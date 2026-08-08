with Ada.Command_Line;
with Ada.Containers;
with Ada.Containers.Bounded_Synchronized_Queues;
with Ada.Containers.Hashed_Maps;
with Ada.Containers.Synchronized_Queue_Interfaces;
with Ada.Containers.Vectors;
with Ada.Long_Float_Text_IO;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Ada.Unchecked_Conversion;
with Flyology.Data_Structures;
with Flyology.Data_Structures.Byte_Strings;
with Flyology.Data_Structures.Handles;
with Flyology.Data_Structures.Hash_Maps;
with Flyology.Data_Structures.Regions;
with Flyology.Data_Structures.Rings.MPMC;
with Flyology.Data_Structures.Rings.SPSC;
with Flyology.Data_Structures.Slab_Pools;
with Flyology.Data_Structures.Vectors;
with Interfaces;
with Interfaces.C;
with System;

procedure Data_Structures_Benchmark is
   package CLI renames Ada.Command_Line;
   package DS renames Flyology.Data_Structures;
   package Byte_Strings renames DS.Byte_Strings;
   package Handles renames DS.Handles;
   package Hash_Maps renames DS.Hash_Maps;
   package MPMC renames DS.Rings.MPMC;
   package Regions renames DS.Regions;
   package Slab_Pools renames DS.Slab_Pools;
   package SPSC renames DS.Rings.SPSC;
   package Vectors renames DS.Vectors;
   package RT renames Ada.Real_Time;
   package TIO renames Ada.Text_IO;
   package US renames Ada.Strings.Unbounded;

   subtype U64 is Interfaces.Unsigned_64;
   subtype Bytes_8 is Ada.Streams.Stream_Element_Array (1 .. 8);

   use type Ada.Containers.Count_Type;
   use type Ada.Streams.Stream_Element_Array;
   use type DS.Byte_Count;
   use type Hash_Maps.Put_Result;
   use type Interfaces.C.int;
   use type MPMC.Pop_Result;
   use type MPMC.Push_Result;
   use type Slab_Pools.Allocation_Result;
   use type RT.Time;
   use type System.Address;
   use type U64;

   function Encode is new Ada.Unchecked_Conversion (U64, Bytes_8);
   function Decode is new Ada.Unchecked_Conversion (Bytes_8, U64);

   function Positive_Argument
     (Position : Positive; Default : Positive) return Positive is
   begin
      if CLI.Argument_Count < Position then
         return Default;
      end if;
      return Positive'Value (CLI.Argument (Position));
   exception
      when Constraint_Error =>
         raise Program_Error with
           "benchmark arguments must be positive integers";
   end Positive_Argument;

   Rounds  : constant Positive := Positive_Argument (1, 50_000);
   Samples : constant Positive := Positive_Argument (2, 5);

   function Map_Capacity return Positive is
      Result : Positive := 1;
   begin
      if Rounds > 1_000_000 then
         raise Program_Error with "benchmark rounds exceed 1000000";
      end if;
      while Result < 2 * Rounds loop
         Result := 2 * Result;
      end loop;
      return Result;
   end Map_Capacity;

   Table_Capacity : constant Positive := Map_Capacity;
   Ring_Capacity  : constant Positive := 1_024;
   Slab_Capacity  : constant Positive := 1_024;

   function Standard_Hash (Key : U64) return Ada.Containers.Hash_Type is
      Work : U64 := Key;
      Hash : U64 := 16#CBF2_9CE4_8422_2325#;
   begin
      for Byte in 1 .. 8 loop
         pragma Unreferenced (Byte);
         Hash := (Hash xor (Work and 16#FF#)) * 16#0000_0100_0000_01B3#;
         Work := Work / 256;
      end loop;
      return Ada.Containers.Hash_Type
        (Hash mod U64 (Ada.Containers.Hash_Type'Modulus));
   end Standard_Hash;

   package Standard_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => U64);
   package Standard_Maps is new Ada.Containers.Hashed_Maps
     (Key_Type        => U64,
      Element_Type    => U64,
      Hash            => Standard_Hash,
      Equivalent_Keys => "=");
   package Queue_Interfaces is new
     Ada.Containers.Synchronized_Queue_Interfaces (U64);
   package Standard_Queues is new Ada.Containers.Bounded_Synchronized_Queues
     (Queue_Interfaces => Queue_Interfaces,
      Default_Capacity => Ada.Containers.Count_Type (Ring_Capacity));

   type Duration_Array is array (Positive range <>) of Duration;

   procedure Sort (Values : in out Duration_Array) is
   begin
      for Index in Values'First + 1 .. Values'Last loop
         declare
            Value : constant Duration := Values (Index);
            Position : Positive := Index;
         begin
            while Position > Values'First
              and then Values (Position - 1) > Value
            loop
               Values (Position) := Values (Position - 1);
               Position := Position - 1;
            end loop;
            Values (Position) := Value;
         end;
      end loop;
   end Sort;

   function Median (Values : Duration_Array) return Duration is
      Ordered : Duration_Array := Values;
      Middle : constant Positive :=
        Ordered'First + (Ordered'Length - 1) / 2;
   begin
      Sort (Ordered);
      if Ordered'Length mod 2 = 0 then
         return (Ordered (Middle) + Ordered (Middle + 1)) / 2;
      end if;
      return Ordered (Middle);
   end Median;

   procedure Measure
     (Action : not null access procedure; Results : out Duration_Array) is
      Started : RT.Time;
   begin
      for Sample in Results'Range loop
         Started := RT.Clock;
         Action.all;
         Results (Sample) := RT.To_Duration (RT.Clock - Started);
      end loop;
   end Measure;

   procedure Report
     (Name       : String;
      Operations : Positive;
      Results    : Duration_Array)
   is
      Elapsed : constant Duration := Median (Results);
      Ns_Per_Operation : constant Long_Float :=
        Long_Float (Elapsed) * 1_000_000_000.0 / Long_Float (Operations);
   begin
      TIO.Put (Name & ": median=" & Elapsed'Image & " s, ns/op=");
      Ada.Long_Float_Text_IO.Put
        (Ns_Per_Operation, Fore => 1, Aft => 2, Exp => 0);
      TIO.Put_Line (", operations=" & Operations'Image);
   end Report;

   function Align_64 (Value : DS.Byte_Count) return DS.Byte_Count is
     (((Value + 63) / 64) * 64);

   Vector_Location : constant DS.Region_Offset := 64;
   Vector_Extent : constant DS.Byte_Count :=
     Vectors.Required_Storage (Rounds, 8);
   Map_Location : constant DS.Region_Offset := DS.Region_Offset
     (Align_64 (DS.Byte_Count (Vector_Location) + Vector_Extent));
   Map_Extent : constant DS.Byte_Count :=
     Hash_Maps.Required_Storage (Table_Capacity, 8, 8);
   SPSC_Location : constant DS.Region_Offset := DS.Region_Offset
     (Align_64 (DS.Byte_Count (Map_Location) + Map_Extent));
   SPSC_Extent : constant DS.Byte_Count :=
     SPSC.Required_Storage (Ring_Capacity, 8);
   MPMC_Location : constant DS.Region_Offset := DS.Region_Offset
     (Align_64 (DS.Byte_Count (SPSC_Location) + SPSC_Extent));
   MPMC_Extent : constant DS.Byte_Count :=
     MPMC.Required_Storage (Ring_Capacity, 8);
   Slab_Location : constant DS.Region_Offset := DS.Region_Offset
     (Align_64 (DS.Byte_Count (MPMC_Location) + MPMC_Extent));
   Slab_Extent : constant DS.Byte_Count :=
     Slab_Pools.Required_Storage (Slab_Capacity, 8, 8);
   String_Location : constant DS.Region_Offset := DS.Region_Offset
     (Align_64 (DS.Byte_Count (Slab_Location) + Slab_Extent));
   String_Extent : constant DS.Byte_Count :=
     Byte_Strings.Required_Storage (8);
   Region_Length : constant DS.Byte_Count := Align_64
     (DS.Byte_Count (String_Location) + String_Extent + 64);

   function Posix_Memalign
     (Result    : access System.Address;
      Alignment : Interfaces.C.size_t;
      Size      : Interfaces.C.size_t) return Interfaces.C.int;
   pragma Import (C, Posix_Memalign, "posix_memalign");

   procedure C_Free (Address : System.Address);
   pragma Import (C, C_Free, "free");

   Base : aliased System.Address := System.Null_Address;
   Region : Regions.View;
   Fly_Vector : Vectors.View;
   Fly_Map : Hash_Maps.View;
   Fly_SPSC : SPSC.View;
   Fly_MPMC : MPMC.View;
   Fly_Slab : Slab_Pools.View;
   Fly_String : Byte_Strings.View;
   Standard_Vector : Standard_Vectors.Vector;
   Standard_Map : Standard_Maps.Map;
   Standard_Queue : Standard_Queues.Queue;
   Standard_String : US.Unbounded_String;
   Timings : Duration_Array (1 .. Samples);
   Checksum : U64 := 0 with Volatile;

   procedure Benchmark_Fly_Vector is
      Data : Bytes_8;
      Added : Boolean;
      Local : U64 := 0;
   begin
      Vectors.Clear (Fly_Vector);
      for Value in 1 .. Rounds loop
         Vectors.Try_Append (Fly_Vector, Encode (U64 (Value)), Added);
         if not Added then
            raise Program_Error with "Flyology vector filled early";
         end if;
      end loop;
      for Index in 1 .. Rounds loop
         Vectors.Read (Fly_Vector, Index, Data);
         Local := Local + Decode (Data);
      end loop;
      Checksum := Checksum + Local;
   end Benchmark_Fly_Vector;

   procedure Benchmark_Standard_Vector is
      Local : U64 := 0;
   begin
      Standard_Vector.Clear;
      for Value in 1 .. Rounds loop
         Standard_Vector.Append (U64 (Value));
      end loop;
      for Index in 1 .. Rounds loop
         Local := Local + Standard_Vector.Element (Index);
      end loop;
      Checksum := Checksum + Local;
   end Benchmark_Standard_Vector;

   procedure Benchmark_Fly_Map is
      Data : Bytes_8;
      Found : Boolean;
      Outcome : Hash_Maps.Put_Result;
      Local : U64 := 0;
   begin
      Hash_Maps.Clear (Fly_Map);
      for Key in 1 .. Rounds loop
         Hash_Maps.Put
           (Fly_Map, Encode (U64 (Key)), Encode (U64 (Key) xor 16#5A5A#),
            Outcome);
         if Outcome /= Hash_Maps.Inserted then
            raise Program_Error with "Flyology map insert failed";
         end if;
      end loop;
      for Key in 1 .. Rounds loop
         Hash_Maps.Get (Fly_Map, Encode (U64 (Key)), Data, Found);
         if not Found then
            raise Program_Error with "Flyology map lookup failed";
         end if;
         Local := Local + Decode (Data);
      end loop;
      Checksum := Checksum + Local;
   end Benchmark_Fly_Map;

   procedure Benchmark_Standard_Map is
      Local : U64 := 0;
   begin
      Standard_Map.Clear;
      for Key in 1 .. Rounds loop
         Standard_Map.Insert (U64 (Key), U64 (Key) xor 16#5A5A#);
      end loop;
      for Key in 1 .. Rounds loop
         Local := Local + Standard_Map.Element (U64 (Key));
      end loop;
      Checksum := Checksum + Local;
   end Benchmark_Standard_Map;

   procedure Benchmark_Fly_SPSC is
      Data : Bytes_8;
      Success : Boolean;
      Local : U64 := 0;
   begin
      for Value in 1 .. Rounds loop
         SPSC.Try_Push (Fly_SPSC, Encode (U64 (Value)), Success);
         if not Success then
            raise Program_Error with "Flyology SPSC push failed";
         end if;
         SPSC.Try_Pop (Fly_SPSC, Data, Success);
         if not Success then
            raise Program_Error with "Flyology SPSC pop failed";
         end if;
         Local := Local + Decode (Data);
      end loop;
      Checksum := Checksum + Local;
   end Benchmark_Fly_SPSC;

   procedure Benchmark_Fly_MPMC is
      Data : Bytes_8;
      Push : MPMC.Push_Result;
      Pop : MPMC.Pop_Result;
      Local : U64 := 0;
   begin
      for Value in 1 .. Rounds loop
         MPMC.Try_Push (Fly_MPMC, Encode (U64 (Value)), Push);
         if Push /= MPMC.Pushed then
            raise Program_Error with "Flyology MPMC push failed";
         end if;
         MPMC.Try_Pop (Fly_MPMC, Data, Pop);
         if Pop /= MPMC.Popped then
            raise Program_Error with "Flyology MPMC pop failed";
         end if;
         Local := Local + Decode (Data);
      end loop;
      Checksum := Checksum + Local;
   end Benchmark_Fly_MPMC;

   procedure Benchmark_Standard_Queue is
      Data : U64;
      Local : U64 := 0;
   begin
      for Value in 1 .. Rounds loop
         Standard_Queue.Enqueue (U64 (Value));
         Standard_Queue.Dequeue (Data);
         Local := Local + Data;
      end loop;
      Checksum := Checksum + Local;
   end Benchmark_Standard_Queue;

   procedure Benchmark_Fly_Slab is
      Handle : Handles.Handle;
      Data : Bytes_8;
      Result : Slab_Pools.Allocation_Result;
      Local : U64 := 0;
   begin
      for Value in 1 .. Rounds loop
         Slab_Pools.Try_Allocate (Fly_Slab, Handle, Result);
         if Result /= Slab_Pools.Allocated then
            raise Program_Error with "Flyology slab allocation failed";
         end if;
         Slab_Pools.Write (Fly_Slab, Handle, Encode (U64 (Value)));
         Slab_Pools.Read (Fly_Slab, Handle, Data);
         Local := Local + Decode (Data);
         Slab_Pools.Release (Fly_Slab, Handle);
      end loop;
      Checksum := Checksum + Local;
   end Benchmark_Fly_Slab;

   procedure Benchmark_Fly_String is
      Data : constant Bytes_8 := Encode (16#666C_796F_6C6F_6779#);
      Local : U64 := 0;
   begin
      for Iteration in 1 .. Rounds loop
         pragma Unreferenced (Iteration);
         Byte_Strings.Assign (Fly_String, Data);
         Local := Local + U64 (Byte_Strings.Length (Fly_String));
      end loop;
      Checksum := Checksum + Local;
   end Benchmark_Fly_String;

   procedure Benchmark_Standard_String is
      Local : U64 := 0;
   begin
      for Iteration in 1 .. Rounds loop
         pragma Unreferenced (Iteration);
         US.Set_Unbounded_String (Standard_String, "flyology");
         Local := Local + U64 (US.Length (Standard_String));
      end loop;
      Checksum := Checksum + Local;
   end Benchmark_Standard_String;

begin
   if Posix_Memalign
     (Base'Access, 64, Interfaces.C.size_t (Region_Length)) /= 0
   then
      raise Storage_Error with "unable to allocate aligned benchmark region";
   end if;

   Regions.Attach (Region, Base, Region_Length);
   Vectors.Initialize (Fly_Vector, Region, Vector_Location, Rounds, 8);
   Hash_Maps.Initialize
     (Fly_Map, Region, Map_Location, Table_Capacity, 8, 8);
   SPSC.Initialize (Fly_SPSC, Region, SPSC_Location, Ring_Capacity, 8);
   MPMC.Initialize (Fly_MPMC, Region, MPMC_Location, Ring_Capacity, 8);
   Slab_Pools.Initialize
     (Fly_Slab, Region, Slab_Location, Slab_Capacity, 8, 8);
   Byte_Strings.Initialize (Fly_String, Region, String_Location, 8);
   Standard_Vector.Reserve_Capacity (Ada.Containers.Count_Type (Rounds));
   Standard_Map.Reserve_Capacity
     (Ada.Containers.Count_Type (Table_Capacity));

   TIO.Put_Line
     ("data-structure benchmark rounds=" & Rounds'Image
      & " samples=" & Samples'Image
      & " (release build; lower ns/op is faster)");
   TIO.Put_Line
     ("vector/map measurements include reset, fill, and lookup/scan; "
      & "queue measurements alternate enqueue/dequeue in one native task");
   TIO.Put_Line
     ("checksums accumulate locally and publish once per sample; results are "
      & "uncontended amortized loop costs, not concurrent scalability");

   Measure (Benchmark_Fly_Vector'Access, Timings);
   Report ("Flyology.Data_Structures.Vectors", 2 * Rounds, Timings);
   Measure (Benchmark_Standard_Vector'Access, Timings);
   Report ("Ada.Containers.Vectors", 2 * Rounds, Timings);
   Measure (Benchmark_Fly_Map'Access, Timings);
   Report ("Flyology.Data_Structures.Hash_Maps", 2 * Rounds, Timings);
   Measure (Benchmark_Standard_Map'Access, Timings);
   Report ("Ada.Containers.Hashed_Maps", 2 * Rounds, Timings);
   Measure (Benchmark_Fly_String'Access, Timings);
   Report ("Flyology.Data_Structures.Byte_Strings", Rounds, Timings);
   Measure (Benchmark_Standard_String'Access, Timings);
   Report ("Ada.Strings.Unbounded", Rounds, Timings);
   Measure (Benchmark_Fly_SPSC'Access, Timings);
   Report ("Flyology.Data_Structures.Rings.SPSC", 2 * Rounds, Timings);
   Measure (Benchmark_Fly_MPMC'Access, Timings);
   Report ("Flyology.Data_Structures.Rings.MPMC", 2 * Rounds, Timings);
   Measure (Benchmark_Standard_Queue'Access, Timings);
   Report
     ("Ada.Containers.Bounded_Synchronized_Queues", 2 * Rounds, Timings);
   Measure (Benchmark_Fly_Slab'Access, Timings);
   Report ("Flyology.Data_Structures.Slab_Pools", 4 * Rounds, Timings);
   TIO.Put_Line
     ("checksum=" & Checksum'Image
      & "; byte strings and queues have different allocation/synchronization "
      & "contracts, and slab pools have no direct standard-container peer");

   Byte_Strings.Destroy (Fly_String);
   Slab_Pools.Destroy (Fly_Slab);
   MPMC.Destroy (Fly_MPMC);
   SPSC.Destroy (Fly_SPSC);
   Hash_Maps.Destroy (Fly_Map);
   Vectors.Destroy (Fly_Vector);
   Regions.Detach (Region);
   C_Free (Base);
exception
   when others =>
      if Base /= System.Null_Address then
         C_Free (Base);
      end if;
      raise;
end Data_Structures_Benchmark;
