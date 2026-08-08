with Ada.Command_Line;
with Ada.Containers;
with Ada.Containers.Bounded_Synchronized_Queues;
with Ada.Containers.Hashed_Maps;
with Ada.Containers.Synchronized_Queue_Interfaces;
with Ada.Containers.Vectors;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Ada.Unchecked_Conversion;
with Flyology;
with Flyology.Data_Structures;
with Flyology.Data_Structures.Allocation_Algorithms.Buddy;
with Flyology.Data_Structures.Arenas;
with Flyology.Data_Structures.Byte_Strings;
with Flyology.Data_Structures.Dynamic.Byte_Strings;
with Flyology.Data_Structures.Dynamic.Hash_Maps;
with Flyology.Data_Structures.Dynamic.Vectors;
with Flyology.Data_Structures.Handles;
with Flyology.Data_Structures.Hash_Maps;
with Flyology.Data_Structures.Regions;
with Flyology.Data_Structures.Rings.MPMC;
with Flyology.Data_Structures.Rings.SPSC;
with Flyology.Data_Structures.Slab_Pools;
with Flyology.Data_Structures.Storage_Types.Unsigned_64s;
with Flyology.Data_Structures.Vectors;
with Flyology_Bench;
with Flyology_Bench.Reporters;
with Interfaces;
with Interfaces.C;
with Interfaces.C.Strings;
with System;

procedure Data_Structures_Benchmark is
   package CLI renames Ada.Command_Line;
   package DS renames Flyology.Data_Structures;
   package Byte_Strings renames DS.Byte_Strings;
   package Arenas is new DS.Arenas
     (Algorithm => DS.Allocation_Algorithms.Buddy);
   package Dynamic_Strings is new DS.Dynamic.Byte_Strings
     (Arena_Provider => Arenas);
   package Handles renames DS.Handles;
   package Regions renames DS.Regions;
   package U64_Elements renames DS.Storage_Types.Unsigned_64s;
   package SPSC is new DS.Rings.SPSC
     (Element => U64_Elements.Element);
   package MPMC is new DS.Rings.MPMC
     (Element => U64_Elements.Element);
   package Slab_Pools is new DS.Slab_Pools
     (Element => U64_Elements.Element);
   package Vectors is new DS.Vectors
     (Element => U64_Elements.Element);
   package Dynamic_Vectors is new DS.Dynamic.Vectors
     (Arena_Provider => Arenas,
      Element        => U64_Elements.Element);
   package Dynamic_Maps is new DS.Dynamic.Hash_Maps
     (Arena_Provider => Arenas,
      Key            => U64_Elements.Element,
      Element        => U64_Elements.Element);
   package Hash_Maps is new DS.Hash_Maps
     (Key     => U64_Elements.Element,
      Element => U64_Elements.Element);
   package Bench renames Flyology_Bench;
   package Reporters renames Flyology_Bench.Reporters;
   package TIO renames Ada.Text_IO;
   package US renames Ada.Strings.Unbounded;

   subtype U64 is Interfaces.Unsigned_64;
   subtype Bytes_8 is Ada.Streams.Stream_Element_Array (1 .. 8);

   use type Ada.Containers.Count_Type;
   use type Ada.Streams.Stream_Element_Array;
   use type Bench.Iteration_Count;
   use type DS.Byte_Count;
   use type DS.Dynamic.Growth_Result;
   use type Arenas.Allocation_Result;
   use type Dynamic_Maps.Put_Result;
   use type Hash_Maps.Put_Result;
   use type Interfaces.C.int;
   use type MPMC.Pop_Result;
   use type MPMC.Push_Result;
   use type Slab_Pools.Allocation_Result;
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

   Maximum_Iterations_Argument : constant Positive :=
     Positive_Argument (1, 200_000);
   Samples_Argument : constant Positive := Positive_Argument (2, 30);
   Measurement_Milliseconds : constant Positive := Positive_Argument (3, 800);
   Contention_Workers : constant Positive := Positive_Argument (4, 4);

   Maximum_Iterations : constant Bench.Iteration_Count :=
     Bench.Iteration_Count (Maximum_Iterations_Argument);
   Samples : constant Bench.Sample_Count :=
     Bench.Sample_Count (Samples_Argument);
   Measurement_Time : constant Duration :=
     Duration (Long_Float (Measurement_Milliseconds) / 1_000.0);

   Working_Capacity : constant Positive := 1_024;
   Map_Capacity     : constant Positive := 2 * Working_Capacity;

   function Payload (Iteration : Bench.Iteration_Count) return U64 is
     (U64 (Iteration) * 16#9E37_79B9_7F4A_7C15# + 16#5A5A#);

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
      Default_Capacity => Ada.Containers.Count_Type (Working_Capacity));

   function CPP_Have_Boost return Interfaces.C.int;
   pragma Import (C, CPP_Have_Boost, "flyology_ds_cpp_have_boost");

   function CPP_Have_Abseil return Interfaces.C.int;
   pragma Import (C, CPP_Have_Abseil, "flyology_ds_cpp_have_abseil");

   function CPP_Compiler return Interfaces.C.Strings.chars_ptr;
   pragma Import (C, CPP_Compiler, "flyology_ds_cpp_compiler");

   function CPP_Vector_Batch
     (Provider   : Interfaces.C.int;
      Iterations : U64;
      Checksum   : access U64) return Interfaces.C.int;
   pragma Import
     (C, CPP_Vector_Batch, "flyology_ds_cpp_vector_batch");

   function CPP_Map_Batch
     (Provider   : Interfaces.C.int;
      Iterations : U64;
      Checksum   : access U64) return Interfaces.C.int;
   pragma Import (C, CPP_Map_Batch, "flyology_ds_cpp_map_batch");

   function CPP_String_Batch
     (Provider   : Interfaces.C.int;
      Iterations : U64;
      Checksum   : access U64) return Interfaces.C.int;
   pragma Import
     (C, CPP_String_Batch, "flyology_ds_cpp_string_batch");

   function CPP_Queue_Batch
     (Provider   : Interfaces.C.int;
      Iterations : U64;
      Checksum   : access U64) return Interfaces.C.int;
   pragma Import (C, CPP_Queue_Batch, "flyology_ds_cpp_queue_batch");

   function CPP_Contention_Batch
     (Structure  : Interfaces.C.int;
      Provider   : Interfaces.C.int;
      Iterations : U64;
      Workers    : Interfaces.C.unsigned;
      Retries    : access U64;
      Value      : access U64) return Interfaces.C.int;
   pragma Import
     (C, CPP_Contention_Batch, "flyology_ds_cpp_contention_batch");

   function Align_64 (Value : DS.Byte_Count) return DS.Byte_Count is
     (((Value + 63) / 64) * 64);

   Vector_Location : constant DS.Region_Offset := 64;
   Vector_Extent : constant DS.Byte_Count :=
     Vectors.Required_Storage (Working_Capacity);
   Map_Location : constant DS.Region_Offset := DS.Region_Offset
     (Align_64 (DS.Byte_Count (Vector_Location) + Vector_Extent));
   Map_Extent : constant DS.Byte_Count :=
     Hash_Maps.Required_Storage (Map_Capacity);
   SPSC_Location : constant DS.Region_Offset := DS.Region_Offset
     (Align_64 (DS.Byte_Count (Map_Location) + Map_Extent));
   SPSC_Extent : constant DS.Byte_Count :=
     SPSC.Required_Storage (Working_Capacity);
   MPMC_Location : constant DS.Region_Offset := DS.Region_Offset
     (Align_64 (DS.Byte_Count (SPSC_Location) + SPSC_Extent));
   MPMC_Extent : constant DS.Byte_Count :=
     MPMC.Required_Storage (Working_Capacity);
   Slab_Location : constant DS.Region_Offset := DS.Region_Offset
     (Align_64 (DS.Byte_Count (MPMC_Location) + MPMC_Extent));
   Slab_Extent : constant DS.Byte_Count :=
     Slab_Pools.Required_Storage (Working_Capacity);
   String_Location : constant DS.Region_Offset := DS.Region_Offset
     (Align_64 (DS.Byte_Count (Slab_Location) + Slab_Extent));
   String_Extent : constant DS.Byte_Count :=
     Byte_Strings.Required_Storage (8);
   Dynamic_Vector_Location : constant DS.Region_Offset := DS.Region_Offset
     (Align_64 (DS.Byte_Count (String_Location) + String_Extent));
   Dynamic_Vector_Extent : constant DS.Byte_Count :=
     Dynamic_Vectors.Required_Storage;
   Dynamic_String_Location : constant DS.Region_Offset := DS.Region_Offset
     (Align_64
        (DS.Byte_Count (Dynamic_Vector_Location) + Dynamic_Vector_Extent));
   Dynamic_String_Extent : constant DS.Byte_Count :=
     Dynamic_Strings.Required_Storage;
   Dynamic_Map_Location : constant DS.Region_Offset := DS.Region_Offset
     (Align_64
        (DS.Byte_Count (Dynamic_String_Location) + Dynamic_String_Extent));
   Dynamic_Map_Extent : constant DS.Byte_Count :=
     Dynamic_Maps.Required_Storage;
   Arena_Location : constant DS.Region_Offset := DS.Region_Offset
     (Align_64 (DS.Byte_Count (Dynamic_Map_Location) + Dynamic_Map_Extent));
   Arena_Extent : constant DS.Byte_Count :=
     Arenas.Required_Storage
       ((Usable_Capacity => 262_144, Minimum_Block_Size => 64));
   Region_Length : constant DS.Byte_Count := Align_64
     (DS.Byte_Count (Arena_Location) + Arena_Extent + 64);

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
   Fly_Arena : Arenas.View;
   Fly_Dynamic_Vector : Dynamic_Vectors.View;
   Fly_Dynamic_Map : Dynamic_Maps.View;
   Fly_Dynamic_String : Dynamic_Strings.View;
   Standard_Vector : Standard_Vectors.Vector;
   Standard_Map : Standard_Maps.Map;
   Standard_Queue : Standard_Queues.Queue;
   Standard_String : US.Unbounded_String;
   Checksum : U64 := 0 with Volatile;
   type Vector_View_Array is
     array (Positive range <>) of aliased Vectors.View;
   type Map_View_Array is
     array (Positive range <>) of aliased Hash_Maps.View;
   type String_View_Array is
     array (Positive range <>) of aliased Byte_Strings.View;
   type Slab_View_Array is
     array (Positive range <>) of aliased Slab_Pools.View;
   type SPSC_View_Array is
     array (Positive range <>) of aliased SPSC.View;
   type MPMC_View_Array is
     array (Positive range <>) of aliased MPMC.View;
   Contended_Vectors : Vector_View_Array (1 .. Contention_Workers);
   Contended_Maps    : Map_View_Array (1 .. Contention_Workers);
   Contended_Strings : String_View_Array (1 .. Contention_Workers);
   Contended_Slabs   : Slab_View_Array (1 .. Contention_Workers);
   Contended_SPSC    : SPSC_View_Array (1 .. 2);
   Contended_MPMC    : MPMC_View_Array (1 .. Contention_Workers);
   Contended_Slab_Handle : Handles.Handle;

   protected type Start_Gate is
      entry Wait;
      procedure Release;
   private
      Open : Boolean := False;
   end Start_Gate;

   protected body Start_Gate is
      entry Wait when Open is
      begin
         null;
      end Wait;

      procedure Release is
      begin
         Open := True;
      end Release;
   end Start_Gate;

   protected type Completion (Expected : Positive) is
      procedure Done (Retries : U64; Success : Boolean);
      entry Await_All;
      function Retry_Count return U64;
      function Passed return Boolean;
   private
      Completed : Natural := 0;
      Retry_Total : U64 := 0;
      All_Passed : Boolean := True;
   end Completion;

   protected body Completion is
      procedure Done (Retries : U64; Success : Boolean) is
      begin
         Completed := Completed + 1;
         Retry_Total := Retry_Total + Retries;
         All_Passed := All_Passed and Success;
      end Done;

      entry Await_All when Completed = Expected is
      begin
         null;
      end Await_All;

      function Retry_Count return U64 is (Retry_Total);
      function Passed return Boolean is (All_Passed);
   end Completion;

   procedure Publish_CPP
     (Status : Interfaces.C.int; Value : U64; Name : String) is
   begin
      if Status /= 0 then
         raise Program_Error with
           Name & " C++ shim failed with status" & Status'Image;
      end if;
      Checksum := Value;
   end Publish_CPP;

   procedure CPP_Contention_Run
     (Structure  : Interfaces.C.int;
      Provider   : Interfaces.C.int;
      Iterations : Bench.Iteration_Count;
      Workers    : Positive;
      Retries    : out U64)
   is
      Local_Retries : aliased U64 := 0;
      Local_Value   : aliased U64 := 0;
      Status : constant Interfaces.C.int :=
        CPP_Contention_Batch
          (Structure, Provider, U64 (Iterations),
           Interfaces.C.unsigned (Workers), Local_Retries'Access,
           Local_Value'Access);
   begin
      Publish_CPP (Status, Local_Value, "contention");
      Retries := Local_Retries;
   end CPP_Contention_Run;

   generic
      with procedure Prepare;
      with procedure Attempt
        (Worker : Positive; Sequence : Bench.Iteration_Count);
      with procedure Cleanup;
   procedure Run_Guard_Contention
     (Iterations : Bench.Iteration_Count; Retries : out U64);

   procedure Run_Guard_Contention
     (Iterations : Bench.Iteration_Count; Retries : out U64)
   is
      Gate : Start_Gate;
      Finished : Completion (Contention_Workers);

      task type Worker_Task is
         entry Configure (Identifier : Positive);
         pragma Task_Info (Flyology.Native_Task);
      end Worker_Task;

      task body Worker_Task is
         Worker_Id : Positive := 1;
         First : Bench.Iteration_Count;
         Last  : Bench.Iteration_Count;
         Local_Retries : U64 := 0;
      begin
         accept Configure (Identifier : Positive) do
            Worker_Id := Identifier;
         end Configure;
         First := Iterations
           * Bench.Iteration_Count (Worker_Id - 1)
           / Bench.Iteration_Count (Contention_Workers) + 1;
         Last := Iterations * Bench.Iteration_Count (Worker_Id)
           / Bench.Iteration_Count (Contention_Workers);
         Gate.Wait;
         if First <= Last then
            for Sequence in First .. Last loop
               loop
                  begin
                     Attempt (Worker_Id, Sequence);
                     exit;
                  exception
                     when DS.Busy_Error =>
                        Local_Retries := Local_Retries + 1;
                  end;
               end loop;
            end loop;
         end if;
         Finished.Done (Local_Retries, True);
      exception
         when others =>
            Finished.Done (Local_Retries, False);
      end Worker_Task;

      type Worker_Array is
        array (Positive range <>) of Worker_Task;
      Workers : Worker_Array (1 .. Contention_Workers);
   begin
      Prepare;
      for Index in Workers'Range loop
         Workers (Index).Configure (Index);
      end loop;
      Gate.Release;
      Finished.Await_All;
      if not Finished.Passed then
         raise Program_Error with "Flyology contention worker failed";
      end if;
      Retries := Finished.Retry_Count;
      Checksum := U64 (Iterations);
      Cleanup;
   exception
      when others =>
         for Worker of Workers loop
            abort Worker;
         end loop;
         raise;
   end Run_Guard_Contention;

   procedure Fly_Vector_Batch (Iterations : Bench.Iteration_Count) is
      Added : Boolean;
      Count : Natural := 0;
      Local : U64 := 0;
   begin
      Vectors.Clear (Fly_Vector);
      for Iteration in Bench.Iteration_Count range 1 .. Iterations loop
         if Count = Working_Capacity then
            Vectors.Clear (Fly_Vector);
            Count := 0;
         end if;
         Vectors.Try_Append
           (Fly_Vector, Payload (Iteration), Added);
         if not Added then
            raise Program_Error with "Flyology vector filled early";
         end if;
         Count := Count + 1;
         Local := Local + Vectors.Read (Fly_Vector, Positive (Count));
      end loop;
      Checksum := Local;
   end Fly_Vector_Batch;

   procedure Ada_Vector_Batch (Iterations : Bench.Iteration_Count) is
      Count : Natural := 0;
      Local : U64 := 0;
   begin
      Standard_Vector.Clear;
      for Iteration in Bench.Iteration_Count range 1 .. Iterations loop
         if Count = Working_Capacity then
            Standard_Vector.Clear;
            Count := 0;
         end if;
         Standard_Vector.Append (Payload (Iteration));
         Count := Count + 1;
         Local := Local + Standard_Vector.Element (Positive (Count));
      end loop;
      Checksum := Local;
   end Ada_Vector_Batch;

   procedure CPP_Vector_Run
     (Provider : Interfaces.C.int; Iterations : Bench.Iteration_Count)
   is
      Local  : aliased U64 := 0;
      Status : constant Interfaces.C.int :=
        CPP_Vector_Batch (Provider, U64 (Iterations), Local'Access);
   begin
      Publish_CPP (Status, Local, "vector");
   end CPP_Vector_Run;

   procedure Fly_Map_Batch (Iterations : Bench.Iteration_Count) is
      Data    : U64;
      Found   : Boolean;
      Outcome : Hash_Maps.Put_Result;
      Local   : U64 := 0;
      Key     : U64;
   begin
      Hash_Maps.Clear (Fly_Map);
      for Iteration in Bench.Iteration_Count range 1 .. Iterations loop
         Key := U64
           ((Iteration - 1) mod Bench.Iteration_Count (Working_Capacity)) + 1;
         if Key = 1 then
            Hash_Maps.Clear (Fly_Map);
         end if;
         Hash_Maps.Put
           (Fly_Map, Key, Payload (Iteration), Outcome);
         if Outcome /= Hash_Maps.Inserted then
            raise Program_Error with "Flyology map insert failed";
         end if;
         Hash_Maps.Get (Fly_Map, Key, Data, Found);
         if not Found then
            raise Program_Error with "Flyology map lookup failed";
         end if;
         Local := Local + Data;
      end loop;
      Checksum := Local;
   end Fly_Map_Batch;

   procedure Ada_Map_Batch (Iterations : Bench.Iteration_Count) is
      Local : U64 := 0;
      Key   : U64;
   begin
      Standard_Map.Clear;
      for Iteration in Bench.Iteration_Count range 1 .. Iterations loop
         Key := U64
           ((Iteration - 1) mod Bench.Iteration_Count (Working_Capacity)) + 1;
         if Key = 1 then
            Standard_Map.Clear;
         end if;
         Standard_Map.Insert (Key, Payload (Iteration));
         Local := Local + Standard_Map.Element (Key);
      end loop;
      Checksum := Local;
   end Ada_Map_Batch;

   procedure CPP_Map_Run
     (Provider : Interfaces.C.int; Iterations : Bench.Iteration_Count)
   is
      Local  : aliased U64 := 0;
      Status : constant Interfaces.C.int :=
        CPP_Map_Batch (Provider, U64 (Iterations), Local'Access);
   begin
      Publish_CPP (Status, Local, "map");
   end CPP_Map_Run;

   procedure Fly_String_Batch (Iterations : Bench.Iteration_Count) is
      Data  : constant Bytes_8 := Encode (16#666C_796F_6C6F_6779#);
      Local : U64 := 0;
   begin
      for Iteration in Bench.Iteration_Count range 1 .. Iterations loop
         pragma Unreferenced (Iteration);
         Byte_Strings.Assign (Fly_String, Data);
         Local := Local + U64 (Byte_Strings.Length (Fly_String));
      end loop;
      Checksum := Local;
   end Fly_String_Batch;

   procedure Ada_String_Batch (Iterations : Bench.Iteration_Count) is
      Local : U64 := 0;
   begin
      for Iteration in Bench.Iteration_Count range 1 .. Iterations loop
         pragma Unreferenced (Iteration);
         US.Set_Unbounded_String (Standard_String, "flyology");
         Local := Local + U64 (US.Length (Standard_String));
      end loop;
      Checksum := Local;
   end Ada_String_Batch;

   procedure CPP_String_Run
     (Provider : Interfaces.C.int; Iterations : Bench.Iteration_Count)
   is
      Local  : aliased U64 := 0;
      Status : constant Interfaces.C.int :=
        CPP_String_Batch (Provider, U64 (Iterations), Local'Access);
   begin
      Publish_CPP (Status, Local, "string");
   end CPP_String_Run;

   procedure Fly_SPSC_Batch (Iterations : Bench.Iteration_Count) is
      Data    : U64;
      Success : Boolean;
      Local   : U64 := 0;
   begin
      for Iteration in Bench.Iteration_Count range 1 .. Iterations loop
         SPSC.Try_Push (Fly_SPSC, Payload (Iteration), Success);
         if not Success then
            raise Program_Error with "Flyology SPSC push failed";
         end if;
         SPSC.Try_Pop (Fly_SPSC, Data, Success);
         if not Success then
            raise Program_Error with "Flyology SPSC pop failed";
         end if;
         Local := Local + Data;
      end loop;
      Checksum := Local;
   end Fly_SPSC_Batch;

   procedure Fly_MPMC_Batch (Iterations : Bench.Iteration_Count) is
      Data  : U64;
      Push  : MPMC.Push_Result;
      Pop   : MPMC.Pop_Result;
      Local : U64 := 0;
   begin
      for Iteration in Bench.Iteration_Count range 1 .. Iterations loop
         MPMC.Try_Push (Fly_MPMC, Payload (Iteration), Push);
         if Push /= MPMC.Pushed then
            raise Program_Error with "Flyology MPMC push failed";
         end if;
         MPMC.Try_Pop (Fly_MPMC, Data, Pop);
         if Pop /= MPMC.Popped then
            raise Program_Error with "Flyology MPMC pop failed";
         end if;
         Local := Local + Data;
      end loop;
      Checksum := Local;
   end Fly_MPMC_Batch;

   procedure Ada_Queue_Batch (Iterations : Bench.Iteration_Count) is
      Data  : U64;
      Local : U64 := 0;
   begin
      for Iteration in Bench.Iteration_Count range 1 .. Iterations loop
         Standard_Queue.Enqueue (Payload (Iteration));
         Standard_Queue.Dequeue (Data);
         Local := Local + Data;
      end loop;
      Checksum := Local;
   end Ada_Queue_Batch;

   procedure CPP_Queue_Run
     (Provider : Interfaces.C.int; Iterations : Bench.Iteration_Count)
   is
      Local  : aliased U64 := 0;
      Status : constant Interfaces.C.int :=
        CPP_Queue_Batch (Provider, U64 (Iterations), Local'Access);
   begin
      Publish_CPP (Status, Local, "queue");
   end CPP_Queue_Run;

   procedure Fly_Slab_Batch (Iterations : Bench.Iteration_Count) is
      Handle : Handles.Handle;
      Data   : U64;
      Result : Slab_Pools.Allocation_Result;
      Local  : U64 := 0;
   begin
      for Iteration in Bench.Iteration_Count range 1 .. Iterations loop
         Slab_Pools.Try_Allocate
           (Fly_Slab, Payload (Iteration), Handle, Result);
         if Result /= Slab_Pools.Allocated then
            raise Program_Error with "Flyology slab allocation failed";
         end if;
         Slab_Pools.Read (Fly_Slab, Handle, Data);
         Local := Local + Data;
         Slab_Pools.Release (Fly_Slab, Handle);
      end loop;
      Checksum := Local;
   end Fly_Slab_Batch;

   procedure Fly_Arena_Batch (Iterations : Bench.Iteration_Count) is
      Handle : Arenas.Allocation_Handle;
      Data   : Bytes_8;
      Result : Arenas.Allocation_Result;
      Local  : U64 := 0;
   begin
      for Iteration in Bench.Iteration_Count range 1 .. Iterations loop
         Arenas.Try_Allocate (Fly_Arena, 8, Handle, Result);
         if Result /= Arenas.Allocated then
            raise Program_Error with "Flyology arena allocation failed";
         end if;
         Arenas.Write
           (Fly_Arena, Handle, 0, Encode (Payload (Iteration)));
         Arenas.Read (Fly_Arena, Handle, 0, Data);
         Local := Local + Decode (Data);
         Arenas.Release (Fly_Arena, Handle);
      end loop;
      Checksum := Local;
   end Fly_Arena_Batch;

   procedure Fly_Dynamic_Vector_Batch
     (Iterations : Bench.Iteration_Count)
   is
      Data   : U64;
      Result : DS.Dynamic.Growth_Result;
      Count  : Natural := 0;
      Local  : U64 := 0;
   begin
      Dynamic_Vectors.Clear (Fly_Dynamic_Vector);
      for Iteration in Bench.Iteration_Count range 1 .. Iterations loop
         if Count = Working_Capacity then
            Dynamic_Vectors.Clear (Fly_Dynamic_Vector);
            Count := 0;
         end if;
         Dynamic_Vectors.Try_Append
           (Fly_Dynamic_Vector, Fly_Arena, Payload (Iteration), Result);
         if Result /= DS.Dynamic.Completed then
            raise Program_Error with "dynamic vector append failed";
         end if;
         Count := Count + 1;
         Data := Dynamic_Vectors.Read
           (Fly_Dynamic_Vector, Fly_Arena, Positive (Count));
         Local := Local + Data;
      end loop;
      Checksum := Local;
   end Fly_Dynamic_Vector_Batch;

   procedure Fly_Dynamic_Map_Batch
     (Iterations : Bench.Iteration_Count)
   is
      Data    : U64;
      Found   : Boolean;
      Result  : Dynamic_Maps.Put_Result;
      Key     : U64;
      Local   : U64 := 0;
   begin
      Dynamic_Maps.Clear (Fly_Dynamic_Map, Fly_Arena);
      for Iteration in Bench.Iteration_Count range 1 .. Iterations loop
         Key := U64
           ((Iteration - 1) mod Bench.Iteration_Count (Working_Capacity)) + 1;
         if Key = 1 then
            Dynamic_Maps.Clear (Fly_Dynamic_Map, Fly_Arena);
         end if;
         Dynamic_Maps.Put
           (Fly_Dynamic_Map, Fly_Arena, Key, Payload (Iteration), Result);
         if Result /= Dynamic_Maps.Put_Inserted then
            raise Program_Error with "dynamic map insert failed";
         end if;
         Dynamic_Maps.Get
           (Fly_Dynamic_Map, Fly_Arena, Key, Data, Found);
         if not Found then
            raise Program_Error with "dynamic map lookup failed";
         end if;
         Local := Local + Data;
      end loop;
      Checksum := Local;
   end Fly_Dynamic_Map_Batch;

   procedure Fly_Dynamic_String_Batch
     (Iterations : Bench.Iteration_Count)
   is
      Data   : constant Bytes_8 := Encode (16#666C_796F_6C6F_6779#);
      Result : DS.Dynamic.Growth_Result;
      Local  : U64 := 0;
   begin
      for Iteration in Bench.Iteration_Count range 1 .. Iterations loop
         pragma Unreferenced (Iteration);
         Dynamic_Strings.Try_Assign
           (Fly_Dynamic_String, Fly_Arena, Data, Result);
         if Result /= DS.Dynamic.Completed then
            raise Program_Error with "dynamic string assignment failed";
         end if;
         Local := Local + U64 (Dynamic_Strings.Length (Fly_Dynamic_String));
      end loop;
      Checksum := Local;
   end Fly_Dynamic_String_Batch;

   procedure Prepare_Vector_Contention is
      Appended : Boolean;
   begin
      Vectors.Initialize
        (Contended_Vectors (1), Region, Vector_Location,
         Working_Capacity);
      Vectors.Try_Append
        (Contended_Vectors (1), 0, Appended);
      if not Appended then
         raise Program_Error with "unable to seed contended vector";
      end if;
      for Index in 2 .. Contention_Workers loop
         Vectors.Attach
           (Contended_Vectors (Index), Region, Vector_Location,
            Working_Capacity);
      end loop;
   end Prepare_Vector_Contention;

   procedure Attempt_Vector_Contention
     (Worker : Positive; Sequence : Bench.Iteration_Count) is
   begin
      Vectors.Replace
        (Contended_Vectors (Worker), 1,
         Payload (Sequence) + U64 (Worker));
   end Attempt_Vector_Contention;

   procedure Attempt_Vector_Wait
     (Worker : Positive; Sequence : Bench.Iteration_Count) is
   begin
      Vectors.Replace
        (Contended_Vectors (Worker), 1,
         Payload (Sequence) + U64 (Worker), 5.0);
   end Attempt_Vector_Wait;

   procedure Cleanup_Vector_Contention is
   begin
      for Index in Contended_Vectors'Range loop
         Vectors.Detach (Contended_Vectors (Index));
      end loop;
   end Cleanup_Vector_Contention;

   procedure Run_Vector_Contention is new Run_Guard_Contention
     (Prepare => Prepare_Vector_Contention,
      Attempt => Attempt_Vector_Contention,
      Cleanup => Cleanup_Vector_Contention);

   procedure Run_Vector_Wait is new Run_Guard_Contention
     (Prepare => Prepare_Vector_Contention,
      Attempt => Attempt_Vector_Wait,
      Cleanup => Cleanup_Vector_Contention);

   procedure Prepare_Map_Contention is
   begin
      Hash_Maps.Initialize
        (Contended_Maps (1), Region, Map_Location, Map_Capacity);
      for Index in 2 .. Contention_Workers loop
         Hash_Maps.Attach
           (Contended_Maps (Index), Region, Map_Location, Map_Capacity);
      end loop;
   end Prepare_Map_Contention;

   procedure Attempt_Map_Contention
     (Worker : Positive; Sequence : Bench.Iteration_Count)
   is
      Outcome : Hash_Maps.Put_Result;
   begin
      Hash_Maps.Put
        (Contended_Maps (Worker), U64 (Worker), Payload (Sequence), Outcome);
      if Outcome = Hash_Maps.Table_Full then
         raise Program_Error with "contended map filled unexpectedly";
      end if;
   end Attempt_Map_Contention;

   procedure Attempt_Map_Wait
     (Worker : Positive; Sequence : Bench.Iteration_Count)
   is
      Outcome : Hash_Maps.Put_Result;
   begin
      Hash_Maps.Put
        (Contended_Maps (Worker), U64 (Worker), Payload (Sequence),
         5.0, Outcome);
      if Outcome = Hash_Maps.Table_Full then
         raise Program_Error with "contended map filled unexpectedly";
      end if;
   end Attempt_Map_Wait;

   procedure Cleanup_Map_Contention is
   begin
      for Index in Contended_Maps'Range loop
         Hash_Maps.Detach (Contended_Maps (Index));
      end loop;
   end Cleanup_Map_Contention;

   procedure Run_Map_Contention is new Run_Guard_Contention
     (Prepare => Prepare_Map_Contention,
      Attempt => Attempt_Map_Contention,
      Cleanup => Cleanup_Map_Contention);

   procedure Run_Map_Wait is new Run_Guard_Contention
     (Prepare => Prepare_Map_Contention,
      Attempt => Attempt_Map_Wait,
      Cleanup => Cleanup_Map_Contention);

   procedure Prepare_String_Contention is
   begin
      Byte_Strings.Initialize
        (Contended_Strings (1), Region, String_Location, 8);
      for Index in 2 .. Contention_Workers loop
         Byte_Strings.Attach
           (Contended_Strings (Index), Region, String_Location, 8);
      end loop;
   end Prepare_String_Contention;

   procedure Attempt_String_Contention
     (Worker : Positive; Sequence : Bench.Iteration_Count) is
      pragma Unreferenced (Sequence);
   begin
      Byte_Strings.Assign
        (Contended_Strings (Worker), Encode (U64 (Worker)));
   end Attempt_String_Contention;

   procedure Attempt_String_Wait
     (Worker : Positive; Sequence : Bench.Iteration_Count) is
      pragma Unreferenced (Sequence);
   begin
      Byte_Strings.Assign
        (Contended_Strings (Worker), Encode (U64 (Worker)), 5.0);
   end Attempt_String_Wait;

   procedure Cleanup_String_Contention is
   begin
      for Index in Contended_Strings'Range loop
         Byte_Strings.Detach (Contended_Strings (Index));
      end loop;
   end Cleanup_String_Contention;

   procedure Run_String_Contention is new Run_Guard_Contention
     (Prepare => Prepare_String_Contention,
      Attempt => Attempt_String_Contention,
      Cleanup => Cleanup_String_Contention);

   procedure Run_String_Wait is new Run_Guard_Contention
     (Prepare => Prepare_String_Contention,
      Attempt => Attempt_String_Wait,
      Cleanup => Cleanup_String_Contention);

   procedure Prepare_Slab_Contention is
      Outcome : Slab_Pools.Allocation_Result;
   begin
      Slab_Pools.Initialize
        (Contended_Slabs (1), Region, Slab_Location,
         Working_Capacity);
      for Index in 2 .. Contention_Workers loop
         Slab_Pools.Attach
           (Contended_Slabs (Index), Region, Slab_Location,
            Working_Capacity);
      end loop;
      Slab_Pools.Try_Allocate
        (Contended_Slabs (1), 0, Contended_Slab_Handle, Outcome);
      if Outcome /= Slab_Pools.Allocated then
         raise Program_Error with "unable to seed contended slab";
      end if;
   end Prepare_Slab_Contention;

   procedure Attempt_Slab_Contention
     (Worker : Positive; Sequence : Bench.Iteration_Count) is
   begin
      Slab_Pools.Replace
        (Contended_Slabs (Worker), Contended_Slab_Handle,
         Payload (Sequence));
   end Attempt_Slab_Contention;

   procedure Attempt_Slab_Wait
     (Worker : Positive; Sequence : Bench.Iteration_Count) is
   begin
      Slab_Pools.Replace
        (Contended_Slabs (Worker), Contended_Slab_Handle,
         Payload (Sequence), 5.0);
   end Attempt_Slab_Wait;

   procedure Cleanup_Slab_Contention is
   begin
      Slab_Pools.Release (Contended_Slabs (1), Contended_Slab_Handle);
      for Index in Contended_Slabs'Range loop
         Slab_Pools.Detach (Contended_Slabs (Index));
      end loop;
   end Cleanup_Slab_Contention;

   procedure Run_Slab_Contention is new Run_Guard_Contention
     (Prepare => Prepare_Slab_Contention,
      Attempt => Attempt_Slab_Contention,
      Cleanup => Cleanup_Slab_Contention);

   procedure Run_Slab_Wait is new Run_Guard_Contention
     (Prepare => Prepare_Slab_Contention,
      Attempt => Attempt_Slab_Wait,
      Cleanup => Cleanup_Slab_Contention);

   procedure Run_SPSC_Contention
     (Iterations : Bench.Iteration_Count;
      Timed      : Boolean;
      Retries    : out U64)
   is
      Gate : Start_Gate;
      Finished : Completion (2);

      task Producer is
         pragma Task_Info (Flyology.Native_Task);
      end Producer;

      task Consumer is
         pragma Task_Info (Flyology.Native_Task);
      end Consumer;

      task body Producer is
         Pushed : Boolean;
         Local_Retries : U64 := 0;
      begin
         Gate.Wait;
         for Sequence in Bench.Iteration_Count range 1 .. Iterations loop
            if Timed then
               SPSC.Push
                 (Contended_SPSC (1), Payload (Sequence), 5.0);
            else
               loop
                  SPSC.Try_Push
                    (Contended_SPSC (1), Payload (Sequence), Pushed);
                  exit when Pushed;
                  Local_Retries := Local_Retries + 1;
                  delay 0.0;
               end loop;
            end if;
         end loop;
         Finished.Done (Local_Retries, True);
      exception
         when others => Finished.Done (Local_Retries, False);
      end Producer;

      task body Consumer is
         Data : U64;
         Popped : Boolean;
         Local_Retries : U64 := 0;
         Local : U64 := 0;
      begin
         Gate.Wait;
         for Sequence in Bench.Iteration_Count range 1 .. Iterations loop
            pragma Unreferenced (Sequence);
            if Timed then
               SPSC.Pop (Contended_SPSC (2), Data, 5.0);
            else
               loop
                  SPSC.Try_Pop (Contended_SPSC (2), Data, Popped);
                  exit when Popped;
                  Local_Retries := Local_Retries + 1;
                  delay 0.0;
               end loop;
            end if;
            Local := Local + Data;
         end loop;
         Checksum := Local;
         Finished.Done (Local_Retries, True);
      exception
         when others => Finished.Done (Local_Retries, False);
      end Consumer;
   begin
      SPSC.Initialize
        (Contended_SPSC (1), Region, SPSC_Location, Working_Capacity);
      SPSC.Attach
        (Contended_SPSC (2), Region, SPSC_Location, Working_Capacity);
      Gate.Release;
      Finished.Await_All;
      if not Finished.Passed then
         raise Program_Error with "SPSC contention worker failed";
      end if;
      Retries := Finished.Retry_Count;
      SPSC.Destroy (Contended_SPSC (1));
      SPSC.Detach (Contended_SPSC (2));
   exception
      when others =>
         abort Producer;
         abort Consumer;
         raise;
   end Run_SPSC_Contention;

   procedure Run_SPSC_Try
     (Iterations : Bench.Iteration_Count; Retries : out U64) is
   begin
      Run_SPSC_Contention (Iterations, False, Retries);
   end Run_SPSC_Try;

   procedure Run_SPSC_Wait
     (Iterations : Bench.Iteration_Count; Retries : out U64) is
   begin
      Run_SPSC_Contention (Iterations, True, Retries);
   end Run_SPSC_Wait;

   procedure Run_MPMC_Contention
     (Iterations : Bench.Iteration_Count;
      Timed      : Boolean;
      Retries    : out U64)
   is
      Half : constant Positive := Contention_Workers / 2;
      Gate : Start_Gate;
      Finished : Completion (Contention_Workers);
      type Result_Array is array (Positive range <>) of U64
        with Volatile_Components;
      Values : Result_Array (1 .. Contention_Workers) := (others => 0);

      task type Worker_Task is
         entry Configure (Identifier : Positive);
         pragma Task_Info (Flyology.Native_Task);
      end Worker_Task;

      task body Worker_Task is
         Worker_Id : Positive := 1;
         Lane : Natural;
         First : Bench.Iteration_Count;
         Last : Bench.Iteration_Count;
         Data : U64;
         Push : MPMC.Push_Result;
         Pop : MPMC.Pop_Result;
         Local_Retries : U64 := 0;
         Local : U64 := 0;
      begin
         accept Configure (Identifier : Positive) do
            Worker_Id := Identifier;
         end Configure;
         Lane := (Worker_Id - 1) mod Half;
         First := Iterations * Bench.Iteration_Count (Lane)
           / Bench.Iteration_Count (Half) + 1;
         Last := Iterations * Bench.Iteration_Count (Lane + 1)
           / Bench.Iteration_Count (Half);
         Gate.Wait;
         if First <= Last then
            for Sequence in First .. Last loop
               if Worker_Id <= Half then
                  if Timed then
                     MPMC.Push
                       (Contended_MPMC (Worker_Id),
                        Payload (Sequence), 5.0);
                  else
                     loop
                        MPMC.Try_Push
                          (Contended_MPMC (Worker_Id),
                           Payload (Sequence), Push);
                        exit when Push = MPMC.Pushed;
                        Local_Retries := Local_Retries + 1;
                        delay 0.0;
                     end loop;
                  end if;
               else
                  if Timed then
                     MPMC.Pop
                       (Contended_MPMC (Worker_Id), Data, 5.0);
                  else
                     loop
                        MPMC.Try_Pop
                          (Contended_MPMC (Worker_Id), Data, Pop);
                        exit when Pop = MPMC.Popped;
                        Local_Retries := Local_Retries + 1;
                        delay 0.0;
                     end loop;
                  end if;
                  Local := Local + Data;
               end if;
            end loop;
         end if;
         if Worker_Id > Half then
            Values (Worker_Id) := Local;
         end if;
         Finished.Done (Local_Retries, True);
      exception
         when others => Finished.Done (Local_Retries, False);
      end Worker_Task;

      type Worker_Array is
        array (Positive range <>) of Worker_Task;
      Workers : Worker_Array (1 .. Contention_Workers);
   begin
      Checksum := 0;
      MPMC.Initialize
        (Contended_MPMC (1), Region, MPMC_Location,
         Working_Capacity);
      for Index in 2 .. Contention_Workers loop
         MPMC.Attach
           (Contended_MPMC (Index), Region, MPMC_Location,
            Working_Capacity);
      end loop;
      for Index in Workers'Range loop
         Workers (Index).Configure (Index);
      end loop;
      Gate.Release;
      Finished.Await_All;
      if not Finished.Passed then
         raise Program_Error with "MPMC contention worker failed";
      end if;
      Retries := Finished.Retry_Count;
      for Index in Half + 1 .. Contention_Workers loop
         Checksum := Checksum + Values (Index);
      end loop;
      MPMC.Destroy (Contended_MPMC (1));
      for Index in 2 .. Contention_Workers loop
         MPMC.Detach (Contended_MPMC (Index));
      end loop;
   exception
      when others =>
         for Worker of Workers loop
            abort Worker;
         end loop;
         raise;
   end Run_MPMC_Contention;

   procedure Run_MPMC_Try
     (Iterations : Bench.Iteration_Count; Retries : out U64) is
   begin
      Run_MPMC_Contention (Iterations, False, Retries);
   end Run_MPMC_Try;

   procedure Run_MPMC_Wait
     (Iterations : Bench.Iteration_Count; Retries : out U64) is
   begin
      Run_MPMC_Contention (Iterations, True, Retries);
   end Run_MPMC_Wait;

   type Vector_Case is
     (Flyology,
      Ada_Vector,
      Std_Vector,
      Std_Vector_Mutex,
      Boost_Vector,
      Boost_Vector_Mutex);
   subtype Vector_Core_Case is
     Vector_Case range Flyology .. Std_Vector_Mutex;

   procedure Vector_Batch
     (Which : Vector_Case; Iterations : Bench.Iteration_Count) is
   begin
      case Which is
         when Flyology =>
            Fly_Vector_Batch (Iterations);
         when Ada_Vector =>
            Ada_Vector_Batch (Iterations);
         when Std_Vector =>
            CPP_Vector_Run (0, Iterations);
         when Std_Vector_Mutex =>
            CPP_Vector_Run (1, Iterations);
         when Boost_Vector =>
            CPP_Vector_Run (2, Iterations);
         when Boost_Vector_Mutex =>
            CPP_Vector_Run (3, Iterations);
      end case;
   end Vector_Batch;

   procedure Vector_Core_Batch
     (Which : Vector_Core_Case; Iterations : Bench.Iteration_Count) is
   begin
      Vector_Batch (Which, Iterations);
   end Vector_Core_Batch;

   procedure Compare_Vectors is new Bench.Compare_Many
     (Case_Id => Vector_Case, Batch => Vector_Batch);
   procedure Compare_Vector_Core is new Bench.Compare_Many
     (Case_Id => Vector_Core_Case, Batch => Vector_Core_Batch);
   procedure Put_Vectors is new Reporters.Put_Multi_Comparison_Console
     (Vector_Case);
   procedure Put_Vector_Core is new Reporters.Put_Multi_Comparison_Console
     (Vector_Core_Case);

   type Map_Case is
     (Flyology,
      Ada_Hashed_Map,
      Std_Unordered,
      Std_Unordered_Mutex,
      Boost_Flat_Map,
      Boost_Flat_Map_Mutex,
      Abseil_Flat_Map,
      Abseil_Flat_Map_Mutex);
   subtype Map_Core_Case is
     Map_Case range Flyology .. Std_Unordered_Mutex;
   subtype Map_Boost_Case is
     Map_Case range Flyology .. Boost_Flat_Map_Mutex;

   procedure Map_Batch
     (Which : Map_Case; Iterations : Bench.Iteration_Count) is
   begin
      case Which is
         when Flyology =>
            Fly_Map_Batch (Iterations);
         when Ada_Hashed_Map =>
            Ada_Map_Batch (Iterations);
         when Std_Unordered =>
            CPP_Map_Run (0, Iterations);
         when Std_Unordered_Mutex =>
            CPP_Map_Run (1, Iterations);
         when Boost_Flat_Map =>
            CPP_Map_Run (2, Iterations);
         when Boost_Flat_Map_Mutex =>
            CPP_Map_Run (3, Iterations);
         when Abseil_Flat_Map =>
            CPP_Map_Run (4, Iterations);
         when Abseil_Flat_Map_Mutex =>
            CPP_Map_Run (5, Iterations);
      end case;
   end Map_Batch;

   procedure Map_Core_Batch
     (Which : Map_Core_Case; Iterations : Bench.Iteration_Count) is
   begin
      Map_Batch (Which, Iterations);
   end Map_Core_Batch;

   procedure Map_Boost_Batch
     (Which : Map_Boost_Case; Iterations : Bench.Iteration_Count) is
   begin
      Map_Batch (Which, Iterations);
   end Map_Boost_Batch;

   procedure Compare_Maps is new Bench.Compare_Many
     (Case_Id => Map_Case, Batch => Map_Batch);
   procedure Compare_Map_Core is new Bench.Compare_Many
     (Case_Id => Map_Core_Case, Batch => Map_Core_Batch);
   procedure Compare_Map_Boost is new Bench.Compare_Many
     (Case_Id => Map_Boost_Case, Batch => Map_Boost_Batch);
   procedure Put_Maps is new Reporters.Put_Multi_Comparison_Console (Map_Case);
   procedure Put_Map_Core is new Reporters.Put_Multi_Comparison_Console
     (Map_Core_Case);
   procedure Put_Map_Boost is new Reporters.Put_Multi_Comparison_Console
     (Map_Boost_Case);

   type String_Case is
     (Flyology, Ada_Unbounded, Std_String, Std_String_Mutex);

   procedure String_Batch
     (Which : String_Case; Iterations : Bench.Iteration_Count) is
   begin
      case Which is
         when Flyology =>
            Fly_String_Batch (Iterations);
         when Ada_Unbounded =>
            Ada_String_Batch (Iterations);
         when Std_String =>
            CPP_String_Run (0, Iterations);
         when Std_String_Mutex =>
            CPP_String_Run (1, Iterations);
      end case;
   end String_Batch;

   procedure Compare_Strings is new Bench.Compare_Many
     (Case_Id => String_Case, Batch => String_Batch);
   procedure Put_Strings is new Reporters.Put_Multi_Comparison_Console
     (String_Case);

   type SPSC_Case is
     (Flyology, Std_Deque_Mutex, Boost_Lockfree);
   subtype SPSC_Core_Case is
     SPSC_Case range Flyology .. Std_Deque_Mutex;

   procedure SPSC_Batch
     (Which : SPSC_Case; Iterations : Bench.Iteration_Count) is
   begin
      case Which is
         when Flyology =>
            Fly_SPSC_Batch (Iterations);
         when Std_Deque_Mutex =>
            CPP_Queue_Run (0, Iterations);
         when Boost_Lockfree =>
            CPP_Queue_Run (1, Iterations);
      end case;
   end SPSC_Batch;

   procedure SPSC_Core_Batch
     (Which : SPSC_Core_Case; Iterations : Bench.Iteration_Count) is
   begin
      SPSC_Batch (Which, Iterations);
   end SPSC_Core_Batch;

   procedure Compare_SPSC is new Bench.Compare_Many
     (Case_Id => SPSC_Case, Batch => SPSC_Batch);
   procedure Compare_SPSC_Core is new Bench.Compare_Many
     (Case_Id => SPSC_Core_Case, Batch => SPSC_Core_Batch);
   procedure Put_SPSC is new Reporters.Put_Multi_Comparison_Console
     (SPSC_Case);
   procedure Put_SPSC_Core is new Reporters.Put_Multi_Comparison_Console
     (SPSC_Core_Case);

   type MPMC_Case is
     (Flyology, Ada_Sync_Queue, Std_Deque_Mutex, Boost_Lockfree);
   subtype MPMC_Core_Case is
     MPMC_Case range Flyology .. Std_Deque_Mutex;

   procedure MPMC_Batch
     (Which : MPMC_Case; Iterations : Bench.Iteration_Count) is
   begin
      case Which is
         when Flyology =>
            Fly_MPMC_Batch (Iterations);
         when Ada_Sync_Queue =>
            Ada_Queue_Batch (Iterations);
         when Std_Deque_Mutex =>
            CPP_Queue_Run (0, Iterations);
         when Boost_Lockfree =>
            CPP_Queue_Run (2, Iterations);
      end case;
   end MPMC_Batch;

   procedure MPMC_Core_Batch
     (Which : MPMC_Core_Case; Iterations : Bench.Iteration_Count) is
   begin
      MPMC_Batch (Which, Iterations);
   end MPMC_Core_Batch;

   procedure Compare_MPMC is new Bench.Compare_Many
     (Case_Id => MPMC_Case, Batch => MPMC_Batch);
   procedure Compare_MPMC_Core is new Bench.Compare_Many
     (Case_Id => MPMC_Core_Case, Batch => MPMC_Core_Batch);
   procedure Put_MPMC is new Reporters.Put_Multi_Comparison_Console
     (MPMC_Case);
   procedure Put_MPMC_Core is new Reporters.Put_Multi_Comparison_Console
     (MPMC_Core_Case);

   procedure Measure_Slab is new Bench.Measure_Batched (Fly_Slab_Batch);
   procedure Measure_Arena is new Bench.Measure_Batched (Fly_Arena_Batch);

   type Dynamic_Vector_Case is (Flyology_Arena_Backed, Ada_Vector);

   procedure Dynamic_Vector_Batch
     (Which : Dynamic_Vector_Case; Iterations : Bench.Iteration_Count) is
   begin
      case Which is
         when Flyology_Arena_Backed =>
            Fly_Dynamic_Vector_Batch (Iterations);
         when Ada_Vector =>
            Ada_Vector_Batch (Iterations);
      end case;
   end Dynamic_Vector_Batch;

   procedure Compare_Dynamic_Vectors is new Bench.Compare_Many
     (Case_Id => Dynamic_Vector_Case, Batch => Dynamic_Vector_Batch);
   procedure Put_Dynamic_Vectors is new
     Reporters.Put_Multi_Comparison_Console (Dynamic_Vector_Case);

   type Dynamic_Map_Case is (Flyology_Arena_Backed, Ada_Hashed_Map);

   procedure Dynamic_Map_Batch
     (Which : Dynamic_Map_Case; Iterations : Bench.Iteration_Count) is
   begin
      case Which is
         when Flyology_Arena_Backed =>
            Fly_Dynamic_Map_Batch (Iterations);
         when Ada_Hashed_Map =>
            Ada_Map_Batch (Iterations);
      end case;
   end Dynamic_Map_Batch;

   procedure Compare_Dynamic_Maps is new Bench.Compare_Many
     (Case_Id => Dynamic_Map_Case, Batch => Dynamic_Map_Batch);
   procedure Put_Dynamic_Maps is new
     Reporters.Put_Multi_Comparison_Console (Dynamic_Map_Case);

   type Dynamic_String_Case is (Flyology_Arena_Backed, Ada_Unbounded);

   procedure Dynamic_String_Batch
     (Which : Dynamic_String_Case; Iterations : Bench.Iteration_Count) is
   begin
      case Which is
         when Flyology_Arena_Backed =>
            Fly_Dynamic_String_Batch (Iterations);
         when Ada_Unbounded =>
            Ada_String_Batch (Iterations);
      end case;
   end Dynamic_String_Batch;

   procedure Compare_Dynamic_Strings is new Bench.Compare_Many
     (Case_Id => Dynamic_String_Case, Batch => Dynamic_String_Batch);
   procedure Put_Dynamic_Strings is new
     Reporters.Put_Multi_Comparison_Console (Dynamic_String_Case);

   type Contended_Vector_Case is
     (Flyology_Try, Flyology_Wait, Std_Mutex, Boost_Mutex);
   subtype Contended_Vector_Core is
     Contended_Vector_Case range Flyology_Try .. Std_Mutex;
   procedure Contended_Vector_Batch
     (Which : Contended_Vector_Case; Iterations : Bench.Iteration_Count)
   is
      Retries : U64;
   begin
      case Which is
         when Flyology_Try =>
            Run_Vector_Contention (Iterations, Retries);
         when Flyology_Wait =>
            Run_Vector_Wait (Iterations, Retries);
         when Std_Mutex =>
            CPP_Contention_Run
              (0, 0, Iterations, Contention_Workers, Retries);
         when Boost_Mutex =>
            CPP_Contention_Run
              (0, 1, Iterations, Contention_Workers, Retries);
      end case;
      Checksum := Checksum xor Retries xor U64 (Iterations);
   end Contended_Vector_Batch;

   procedure Contended_Vector_Core_Batch
     (Which : Contended_Vector_Core; Iterations : Bench.Iteration_Count) is
   begin
      Contended_Vector_Batch (Which, Iterations);
   end Contended_Vector_Core_Batch;

   procedure Compare_Contended_Vectors is new Bench.Compare_Many
     (Case_Id => Contended_Vector_Case, Batch => Contended_Vector_Batch);
   procedure Compare_Contended_Vector_Core is new Bench.Compare_Many
     (Case_Id => Contended_Vector_Core,
      Batch => Contended_Vector_Core_Batch);
   procedure Put_Contended_Vectors is new
     Reporters.Put_Multi_Comparison_Console (Contended_Vector_Case);
   procedure Put_Contended_Vector_Core is new
     Reporters.Put_Multi_Comparison_Console (Contended_Vector_Core);

   type Contended_Map_Case is
     (Flyology_Try, Flyology_Wait,
      Std_Mutex, Boost_Mutex, Abseil_Mutex);
   subtype Contended_Map_Core is
     Contended_Map_Case range Flyology_Try .. Std_Mutex;
   subtype Contended_Map_Boost is
     Contended_Map_Case range Flyology_Try .. Boost_Mutex;
   procedure Contended_Map_Batch
     (Which : Contended_Map_Case; Iterations : Bench.Iteration_Count)
   is
      Retries : U64;
   begin
      case Which is
         when Flyology_Try =>
            Run_Map_Contention (Iterations, Retries);
         when Flyology_Wait =>
            Run_Map_Wait (Iterations, Retries);
         when Std_Mutex =>
            CPP_Contention_Run
              (1, 0, Iterations, Contention_Workers, Retries);
         when Boost_Mutex =>
            CPP_Contention_Run
              (1, 1, Iterations, Contention_Workers, Retries);
         when Abseil_Mutex =>
            CPP_Contention_Run
              (1, 2, Iterations, Contention_Workers, Retries);
      end case;
      Checksum := Checksum xor Retries xor U64 (Iterations);
   end Contended_Map_Batch;

   procedure Contended_Map_Core_Batch
     (Which : Contended_Map_Core; Iterations : Bench.Iteration_Count) is
   begin
      Contended_Map_Batch (Which, Iterations);
   end Contended_Map_Core_Batch;

   procedure Contended_Map_Boost_Batch
     (Which : Contended_Map_Boost; Iterations : Bench.Iteration_Count) is
   begin
      Contended_Map_Batch (Which, Iterations);
   end Contended_Map_Boost_Batch;

   procedure Compare_Contended_Maps is new Bench.Compare_Many
     (Case_Id => Contended_Map_Case, Batch => Contended_Map_Batch);
   procedure Compare_Contended_Map_Core is new Bench.Compare_Many
     (Case_Id => Contended_Map_Core, Batch => Contended_Map_Core_Batch);
   procedure Compare_Contended_Map_Boost is new Bench.Compare_Many
     (Case_Id => Contended_Map_Boost, Batch => Contended_Map_Boost_Batch);
   procedure Put_Contended_Maps is new
     Reporters.Put_Multi_Comparison_Console (Contended_Map_Case);
   procedure Put_Contended_Map_Core is new
     Reporters.Put_Multi_Comparison_Console (Contended_Map_Core);
   procedure Put_Contended_Map_Boost is new
     Reporters.Put_Multi_Comparison_Console (Contended_Map_Boost);

   type Contended_String_Case is
     (Flyology_Try, Flyology_Wait, Std_Mutex);
   procedure Contended_String_Batch
     (Which : Contended_String_Case; Iterations : Bench.Iteration_Count)
   is
      Retries : U64;
   begin
      case Which is
         when Flyology_Try =>
            Run_String_Contention (Iterations, Retries);
         when Flyology_Wait =>
            Run_String_Wait (Iterations, Retries);
         when Std_Mutex =>
            CPP_Contention_Run
              (2, 0, Iterations, Contention_Workers, Retries);
      end case;
      Checksum := Checksum xor Retries xor U64 (Iterations);
   end Contended_String_Batch;

   procedure Compare_Contended_Strings is new Bench.Compare_Many
     (Case_Id => Contended_String_Case, Batch => Contended_String_Batch);
   procedure Put_Contended_Strings is new
     Reporters.Put_Multi_Comparison_Console (Contended_String_Case);

   type Contended_Queue_Case is
     (Flyology_Try, Flyology_Wait, Std_Deque_Mutex, Boost_Lockfree);
   subtype Contended_Queue_Core is
     Contended_Queue_Case range Flyology_Try .. Std_Deque_Mutex;
   procedure Contended_SPSC_Batch
     (Which : Contended_Queue_Case; Iterations : Bench.Iteration_Count)
   is
      Retries : U64;
   begin
      case Which is
         when Flyology_Try =>
            Run_SPSC_Try (Iterations, Retries);
         when Flyology_Wait =>
            Run_SPSC_Wait (Iterations, Retries);
         when Std_Deque_Mutex =>
            CPP_Contention_Run (3, 0, Iterations, 2, Retries);
         when Boost_Lockfree =>
            CPP_Contention_Run (3, 1, Iterations, 2, Retries);
      end case;
      Checksum := Checksum xor Retries xor U64 (Iterations);
   end Contended_SPSC_Batch;

   procedure Contended_SPSC_Core_Batch
     (Which : Contended_Queue_Core; Iterations : Bench.Iteration_Count) is
   begin
      Contended_SPSC_Batch (Which, Iterations);
   end Contended_SPSC_Core_Batch;

   procedure Contended_MPMC_Batch
     (Which : Contended_Queue_Case; Iterations : Bench.Iteration_Count)
   is
      Retries : U64;
   begin
      case Which is
         when Flyology_Try =>
            Run_MPMC_Try (Iterations, Retries);
         when Flyology_Wait =>
            Run_MPMC_Wait (Iterations, Retries);
         when Std_Deque_Mutex =>
            CPP_Contention_Run
              (4, 0, Iterations, Contention_Workers, Retries);
         when Boost_Lockfree =>
            CPP_Contention_Run
              (4, 1, Iterations, Contention_Workers, Retries);
      end case;
      Checksum := Checksum xor Retries xor U64 (Iterations);
   end Contended_MPMC_Batch;

   procedure Contended_MPMC_Core_Batch
     (Which : Contended_Queue_Core; Iterations : Bench.Iteration_Count) is
   begin
      Contended_MPMC_Batch (Which, Iterations);
   end Contended_MPMC_Core_Batch;

   procedure Compare_Contended_SPSC is new Bench.Compare_Many
     (Case_Id => Contended_Queue_Case, Batch => Contended_SPSC_Batch);
   procedure Compare_Contended_SPSC_Core is new Bench.Compare_Many
     (Case_Id => Contended_Queue_Core, Batch => Contended_SPSC_Core_Batch);
   procedure Compare_Contended_MPMC is new Bench.Compare_Many
     (Case_Id => Contended_Queue_Case, Batch => Contended_MPMC_Batch);
   procedure Compare_Contended_MPMC_Core is new Bench.Compare_Many
     (Case_Id => Contended_Queue_Core, Batch => Contended_MPMC_Core_Batch);
   procedure Put_Contended_Queues is new
     Reporters.Put_Multi_Comparison_Console (Contended_Queue_Case);
   procedure Put_Contended_Queue_Core is new
     Reporters.Put_Multi_Comparison_Console (Contended_Queue_Core);

   type Contended_Slab_Case is (Flyology_Try, Flyology_Wait);

   procedure Contended_Slab_Batch
     (Which : Contended_Slab_Case; Iterations : Bench.Iteration_Count)
   is
      Retries : U64;
   begin
      case Which is
         when Flyology_Try =>
            Run_Slab_Contention (Iterations, Retries);
         when Flyology_Wait =>
            Run_Slab_Wait (Iterations, Retries);
      end case;
      Checksum := Checksum xor Retries xor U64 (Iterations);
   end Contended_Slab_Batch;

   procedure Compare_Contended_Slab is new Bench.Compare_Many
     (Case_Id => Contended_Slab_Case, Batch => Contended_Slab_Batch);
   procedure Put_Contended_Slab is new
     Reporters.Put_Multi_Comparison_Console (Contended_Slab_Case);

   Base_Config : constant Bench.Configuration :=
     (Warmup_Time                  => 0.040,
      Measurement_Time             => Measurement_Time,
      Maximum_Sampling_Time        => 2.0 * Measurement_Time,
      Samples                      => Samples,
      Minimum_Sample_Time          => 0.000_200,
      Maximum_Iterations           => Maximum_Iterations,
      Comparison_Batching          => Bench.Equal_Time,
      Shootout_Scheduling          => Bench.Balanced_Rounds,
      Subtract_Timer_Cost          => False,
      Practical_Threshold_Percent => 1.0,
      Random_Seed                  => 42,
      Collect_Process_Telemetry    => False,
      CPU_Quiescence               => (others => <>),
      Progress                     => null,
      Progress_Name                => <>);

   function Terminal_Config (Name : String) return Bench.Configuration is
     (Reporters.Terminal_Mode (Base_Config, Name));

   Multi_Result : Bench.Multi_Comparison;
   Slab_Result  : Bench.Measurement;
   Have_Boost   : constant Boolean := CPP_Have_Boost /= 0;
   Have_Abseil  : constant Boolean := CPP_Have_Abseil /= 0;

begin
   if Contention_Workers < 2 or else Contention_Workers mod 2 /= 0 then
      raise Program_Error with
        "contention worker count must be an even integer of at least two";
   end if;

   if Posix_Memalign
     (Base'Access, 64, Interfaces.C.size_t (Region_Length)) /= 0
   then
      raise Storage_Error with "unable to allocate aligned benchmark region";
   end if;

   Regions.Attach (Region, Base, Region_Length);
   Vectors.Initialize
     (Fly_Vector, Region, Vector_Location, Working_Capacity);
   Hash_Maps.Initialize
     (Fly_Map, Region, Map_Location, Map_Capacity);
   SPSC.Initialize
     (Fly_SPSC, Region, SPSC_Location, Working_Capacity);
   MPMC.Initialize
     (Fly_MPMC, Region, MPMC_Location, Working_Capacity);
   Slab_Pools.Initialize
     (Fly_Slab, Region, Slab_Location, Working_Capacity);
   Byte_Strings.Initialize (Fly_String, Region, String_Location, 8);
   Arenas.Initialize
     (Fly_Arena, Region, Arena_Location,
      (Usable_Capacity => 262_144, Minimum_Block_Size => 64),
      16#B34C_7A91_04D2_EE01#);
   Dynamic_Vectors.Initialize
     (Fly_Dynamic_Vector, Region, Dynamic_Vector_Location,
      Fly_Arena, Working_Capacity);
   Dynamic_Maps.Initialize
     (Fly_Dynamic_Map, Region, Dynamic_Map_Location,
      Fly_Arena, Map_Capacity);
   Dynamic_Strings.Initialize
     (Fly_Dynamic_String, Region, Dynamic_String_Location,
      Fly_Arena, 8);
   Standard_Vector.Reserve_Capacity
     (Ada.Containers.Count_Type (Working_Capacity));
   Standard_Map.Reserve_Capacity
     (Ada.Containers.Count_Type (Map_Capacity));

   TIO.Put_Line ("");
   TIO.Put_Line ("Flyology address-independent data-structure shootout");
   TIO.Put_Line
     ("  Ada/Flyology compiler: GNAT; C++ shim: "
      & Interfaces.C.Strings.Value (CPP_Compiler));
   TIO.Put_Line
     ("  adaptive ceiling=" & Maximum_Iterations'Image
      & " iterations/sample, samples=" & Samples'Image
      & ", target=" & Measurement_Time'Image & " s/shootout");
   TIO.Put_Line
     ("  one logical operation is one mutation plus one observation; "
      & "lower ns/op is faster");
   TIO.Put_Line
     ("  raw C++ rows are not concurrency-safe; *_MUTEX rows lock each public "
      & "mutation and observation separately");
   if not Have_Boost then
      TIO.Put_Line ("  Boost headers unavailable: Boost rows omitted");
   end if;
   if not Have_Abseil then
      TIO.Put_Line
        ("  Abseil unavailable or ABI-incompatible: Abseil rows omitted");
   end if;

   if Have_Boost then
      Compare_Vectors
        (Config => Terminal_Config ("vector shootout"),
         Result => Multi_Result);
      Put_Vectors (Multi_Result);
   else
      Compare_Vector_Core
        (Config => Terminal_Config ("vector shootout"),
         Result => Multi_Result);
      Put_Vector_Core (Multi_Result);
   end if;

   if Have_Abseil then
      Compare_Maps
        (Config => Terminal_Config ("hash map shootout"),
         Result => Multi_Result);
      Put_Maps (Multi_Result);
   elsif Have_Boost then
      Compare_Map_Boost
        (Config => Terminal_Config ("hash map shootout"),
         Result => Multi_Result);
      Put_Map_Boost (Multi_Result);
   else
      Compare_Map_Core
        (Config => Terminal_Config ("hash map shootout"),
         Result => Multi_Result);
      Put_Map_Core (Multi_Result);
   end if;

   Compare_Strings
     (Config => Terminal_Config ("byte string shootout"),
      Result => Multi_Result);
   Put_Strings (Multi_Result);

   if Have_Boost then
      Compare_SPSC
        (Config => Terminal_Config ("SPSC queue shootout"),
         Result => Multi_Result);
      Put_SPSC (Multi_Result);
   else
      Compare_SPSC_Core
        (Config => Terminal_Config ("SPSC queue shootout"),
         Result => Multi_Result);
      Put_SPSC_Core (Multi_Result);
   end if;

   if Have_Boost then
      Compare_MPMC
        (Config => Terminal_Config ("MPMC queue shootout"),
         Result => Multi_Result);
      Put_MPMC (Multi_Result);
   else
      Compare_MPMC_Core
        (Config => Terminal_Config ("MPMC queue shootout"),
         Result => Multi_Result);
      Put_MPMC_Core (Multi_Result);
   end if;

   Measure_Slab
     (Config => Terminal_Config ("slab pool"), Result => Slab_Result);
   Reporters.Put_Console
     ("Flyology_Data_Structures_Slab_Pools", Slab_Result);

   TIO.New_Line;
   TIO.Put_Line ("Allocator-backed steady-state throughput");
   TIO.Put_Line
     ("  Flyology rows retain already-grown arena allocations; growth and "
      & "rehashing are excluded");

   Compare_Dynamic_Vectors
     (Config => Terminal_Config ("arena-backed vector"),
      Result => Multi_Result);
   Put_Dynamic_Vectors (Multi_Result);

   Compare_Dynamic_Maps
     (Config => Terminal_Config ("arena-backed hash map"),
      Result => Multi_Result);
   Put_Dynamic_Maps (Multi_Result);

   Compare_Dynamic_Strings
     (Config => Terminal_Config ("arena-backed byte string"),
      Result => Multi_Result);
   Put_Dynamic_Strings (Multi_Result);

   Measure_Arena
     (Config => Terminal_Config ("buddy arena allocation cycle"),
      Result => Slab_Result);
   Reporters.Put_Console
     ("Flyology_Arenas_Allocate_Write_Read_Release", Slab_Result);

   TIO.Put_Line
     ("checksum=" & Checksum'Image
      & "; preceding results are uncontended amortized throughput");

   Dynamic_Strings.Destroy (Fly_Dynamic_String, Fly_Arena);
   Dynamic_Maps.Destroy (Fly_Dynamic_Map, Fly_Arena);
   Dynamic_Vectors.Destroy (Fly_Dynamic_Vector, Fly_Arena);
   Arenas.Destroy (Fly_Arena);
   Byte_Strings.Destroy (Fly_String);
   Slab_Pools.Destroy (Fly_Slab);
   MPMC.Destroy (Fly_MPMC);
   SPSC.Destroy (Fly_SPSC);
   Hash_Maps.Destroy (Fly_Map);
   Vectors.Destroy (Fly_Vector);

   TIO.New_Line;
   TIO.Put_Line ("Contended native-task throughput");
   TIO.Put_Line
     ("  " & Contention_Workers'Image
      & " synchronized native workers; queue rows use matched producers and "
      & "consumers");
   TIO.Put_Line
     ("  one vector/map/string/slab operation or one delivered queue item; "
      & "lower ns/op is higher aggregate throughput");

   if Have_Boost then
      Compare_Contended_Vectors
        (Config => Terminal_Config ("contended vector"),
         Result => Multi_Result);
      Put_Contended_Vectors (Multi_Result);
   else
      Compare_Contended_Vector_Core
        (Config => Terminal_Config ("contended vector"),
         Result => Multi_Result);
      Put_Contended_Vector_Core (Multi_Result);
   end if;

   if Have_Abseil then
      Compare_Contended_Maps
        (Config => Terminal_Config ("contended hash map"),
         Result => Multi_Result);
      Put_Contended_Maps (Multi_Result);
   elsif Have_Boost then
      Compare_Contended_Map_Boost
        (Config => Terminal_Config ("contended hash map"),
         Result => Multi_Result);
      Put_Contended_Map_Boost (Multi_Result);
   else
      Compare_Contended_Map_Core
        (Config => Terminal_Config ("contended hash map"),
         Result => Multi_Result);
      Put_Contended_Map_Core (Multi_Result);
   end if;

   Compare_Contended_Strings
     (Config => Terminal_Config ("contended byte string"),
      Result => Multi_Result);
   Put_Contended_Strings (Multi_Result);

   if Have_Boost then
      Compare_Contended_SPSC
        (Config => Terminal_Config ("contended SPSC"),
         Result => Multi_Result);
      Put_Contended_Queues (Multi_Result);
   else
      Compare_Contended_SPSC_Core
        (Config => Terminal_Config ("contended SPSC"),
         Result => Multi_Result);
      Put_Contended_Queue_Core (Multi_Result);
   end if;

   if Have_Boost then
      Compare_Contended_MPMC
        (Config => Terminal_Config ("contended MPMC"),
         Result => Multi_Result);
      Put_Contended_Queues (Multi_Result);
   else
      Compare_Contended_MPMC_Core
        (Config => Terminal_Config ("contended MPMC"),
         Result => Multi_Result);
      Put_Contended_Queue_Core (Multi_Result);
   end if;

   Compare_Contended_Slab
     (Config => Terminal_Config ("contended slab"),
      Result => Multi_Result);
   Put_Contended_Slab (Multi_Result);

   TIO.Put_Line
     ("checksum=" & Checksum'Image
      & "; contention results include native-task/thread orchestration and "
      & "are not crash-recovery measurements");

   Regions.Detach (Region);
   C_Free (Base);
exception
   when others =>
      if Base /= System.Null_Address then
         C_Free (Base);
      end if;
      raise;
end Data_Structures_Benchmark;
