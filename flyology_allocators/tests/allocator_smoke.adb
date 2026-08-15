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
   use type FA.Allocation_Algorithms.Search_Bound;
   use type FA.Allocation_Algorithms.Allocation_Handle;
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

   type Buddy_Handle_Array is array (Positive range <>) of
     Buddy_Arenas.Allocation_Handle;

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
   Buddy_Peer_View : Buddy_Arenas.View;
   Buddy_Tiny_View : Buddy_Arenas.View;
   Best_Fit_View : Best_Fit_Arenas.View;
   TLSF_View : TLSF_Arenas.View;
   Buddy_Handle : Buddy_Arenas.Allocation_Handle;
   Buddy_Peer_Handle : Buddy_Arenas.Allocation_Handle;
   Buddy_Tiny_Left, Buddy_Tiny_Right : Buddy_Arenas.Allocation_Handle;
   Buddy_Small_Handles : Buddy_Handle_Array (1 .. 1_024);
   Best_Fit_Handle : Best_Fit_Arenas.Allocation_Handle;
   Best_Fit_Probe : Best_Fit_Arenas.Allocation_Handle;
   type Best_Fit_Handle_Array is array (Positive range <>) of
     Best_Fit_Arenas.Allocation_Handle;
   type Index_Array is array (Positive range <>) of Positive;
   Alternating_Indices : constant Index_Array := [1, 5, 7];
   Remaining_Indices : constant Index_Array := [1, 2, 5, 6, 7, 8];
   Best_Fit_Handles : Best_Fit_Handle_Array (1 .. 8);
   Stale_Best_Fit_Handle : Best_Fit_Arenas.Allocation_Handle;
   Saw_Stale_Best_Fit : Boolean := False;
   TLSF_Handle : TLSF_Arenas.Allocation_Handle;
   type TLSF_Handle_Array is array (Natural range 0 .. 7) of
     TLSF_Arenas.Allocation_Handle;
   TLSF_Handles : TLSF_Handle_Array :=
     [others => TLSF_Arenas.Null_Allocation];
   Result : FA.Allocation_Algorithms.Allocation_Result;
   Timed_Out : Boolean := False;
   Stale_Rejected : Boolean := False;
   Destroy_Rejected : Boolean := False;
begin
   Attach (Buddy_Region, Buddy_Storage);
   Buddy_Arenas.Initialize
     (Buddy_View, Buddy_Region, 64,
      (Usable_Capacity => 65_536, Minimum_Block_Size => 64), 1);
   Check
     (Buddy_Arenas.Capabilities.Search =
        FA.Allocation_Algorithms.Linear
      and then not Buddy_Arenas.Capabilities.Coalesces_On_Release,
      "buddy lazy-coalescing capabilities are inaccurate");
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

   --  Retained split nodes must not create false exhaustion. Fill every leaf,
   --  release the left half, and require a half-arena allocation that can be
   --  satisfied only by lazily joining those released buddies. Then release
   --  everything and require the same fallback to rebuild the root block.
   for Index in Buddy_Small_Handles'Range loop
      Buddy_Arenas.Try_Allocate
        (Buddy_View, 64, Buddy_Small_Handles (Index), Result);
      Check
        (Result = FA.Allocation_Algorithms.Allocated,
         "buddy leaf fill failed");
   end loop;
   for Index in 1 .. 512 loop
      Buddy_Arenas.Release (Buddy_View, Buddy_Small_Handles (Index));
   end loop;
   begin
      declare
         Ignored : constant FA.Byte_Count := Buddy_Arenas.Block_Capacity
           (Buddy_View, Buddy_Small_Handles (1));
         pragma Unreferenced (Ignored);
      begin
         null;
      end;
   exception
      when FA.Handle_Error =>
         Stale_Rejected := True;
   end;
   Check (Stale_Rejected, "buddy lazy release accepted a stale handle");
   Buddy_Arenas.Try_Allocate (Buddy_View, 32_768, Buddy_Handle, Result);
   Check
     (Result = FA.Allocation_Algorithms.Allocated
      and then Buddy_Arenas.Block_Capacity (Buddy_View, Buddy_Handle) = 32_768,
      "buddy lazy half-tree coalescing failed");
   Buddy_Arenas.Release (Buddy_View, Buddy_Handle);
   for Index in 513 .. 1_024 loop
      Buddy_Arenas.Release (Buddy_View, Buddy_Small_Handles (Index));
   end loop;
   Buddy_Arenas.Try_Allocate (Buddy_View, 65_536, Buddy_Handle, Result);
   Check
     (Result = FA.Allocation_Algorithms.Allocated
      and then Buddy_Arenas.Block_Capacity (Buddy_View, Buddy_Handle) = 65_536,
      "buddy lazy root coalescing failed");
   Buddy_Arenas.Release (Buddy_View, Buddy_Handle);

   --  A process-local reuse hint may be stale when another attached view
   --  consumes its node. The persisted state remains authoritative and must
   --  prevent the first view from allocating the same bytes concurrently.
   Buddy_Arenas.Attach
     (Buddy_Peer_View, Buddy_Region, 64,
      (Usable_Capacity => 65_536, Minimum_Block_Size => 64), 1);
   Buddy_Arenas.Try_Allocate
     (Buddy_Peer_View, 65_536, Buddy_Peer_Handle, Result);
   Check
     (Result = FA.Allocation_Algorithms.Allocated,
      "buddy peer root allocation failed");
   Buddy_Arenas.Try_Allocate (Buddy_View, 65_536, Buddy_Handle, Result);
   Check
     (Result = FA.Allocation_Algorithms.Exhausted,
      "buddy stale local hint duplicated a peer allocation");
   Buddy_Arenas.Release (Buddy_Peer_View, Buddy_Peer_Handle);
   Buddy_Arenas.Try_Allocate (Buddy_View, 65_536, Buddy_Handle, Result);
   Check
     (Result = FA.Allocation_Algorithms.Allocated,
      "buddy allocation did not recover from a stale local hint");
   Buddy_Arenas.Release (Buddy_View, Buddy_Handle);
   Buddy_Arenas.Detach (Buddy_Peer_View);

   Buddy_Arenas.Try_Allocate (Buddy_View, 64, Buddy_Handle, Result);
   Check
     (Result = FA.Allocation_Algorithms.Allocated,
      "buddy live-destroy allocation failed");
   begin
      Buddy_Arenas.Destroy (Buddy_View);
   exception
      when FA.Layout_Error =>
         Destroy_Rejected := True;
   end;
   Check
     (Destroy_Rejected
      and then not Buddy_Arenas.Is_Poisoned (Buddy_View)
      and then Buddy_Arenas.Block_Capacity (Buddy_View, Buddy_Handle) = 64,
      "buddy live destroy mutated or poisoned a usable arena");
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

   --  The eager reader accepted this retained state but falsely reported
   --  exhaustion: a split root with two free leaves must satisfy a root-sized
   --  request through the coalesce-and-retry fallback.
   Buddy_Arenas.Initialize
     (Buddy_Tiny_View, Buddy_Region, 200_000,
      (Usable_Capacity => 128, Minimum_Block_Size => 64), 4);
   Buddy_Arenas.Try_Allocate
     (Buddy_Tiny_View, 64, Buddy_Tiny_Left, Result);
   Check
     (Result = FA.Allocation_Algorithms.Allocated,
      "buddy tiny left allocation failed");
   Buddy_Arenas.Try_Allocate
     (Buddy_Tiny_View, 64, Buddy_Tiny_Right, Result);
   Check
     (Result = FA.Allocation_Algorithms.Allocated,
      "buddy tiny right allocation failed");
   Buddy_Arenas.Release (Buddy_Tiny_View, Buddy_Tiny_Left);
   Buddy_Arenas.Release (Buddy_Tiny_View, Buddy_Tiny_Right);
   Buddy_Arenas.Try_Allocate
     (Buddy_Tiny_View, 128, Buddy_Tiny_Left, Result);
   Check
     (Result = FA.Allocation_Algorithms.Allocated
      and then Buddy_Arenas.Block_Capacity
        (Buddy_Tiny_View, Buddy_Tiny_Left) = 128,
      "buddy retained two-leaf root falsely exhausted");
   Buddy_Arenas.Release (Buddy_Tiny_View, Buddy_Tiny_Left);
   Buddy_Arenas.Destroy (Buddy_Tiny_View);

   Attach (Best_Fit_Region, Best_Fit_Storage);
   Best_Fit_Arenas.Initialize
     (Best_Fit_View, Best_Fit_Region, 64,
      (Usable_Capacity => 1_024, Minimum_Block_Size => 64), 2);
   for Index in Best_Fit_Handles'Range loop
      Best_Fit_Arenas.Try_Allocate
        (Best_Fit_View, 64, Best_Fit_Handles (Index), Result);
      Check
        (Result = FA.Allocation_Algorithms.Allocated,
         "best-fit fill allocation failed");
   end loop;

   --  Lazy release keeps both adjacent blocks indexed. Attachment must accept
   --  and validate that representation, while a larger allocation must merge
   --  the run and retry rather than report false exhaustion.
   Stale_Best_Fit_Handle := Best_Fit_Handles (3);
   Best_Fit_Arenas.Release (Best_Fit_View, Best_Fit_Handles (3));
   Best_Fit_Arenas.Release (Best_Fit_View, Best_Fit_Handles (4));
   Best_Fit_Arenas.Detach (Best_Fit_View);
   Best_Fit_Arenas.Attach
     (Best_Fit_View, Best_Fit_Region, 64,
      (Usable_Capacity => 1_024, Minimum_Block_Size => 64), 2);
   Best_Fit_Arenas.Try_Allocate
     (Best_Fit_View, 160, Best_Fit_Handle, Result);
   Check
     (Result = FA.Allocation_Algorithms.Allocated
      and then Best_Fit_Arenas.Block_Capacity
        (Best_Fit_View, Best_Fit_Handle) >= 160,
      "best-fit deferred coalescing reported false exhaustion");
   begin
      Best_Fit_Arenas.Release (Best_Fit_View, Stale_Best_Fit_Handle);
   exception
      when FA.Handle_Error =>
         Saw_Stale_Best_Fit := True;
   end;
   Check (Saw_Stale_Best_Fit, "best-fit accepted a stale merged handle");

   --  Exercise exact-block reuse with alternating physical gaps, then leave
   --  the arena as multiple adjacent frees for Destroy to canonicalize.
   for Index of Alternating_Indices loop
      Best_Fit_Arenas.Release (Best_Fit_View, Best_Fit_Handles (Index));
   end loop;
   Best_Fit_Arenas.Try_Allocate
     (Best_Fit_View, 160, Best_Fit_Probe, Result);
   Check
     (Result = FA.Allocation_Algorithms.Exhausted
      and then Best_Fit_Probe = Best_Fit_Arenas.Null_Allocation,
      "best-fit joined nonadjacent alternating gaps");
   for Index of Alternating_Indices loop
      Best_Fit_Arenas.Try_Allocate
        (Best_Fit_View, 64, Best_Fit_Handles (Index), Result);
      Check
        (Result = FA.Allocation_Algorithms.Allocated,
         "best-fit alternating-gap reuse failed");
   end loop;
   Best_Fit_Arenas.Release (Best_Fit_View, Best_Fit_Handle);
   for Index of Remaining_Indices loop
      Best_Fit_Arenas.Release (Best_Fit_View, Best_Fit_Handles (Index));
   end loop;
   Best_Fit_Arenas.Destroy (Best_Fit_View);

   Attach (TLSF_Region, TLSF_Storage);
   Check
     (TLSF_Arenas.Capabilities.Search =
        FA.Allocation_Algorithms.Linear
      and then not TLSF_Arenas.Capabilities.Coalesces_On_Release,
      "TLSF lazy-coalescing capabilities are inaccurate");
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

   --  Fill a small arena so a larger request can succeed only by merging the
   --  two adjacent blocks released below. Attachment must accept and validate
   --  the deliberately uncoalesced but fully indexed physical chain.
   TLSF_Arenas.Initialize
     (TLSF_View, TLSF_Region, 64,
      (Usable_Capacity => 1_024, Minimum_Block_Size => 64), 3);
   for Index in TLSF_Handles'Range loop
      TLSF_Arenas.Try_Allocate
        (TLSF_View, 64, TLSF_Handles (Index), Result);
      Check (Result = FA.Allocation_Algorithms.Allocated,
             "TLSF adjacent-coalescing setup failed");
   end loop;
   TLSF_Arenas.Release (TLSF_View, TLSF_Handles (0));
   TLSF_Arenas.Release (TLSF_View, TLSF_Handles (1));
   begin
      declare
         Ignored : constant FA.Byte_Count :=
           TLSF_Arenas.Block_Capacity (TLSF_View, TLSF_Handles (0));
      begin
         Check (Ignored = 0, "released TLSF handle retained capacity");
      end;
   exception
      when FA.Handle_Error =>
         Stale_Rejected := True;
   end;
   Check (Stale_Rejected, "TLSF accepted a released handle");
   TLSF_Arenas.Detach (TLSF_View);
   TLSF_Arenas.Attach
     (TLSF_View, TLSF_Region, 64,
      (Usable_Capacity => 1_024, Minimum_Block_Size => 64), 3);
   TLSF_Arenas.Try_Allocate (TLSF_View, 192, TLSF_Handle, Result);
   Check (Result = FA.Allocation_Algorithms.Allocated,
          "TLSF did not coalesce adjacent free blocks on demand");
   TLSF_Arenas.Release (TLSF_View, TLSF_Handle);
   for Index in 2 .. TLSF_Handles'Last loop
      TLSF_Arenas.Release (TLSF_View, TLSF_Handles (Index));
   end loop;
   TLSF_Arenas.Destroy (TLSF_View);

   --  Alternating free blocks must remain unavailable to a larger request.
   --  Releasing the intervening block then makes exactly one sufficient run.
   TLSF_Arenas.Initialize
     (TLSF_View, TLSF_Region, 64,
      (Usable_Capacity => 1_024, Minimum_Block_Size => 64), 3);
   for Index in TLSF_Handles'Range loop
      TLSF_Arenas.Try_Allocate
        (TLSF_View, 64, TLSF_Handles (Index), Result);
      Check (Result = FA.Allocation_Algorithms.Allocated,
             "TLSF fragmented-coalescing setup failed");
   end loop;
   for Index in TLSF_Handles'Range loop
      if Index mod 2 = 0 then
         TLSF_Arenas.Release (TLSF_View, TLSF_Handles (Index));
      end if;
   end loop;
   TLSF_Arenas.Try_Allocate (TLSF_View, 192, TLSF_Handle, Result);
   Check (Result = FA.Allocation_Algorithms.Exhausted,
          "TLSF coalesced across an allocated gap");
   TLSF_Arenas.Release (TLSF_View, TLSF_Handles (1));
   TLSF_Arenas.Try_Allocate (TLSF_View, 320, TLSF_Handle, Result);
   Check (Result = FA.Allocation_Algorithms.Allocated,
          "TLSF did not merge a mixed-size free run");
   TLSF_Arenas.Release (TLSF_View, TLSF_Handle);
   for Index in TLSF_Handles'Range loop
      if Index mod 2 = 1 and then Index /= 1 then
         TLSF_Arenas.Release (TLSF_View, TLSF_Handles (Index));
      end if;
   end loop;
   TLSF_Arenas.Destroy (TLSF_View);

   FA.Regions.Detach (Buddy_Region);
   FA.Regions.Detach (Best_Fit_Region);
   FA.Regions.Detach (TLSF_Region);
end Allocator_Smoke;
