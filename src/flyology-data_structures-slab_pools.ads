with Ada.Streams;
with Flyology.Data_Structures.Handles;
with Interfaces;
private with Flyology.Data_Structures.Layouts;
private with System;

--  Provides bounded fixed-size byte-slot allocation in relocatable storage.
--  Stored slots contain generation, state, reserved metadata, and payload bytes;
--  they contain no address or access value. Allocation, reclamation, and
--  payload access are internally synchronized across native tasks, processes,
--  and distinct mappings. Initialization, attachment, destruction, and
--  backing-region lifetime changes require quiescence across every view.
--  Termination during an operation leaves its slot abandoned rather than
--  silently reusable; an external recovery authority may poison and reclaim
--  that slot only after establishing owner death and target-slot quiescence.
package Flyology.Data_Structures.Slab_Pools with Preelaborate is

   --  Eight-byte magic stored in every slab header.
   Magic : constant Interfaces.Unsigned_64 := 16#4644_534C_4142_3031#;

   --  Schema identifier for the current fixed-width slab layout.
   Schema : constant Interfaces.Unsigned_64 := 16#0002_534C_4142_0001#;

   --  Leaf-specific stored-layout version.
   Layout_Version : constant Interfaces.Unsigned_32 := 2;

   --  Complete stable layout identity for envelope instances and tooling.
   Identity : constant Layout_Identity :=
     (Magic => Magic, Version => Layout_Version, Schema => Schema);

   --  Maximum compare/exchange attempts made by one operation.
   Contention_Limit : constant Positive := 64;

   --  Allocation outcome.
   --  @enum Allocated A slot was claimed and Value contains its handle
   --  @enum Exhausted No free slot was observed during the capacity scan
   --  @enum Allocation_Contended A concurrently claimed free slot was observed
   type Allocation_Result is (Allocated, Exhausted, Allocation_Contended);

   --  Process-local attached view. It owns neither the backing region nor any
   --  allocated slot and must be detached before the backing bytes disappear.
   type View is limited private;

   --  Immutable stored configuration reported by an attached view.
   --  @field Capacity Number of independently allocatable slots
   --  @field Element_Size Payload bytes in each slot
   --  @field Element_Alignment Required payload alignment
   --  @field Extent Complete stored layout size in bytes
   type Metadata is record
      Capacity          : Interfaces.Unsigned_32;
      Element_Size      : Interfaces.Unsigned_32;
      Element_Alignment : Interfaces.Unsigned_32;
      Extent            : Byte_Count;
   end record;

   --  Compute the complete layout extent without touching a region.
   --  @param Capacity Number of slots
   --  @param Element_Size Payload bytes per slot
   --  @param Element_Alignment Power-of-two payload alignment
   --  @return Required header, metadata, padding, and payload bytes
   --  @exception Constraint_Error Alignment or arithmetic is invalid
   function Required_Storage
     (Capacity          : Positive;
      Element_Size      : Positive;
      Element_Alignment : Positive := 1) return Byte_Count;

   --  Create a new slab at Location and attach Item. The caller must
   --  exclusively own the complete target extent. Initialization publishes a
   --  ready state with a release store only after all metadata is complete.
   --  @param Item View attached on success
   --  @param Region Attached backing region
   --  @param Location Nonzero aligned stored offset
   --  @param Capacity Number of slots
   --  @param Element_Size Payload bytes per slot
   --  @param Element_Alignment Power-of-two payload alignment
   --  @exception Region_Error Region or extent is invalid
   --  @exception Constraint_Error Configuration cannot be represented
   procedure Initialize
     (Item              : out View;
      Region            : Region_View;
      Location          : Region_Offset;
      Capacity          : Positive;
      Element_Size      : Positive;
      Element_Alignment : Positive := 1);

   --  Attach to a quiescent existing slab and validate its complete layout,
   --  slot states, generations, and expected configuration. Valid transitional
   --  and poisoned slots remain attachable so a recovery authority need not
   --  retain a pre-failure View.
   --  @param Item View attached on success
   --  @param Region Independently attached backing region
   --  @param Location Stored slab offset
   --  @param Capacity Expected slot count
   --  @param Element_Size Expected payload size
   --  @param Element_Alignment Expected payload alignment
   --  @exception Layout_Error Stored data is incompatible or corrupt
   --  @exception Region_Error Region or extent is invalid
   procedure Attach
     (Item              : out View;
      Region            : Region_View;
      Location          : Region_Offset;
      Capacity          : Positive;
      Element_Size      : Positive;
      Element_Alignment : Positive := 1);

   --  Detach Item without changing backing bytes or reclaiming live slots.
   --  @param Item Local view to detach
   procedure Detach (Item : in out View);

   --  Report whether Item is locally attached.
   --  @param Item View to inspect
   --  @return True only while Item retains local mapping information
   function Is_Attached (Item : View) return Boolean;

   --  Return the immutable stored configuration.
   --  @param Item Attached view
   --  @return Validated slab metadata
   --  @exception Region_Error Item is detached
   function Current_Metadata (Item : View) return Metadata;

   --  Attempt to allocate one free slot without waiting. Every outcome is
   --  bounded by one scan of the validated capacity.
   --  @param Item Any concurrently attached slab view
   --  @param Value New generation-stamped handle or Null_Handle
   --  @param Result Allocated, exhausted, or bounded-contention outcome
   procedure Try_Allocate
     (Item      : in out View;
      Value     : out Handles.Handle;
      Result    : out Allocation_Result);

   --  Reclaim Value and advance its generation so every copy becomes stale.
   --  @param Item Any concurrently attached slab view
   --  @param Value Live handle returned by this slab
   --  @exception Handle_Error Value is null, malformed, stale, or reclaimed
   --  @exception Busy_Error The bounded claim budget is exhausted
   --  @exception Poison_Error Value addresses a poisoned slot
   --  @exception Layout_Error Slot bookkeeping is corrupt
   procedure Release
     (Item  : in out View;
      Value : Handles.Handle);

   --  Copy exactly one slot payload into Data.
   --  @param Item Any concurrently attached slab view
   --  @param Value Live handle returned by this slab
   --  @param Data Destination whose length must equal Element_Size
   --  @exception Handle_Error Value is invalid or stale
   --  @exception Constraint_Error Data has the wrong length
   --  @exception Busy_Error The bounded claim budget is exhausted
   --  @exception Poison_Error Value addresses a poisoned slot
   procedure Read
     (Item  : View;
      Value : Handles.Handle;
      Data  : out Ada.Streams.Stream_Element_Array);

   --  Replace exactly one slot payload from Data.
   --  @param Item Any concurrently attached slab view
   --  @param Value Live handle returned by this slab
   --  @param Data Source whose length must equal Element_Size
   --  @exception Handle_Error Value is invalid or stale
   --  @exception Constraint_Error Data has the wrong length
   --  @exception Busy_Error The bounded claim budget is exhausted
   --  @exception Poison_Error Value addresses a poisoned slot
   procedure Write
     (Item  : in out View;
      Value : Handles.Handle;
      Data  : Ada.Streams.Stream_Element_Array);

   --  Mark a transitional slot abandoned. The caller is the recovery
   --  authority and must first establish that its owner has terminated and
   --  that no operation can still access the target slot. Live and free slots
   --  are rejected; an already poisoned slot is accepted idempotently.
   --  @param Item Any attached slab view
   --  @param Slot One-based slot selected by the recovery authority
   --  @exception Handle_Error Slot is null or out of range
   --  @exception Program_Error Slot is live or free rather than abandoned
   --  @exception Busy_Error The bounded poison claim budget expires
   procedure Poison_Abandoned
     (Item : in out View;
      Slot : Handles.Slot_Index);

   --  Validate immutable slab identity and geometry, then poison a
   --  transitional slot without attaching or traversing mutable slot contents.
   --  This is the recovery entry point when normal Attach cannot validate
   --  abandoned bookkeeping. The caller must establish owner death and
   --  target-slot quiescence before calling it.
   --  @param Region Attached backing region
   --  @param Location Stored slab offset
   --  @param Capacity Expected slot count
   --  @param Element_Size Expected payload size
   --  @param Element_Alignment Expected payload alignment
   --  @param Slot One-based slot selected by the recovery authority
   --  @exception Layout_Error Immutable identity or geometry is incompatible
   --  @exception Handle_Error Slot is null or out of range
   --  @exception Program_Error Slot is live or free rather than abandoned
   --  @exception Busy_Error The bounded poison claim budget expires
   procedure Poison_Abandoned_At
     (Region            : Region_View;
      Location          : Region_Offset;
      Capacity          : Positive;
      Element_Size      : Positive;
      Element_Alignment : Positive;
      Slot              : Handles.Slot_Index);

   --  Explicitly recycle a poisoned slot after external recovery authority
   --  has established target-slot quiescence. The generation advances before
   --  the slot is published, so every earlier handle remains stale. Failure
   --  leaves the slot poisoned. Whole-object exclusive Initialize remains an
   --  unconditional recovery path.
   --  @param Item Any attached slab view
   --  @param Slot One-based poisoned slot to reclaim
   --  @exception Handle_Error Slot is null or out of range
   --  @exception Program_Error Slot is not poisoned
   procedure Recover_Poisoned
     (Item : in out View;
      Slot : Handles.Slot_Index);

   --  Invalidate an empty slab and detach Item. Every view and handle must be
   --  quiescent; live slots make destruction fail rather than leak ownership.
   --  @param Item Exclusively synchronized slab view
   --  @exception Program_Error One or more slots remain live
   procedure Destroy (Item : in out View);

   pragma Inline (Try_Allocate, Release, Read, Write);

private
   type View is limited record
      Core              : Layouts.Local_View;
      Capacity_Value    : Interfaces.Unsigned_32 := 0;
      Element_Value     : Interfaces.Unsigned_32 := 0;
      Alignment_Value   : Interfaces.Unsigned_32 := 0;
      Payload_Offset    : Byte_Count := 0;
      Stride            : Byte_Count := 0;
      Allocation_Cursor_Address : System.Address := System.Null_Address;
   end record;
end Flyology.Data_Structures.Slab_Pools;
