with Ada.Streams;
with Flyology_Allocators;
with Flyology_Allocators.Allocation_Algorithms.Best_Fit;
with Flyology_Allocators.Allocation_Algorithms.Buddy;
with Flyology_Allocators.Allocation_Algorithms.TLSF;
with Flyology_Allocators.Arenas;
with Flyology_Allocators.Regions;
with Interfaces;
with System.Address_To_Access_Conversions;

procedure Allocator_Smoke is
   package FA renames Flyology_Allocators;

   use type FA.Allocation_Algorithms.Allocation_Result;
   use type FA.Byte_Count;
   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.Unsigned_8;

   package Buddy_Arenas is new FA.Arenas
     (FA.Allocation_Algorithms.Buddy);
   package Best_Fit_Arenas is new FA.Arenas
     (FA.Allocation_Algorithms.Best_Fit);
   package TLSF_Arenas is new FA.Arenas
     (FA.Allocation_Algorithms.TLSF);
   package U32_Pointers is new System.Address_To_Access_Conversions
     (Interfaces.Unsigned_32);
   package U8_Pointers is new System.Address_To_Access_Conversions
     (Interfaces.Unsigned_8);

   Storage_Length : constant := 262_144;
   subtype Storage_Range is
     Ada.Streams.Stream_Element_Offset range 1 .. Storage_Length;
   type Storage_Array is array (Storage_Range) of Ada.Streams.Stream_Element;

   Buddy_Storage    : aliased Storage_Array := [others => 0]
     with Alignment => 64;
   Best_Fit_Storage : aliased Storage_Array := [others => 0]
     with Alignment => 64;
   TLSF_Storage     : aliased Storage_Array := [others => 0]
     with Alignment => 64;

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   procedure Attach
     (Region  : in out FA.Regions.View;
      Storage : aliased in out Storage_Array) is
   begin
      FA.Regions.Attach
        (Region,
         Storage (Storage'First)'Address,
         FA.Byte_Count (Storage'Length));
   end Attach;

   Buddy_Region, Best_Fit_Region, TLSF_Region : FA.Regions.View;
   Buddy_Allocation : FA.Regions.View;
   Buddy_View : Buddy_Arenas.View;
   Best_Fit_View : Best_Fit_Arenas.View;
   TLSF_View : TLSF_Arenas.View;
   Buddy_Handle : Buddy_Arenas.Allocation_Handle;
   Best_Fit_Handle : Best_Fit_Arenas.Allocation_Handle;
   TLSF_Handle : TLSF_Arenas.Allocation_Handle;
   Result : FA.Allocation_Algorithms.Allocation_Result;
   Timed_Out : Boolean := False;
begin
   Attach (Buddy_Region, Buddy_Storage);
   Buddy_Arenas.Initialize
     (Buddy_View, Buddy_Region, 64,
      (Usable_Capacity => 65_536, Minimum_Block_Size => 64), 1);
   Buddy_Arenas.Try_Allocate (Buddy_View, 65, Buddy_Handle, Result);
   Check
     (Result = FA.Allocation_Algorithms.Allocated
      and then Buddy_Arenas.Block_Capacity (Buddy_View, Buddy_Handle) = 128,
      "buddy allocation failed");
   Buddy_Arenas.Attach_Allocation
     (Buddy_Allocation, Buddy_View, Buddy_Handle);
   for Index in FA.Byte_Count range 0 .. 15 loop
      U8_Pointers.To_Pointer
        (FA.Regions.Address_At (Buddy_Allocation, Index, 1)).all :=
          Interfaces.Unsigned_8 (Index + 1);
   end loop;
   Buddy_Arenas.Copy
     (Buddy_View, Buddy_Handle, 0, Buddy_Handle, 4, 16);
   for Index in FA.Byte_Count range 0 .. 15 loop
      Check
        (U8_Pointers.To_Pointer
           (FA.Regions.Address_At (Buddy_Allocation, Index + 4, 1)).all =
           Interfaces.Unsigned_8 (Index + 1),
         "backward overlapping copy failed");
   end loop;
   Buddy_Arenas.Copy
     (Buddy_View, Buddy_Handle, 4, Buddy_Handle, 0, 16);
   for Index in FA.Byte_Count range 0 .. 15 loop
      Check
        (U8_Pointers.To_Pointer
           (FA.Regions.Address_At (Buddy_Allocation, Index, 1)).all =
           Interfaces.Unsigned_8 (Index + 1),
         "forward overlapping copy failed");
   end loop;
   FA.Regions.Detach (Buddy_Allocation);
   Buddy_Arenas.Release (Buddy_View, Buddy_Handle);

   --  The buddy guard is algorithm metadata at offset 44 from the allocator
   --  start. Force contention while no task can own the arena, then verify the
   --  standard-runtime deadline and cooperative retry path.
   U32_Pointers.To_Pointer
     (Buddy_Storage (Buddy_Storage'First + 64 + 44)'Address).all := 1;
   begin
      Buddy_Arenas.Try_Allocate
        (Buddy_View, 64, 0.001, Buddy_Handle, Result);
   exception
      when FA.Timeout_Error =>
         Timed_Out := True;
   end;
   U32_Pointers.To_Pointer
     (Buddy_Storage (Buddy_Storage'First + 64 + 44)'Address).all := 0;
   Check (Timed_Out, "timed retry did not expire under contention");
   Buddy_Arenas.Destroy (Buddy_View);

   Attach (Best_Fit_Region, Best_Fit_Storage);
   Best_Fit_Arenas.Initialize
     (Best_Fit_View, Best_Fit_Region, 64,
      (Usable_Capacity => 65_536, Minimum_Block_Size => 64), 2);
   Best_Fit_Arenas.Try_Allocate
     (Best_Fit_View, 65, Best_Fit_Handle, Result);
   Check
     (Result = FA.Allocation_Algorithms.Allocated
      and then Best_Fit_Arenas.Block_Capacity
        (Best_Fit_View, Best_Fit_Handle) >= 65,
      "best-fit allocation failed");
   Best_Fit_Arenas.Release (Best_Fit_View, Best_Fit_Handle);
   Best_Fit_Arenas.Destroy (Best_Fit_View);

   Attach (TLSF_Region, TLSF_Storage);
   TLSF_Arenas.Initialize
     (TLSF_View, TLSF_Region, 64,
      (Usable_Capacity => 65_536, Minimum_Block_Size => 64), 3);
   TLSF_Arenas.Try_Allocate (TLSF_View, 65, TLSF_Handle, Result);
   Check
     (Result = FA.Allocation_Algorithms.Allocated
      and then TLSF_Arenas.Block_Capacity (TLSF_View, TLSF_Handle) >= 65,
      "TLSF allocation failed");
   TLSF_Arenas.Release (TLSF_View, TLSF_Handle);
   TLSF_Arenas.Destroy (TLSF_View);

   FA.Regions.Detach (Buddy_Region);
   FA.Regions.Detach (Best_Fit_Region);
   FA.Regions.Detach (TLSF_Region);
end Allocator_Smoke;
