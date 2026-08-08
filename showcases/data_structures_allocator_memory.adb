with Ada.Text_IO;
with Flyology.Data_Structures;
with Flyology.Data_Structures.Allocation_Algorithms.Best_Fit;
with Flyology.Data_Structures.Allocation_Algorithms.Buddy;
with Flyology.Data_Structures.Allocation_Algorithms.TLSF;
with Flyology.Data_Structures.Allocation_Pools.Adaptive;
with Flyology.Data_Structures.Arenas;
with Flyology.Data_Structures.Regions;
with Flyology.Data_Structures.Slab_Pools;
with Flyology.Data_Structures.Storage_Types.Unsigned_64s;
with Interfaces;
with Interfaces.C;
with System;

procedure Data_Structures_Allocator_Memory is
   package DS renames Flyology.Data_Structures;
   package Regions renames DS.Regions;
   package Buddy_Arenas is new DS.Arenas
     (Algorithm => DS.Allocation_Algorithms.Buddy);
   package Best_Fit_Arenas is new DS.Arenas
     (Algorithm => DS.Allocation_Algorithms.Best_Fit);
   package TLSF_Arenas is new DS.Arenas
     (Algorithm => DS.Allocation_Algorithms.TLSF);
   package U64_Elements renames DS.Storage_Types.Unsigned_64s;
   package Measurement_Slabs is new DS.Slab_Pools
     (Element => U64_Elements.Element);
   package Adaptive_U64 is new DS.Allocation_Pools.Adaptive
     (Arena_Provider  => TLSF_Arenas,
      Element         => U64_Elements.Element,
      Slots_Per_Chunk => 64,
      Maximum_Chunks  => 16);

   use type DS.Byte_Count;
   use type Buddy_Arenas.Allocation_Result;
   use type Adaptive_U64.Allocation_Result;
   use type Interfaces.C.int;
   use type System.Address;

   function Posix_Memalign
     (Result    : access System.Address;
      Alignment : Interfaces.C.size_t;
      Size      : Interfaces.C.size_t) return Interfaces.C.int;
   pragma Import (C, Posix_Memalign, "posix_memalign");

   procedure C_Free (Address : System.Address);
   pragma Import (C, C_Free, "free");

   procedure Put_Number (Value : DS.Byte_Count) is
   begin
      Ada.Text_IO.Put (DS.Byte_Count'Image (Value));
   end Put_Number;

   generic
      with package Provider is new DS.Arenas (<>);
   procedure Measure
     (Name          : String;
      Configuration : Provider.Configuration;
      Instance      : Interfaces.Unsigned_64);

   procedure Measure
     (Name          : String;
      Configuration : Provider.Configuration;
      Instance      : Interfaces.Unsigned_64)
   is
      Extent : constant DS.Byte_Count :=
        Provider.Required_Storage (Configuration);
      Location : constant DS.Region_Offset := 64;
      Region_Length : constant DS.Byte_Count := Extent + 128;
      Base   : aliased System.Address := System.Null_Address;
      Region : Regions.View;
      Arena  : Provider.View;
      Metadata : Provider.Metadata;
      Slot_Count : constant := 256;
      type Handle_Array is
        array (Positive range <>) of Provider.Allocation_Handle;
      Handles : Handle_Array (1 .. Slot_Count) :=
        [others => Provider.Null_Allocation];
      Requests : array (Positive range 1 .. Slot_Count) of Natural :=
        [others => 0];
      Live : array (Positive range 1 .. Slot_Count) of Boolean :=
        [others => False];
      Result : Provider.Allocation_Result;
      Fragment_Live_Requested : DS.Byte_Count := 0;
      Fragment_Live_Capacity  : DS.Byte_Count := 0;
      Largest_Fragment_Request : DS.Byte_Count := 0;
      Exhausted_Requested : DS.Byte_Count := 0;
      Exhausted_Capacity  : DS.Byte_Count := 0;
      Exhausted_Count     : Natural := 0;
      Low, High, Middle : DS.Byte_Count;
      Probe : Provider.Allocation_Handle;

      procedure Release_All is
      begin
         for Index in Live'Range loop
            if Live (Index) then
               Provider.Release (Arena, Handles (Index));
               Live (Index) := False;
            end if;
         end loop;
      end Release_All;
   begin
      if Posix_Memalign
        (Base'Access, 64, Interfaces.C.size_t (Region_Length)) /= 0
      then
         raise Storage_Error with "unable to allocate allocator memory arena";
      end if;
      Regions.Attach (Region, Base, Region_Length);
      Provider.Initialize
        (Arena, Region, Location, Configuration, Instance);
      Metadata := Provider.Current_Metadata (Arena);

      for Index in Handles'Range loop
         Requests (Index) := 1 + (Index * 73 mod 2_047);
         Provider.Try_Allocate
           (Arena, Requests (Index), Handles (Index), Result);
         exit when Result = Provider.Exhausted;
         if Result /= Provider.Allocated then
            raise Program_Error with
              "single-task fragmentation trace observed contention";
         end if;
         Live (Index) := True;
      end loop;
      for Index in Live'Range loop
         if Live (Index) and then Index mod 2 = 0 then
            Provider.Release (Arena, Handles (Index));
            Live (Index) := False;
         elsif Live (Index) then
            Fragment_Live_Requested := Fragment_Live_Requested
              + DS.Byte_Count (Requests (Index));
            Fragment_Live_Capacity := Fragment_Live_Capacity
              + Provider.Block_Capacity (Arena, Handles (Index));
         end if;
      end loop;

      Low := 1;
      High := DS.Byte_Count (Metadata.Usable_Capacity);
      while Low <= High loop
         Middle := Low + (High - Low) / 2;
         Provider.Try_Allocate
           (Arena, Positive (Middle), Probe, Result);
         if Result = Provider.Allocated then
            Largest_Fragment_Request := Middle;
            Provider.Release (Arena, Probe);
            Low := Middle + 1;
         elsif Result = Provider.Exhausted then
            exit when Middle = 0;
            High := Middle - 1;
         else
            raise Program_Error with
              "single-task largest-block probe observed contention";
         end if;
      end loop;
      Release_All;

      for Index in Handles'Range loop
         Requests (Index) := 1 + (Index * 151 mod 2_047);
         Provider.Try_Allocate
           (Arena, Requests (Index), Handles (Index), Result);
         exit when Result = Provider.Exhausted;
         if Result /= Provider.Allocated then
            raise Program_Error with
              "single-task exhaustion trace observed contention";
         end if;
         Live (Index) := True;
         Exhausted_Count := Exhausted_Count + 1;
         Exhausted_Requested := Exhausted_Requested
           + DS.Byte_Count (Requests (Index));
         Exhausted_Capacity := Exhausted_Capacity
           + Provider.Block_Capacity (Arena, Handles (Index));
      end loop;

      Ada.Text_IO.Put (Name);
      Ada.Text_IO.Put (" | extent");
      Put_Number (Extent);
      Ada.Text_IO.Put (" | outer metadata");
      Put_Number (Extent - DS.Byte_Count (Metadata.Usable_Capacity));
      Ada.Text_IO.Put (" | fragmented live requested");
      Put_Number (Fragment_Live_Requested);
      Ada.Text_IO.Put (" | fragmented live capacity");
      Put_Number (Fragment_Live_Capacity);
      Ada.Text_IO.Put (" | largest fragmented request");
      Put_Number (Largest_Fragment_Request);
      Ada.Text_IO.Put (" | exhaustion allocations" & Exhausted_Count'Image);
      Ada.Text_IO.Put (" | exhaustion requested");
      Put_Number (Exhausted_Requested);
      Ada.Text_IO.Put (" | exhaustion capacity");
      Put_Number (Exhausted_Capacity);
      Ada.Text_IO.New_Line;

      Release_All;
      Provider.Destroy (Arena);
      Regions.Detach (Region);
      C_Free (Base);
      Base := System.Null_Address;
   exception
      when others =>
         if Base /= System.Null_Address then
            C_Free (Base);
         end if;
         raise;
   end Measure;

   procedure Measure_Buddy is new Measure (Provider => Buddy_Arenas);
   procedure Measure_Best_Fit is new Measure (Provider => Best_Fit_Arenas);
   procedure Measure_TLSF is new Measure (Provider => TLSF_Arenas);

   procedure Measure_Adaptive_Pool is
      Arena_Configuration : constant TLSF_Arenas.Configuration :=
        (Usable_Capacity => 262_144, Minimum_Block_Size => 64);
      Arena_Extent : constant DS.Byte_Count :=
        TLSF_Arenas.Required_Storage (Arena_Configuration);
      Arena_Location : constant DS.Region_Offset := 64;
      Pool_Location : constant DS.Region_Offset := DS.Region_Offset
        ((DS.Byte_Count (Arena_Location) + Arena_Extent + 63) / 64 * 64);
      Region_Length : constant DS.Byte_Count :=
        DS.Byte_Count (Pool_Location) + Adaptive_U64.Required_Storage + 64;
      Chunk_Request : constant DS.Byte_Count :=
        64 + Measurement_Slabs.Required_Storage (64);
      Allocation_Count : constant Positive := 256;
      type Handle_Array is
        array (Positive range <>) of Adaptive_U64.Handle;
      Handles : Handle_Array (1 .. Allocation_Count);
      Base : aliased System.Address := System.Null_Address;
      Region : Regions.View;
      Arena : TLSF_Arenas.View;
      Pool : Adaptive_U64.View;
      Result : Adaptive_U64.Allocation_Result;
      Chunks : Interfaces.Unsigned_32 := 0;
   begin
      if Posix_Memalign
        (Base'Access, 64, Interfaces.C.size_t (Region_Length)) /= 0
      then
         raise Storage_Error with
           "unable to allocate adaptive-pool memory arena";
      end if;
      Regions.Attach (Region, Base, Region_Length);
      TLSF_Arenas.Initialize
        (Arena, Region, Arena_Location, Arena_Configuration,
         16#715F_0000_0000_0002#);
      Adaptive_U64.Initialize (Pool, Region, Pool_Location, Arena);
      for Index in Handles'Range loop
         Adaptive_U64.Try_Allocate
           (Pool, Arena, Interfaces.Unsigned_64 (Index),
            Handles (Index), Result);
         if Result /= Adaptive_U64.Allocated then
            raise Program_Error with
              "adaptive-pool memory trace exhausted unexpectedly";
         end if;
         Chunks := Interfaces.Unsigned_32'Max
           (Chunks, Handles (Index).Chunk);
      end loop;

      Ada.Text_IO.Put ("adaptive TLSF pool | outer extent");
      Put_Number (Adaptive_U64.Required_Storage);
      Ada.Text_IO.Put (" | chunks" & Chunks'Image);
      Ada.Text_IO.Put (" | chunk request");
      Put_Number (Chunk_Request);
      Ada.Text_IO.Put (" | arena bytes requested");
      Put_Number (DS.Byte_Count (Chunks) * Chunk_Request);
      Ada.Text_IO.Put (" | live elements" & Allocation_Count'Image);
      Ada.Text_IO.Put (" | live payload");
      Put_Number
        (DS.Byte_Count (Allocation_Count)
         * DS.Byte_Count (U64_Elements.Element.Size));
      Ada.Text_IO.New_Line;

      for Handle of Handles loop
         Adaptive_U64.Release (Pool, Arena, Handle);
      end loop;
      Adaptive_U64.Destroy (Pool, Arena);
      TLSF_Arenas.Destroy (Arena);
      Regions.Detach (Region);
      C_Free (Base);
      Base := System.Null_Address;
   exception
      when others =>
         if Base /= System.Null_Address then
            C_Free (Base);
         end if;
         raise;
   end Measure_Adaptive_Pool;

begin
   Ada.Text_IO.Put_Line
     ("Deterministic allocator memory/fragmentation trace (bytes)");
   Ada.Text_IO.Put_Line
     ("Nominal managed capacity is 262144 for each row; live capacity "
      & "excludes allocator block prefixes.");
   Measure_Buddy
     ("buddy",
      (Usable_Capacity => 262_144, Minimum_Block_Size => 64),
      16#BADD_0000_0000_0001#);
   Measure_Best_Fit
     ("best fit",
      (Usable_Capacity => 262_144, Minimum_Block_Size => 64),
      16#B35F_0000_0000_0001#);
   Measure_TLSF
     ("TLSF",
      (Usable_Capacity => 262_144, Minimum_Block_Size => 64),
      16#715F_0000_0000_0001#);
   Measure_Adaptive_Pool;
end Data_Structures_Allocator_Memory;
