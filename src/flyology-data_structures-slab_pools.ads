with Flyology.Data_Structures.Handles;
with Flyology.Data_Structures.Storage_Types.Elements;
with Interfaces;
private with Flyology.Data_Structures.Layouts;
private with System;

use type Interfaces.Unsigned_64;

--  Provides bounded fixed-size immutable-element allocation in relocatable
--  storage.
--  Stored slots contain generation, state, reserved metadata, and payload
--  bytes, but no address or access value. Allocation, reclamation, and payload
--  access are internally synchronized across native tasks,
--  processes, and distinct mappings. Initialization, attachment, destruction,
--  and backing-region lifetime changes require quiescence across every view.
--  Concurrent Create_Or_Attach calls are allowed only on
--  allocation-certified virgin bytes; if Ready may exist, attachment
--  quiescence applies. Lifecycle operations must also be excluded from
--  ordinary use of the same local View.
--  Immediate operations retain bounded contention outcomes or Busy_Error;
--  timed overloads yield through one explicit timeout.
--  Termination during an operation leaves its slot abandoned rather than
--  silently reusable; an external recovery authority may poison and reclaim
--  that slot only after establishing owner death and target-slot quiescence.
--  @formal Element Immutable byte-backed element adapter stored by this slab

generic
   with package Element is new Flyology.Data_Structures.Storage_Types.Elements (<>);
package Flyology.Data_Structures.Slab_Pools with Preelaborate is

   --  Eight-byte magic stored in every slab header.
   Magic : constant Interfaces.Unsigned_64 := 16#4644_534C_4142_3031#;

   --  Schema identifier for the current fixed-width slab layout.
   Schema : constant Interfaces.Unsigned_64 :=
     16#0002_534C_4142_0003#
     xor Element.Signature
     xor Interfaces.Shift_Left (Interfaces.Unsigned_64 (Element.Version), 32);

   --  Leaf-specific stored-layout version.
   Layout_Version : constant Interfaces.Unsigned_32 := 4;

   --  Complete stable layout identity for envelope instances and tooling.
   Identity : constant Layout_Identity := (Magic => Magic, Version => Layout_Version, Schema => Schema);

   --  Maximum compare/exchange attempts made by one immediate claim
   --  campaign. Timed overloads may use shorter campaigns between yields.
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
   --  @return Required header, metadata, padding, and payload bytes
   --  @exception Constraint_Error Alignment or arithmetic is invalid
   function Required_Storage (Capacity : Positive) return Byte_Count;

   --  Create a new slab at Location and attach Item. The caller must
   --  exclusively own the complete target extent. Initialization publishes a
   --  ready state with a release store only after all metadata is complete.
   --  Every preexisting view becomes stale and must attach again.
   --  @param Item View attached on success
   --  @param Region Attached backing region
   --  @param Location Nonzero aligned stored offset
   --  @param Capacity Number of slots
   --  @exception Region_Error Region or extent is invalid
   --  @exception Constraint_Error Configuration cannot be represented
   procedure Initialize
     (Item : out View; Region : Region_View; Location : Region_Offset; Capacity : Positive);

   --  Atomically initialize a known-virgin zeroed extent or attach to a ready
   --  compatible slab. Only the exact zero lifecycle sentinel is eligible for
   --  creation; no existing lifecycle is reinitialized. The operation does
   --  not wait for another initializer.
   --  Concurrent calls are permitted only while the allocation protocol
   --  guarantees virgin bytes; if Ready may exist, Attach quiescence applies.
   --  @param Item Attached view, or detached when initialization is in
   --     progress
   --  @param Region Independently attached backing region
   --  @param Location Stored slab offset
   --  @param Capacity Expected slot count
   --  @param Result Whether this caller initialized, attached, or observed an
   --     initialization in progress
   procedure Create_Or_Attach
     (Item     : out View;
      Region   : Region_View;
      Location : Region_Offset;
      Capacity : Positive;
      Result   : out Open_Result);

   --  Attach to a quiescent existing slab and validate its complete layout,
   --  slot states, generations, and expected configuration. Valid transitional
   --  and poisoned slots remain attachable so a recovery authority need not
   --  retain a pre-failure View.
   --  @param Item View attached on success
   --  @param Region Independently attached backing region
   --  @param Location Stored slab offset
   --  @param Capacity Expected slot count
   --  @exception Layout_Error Stored data is incompatible or corrupt
   --  @exception Region_Error Region or extent is invalid
   procedure Attach (Item : out View; Region : Region_View; Location : Region_Offset; Capacity : Positive);

   --  Detach Item without changing backing bytes or reclaiming live slots.
   --  @param Item Local view to detach
   procedure Detach (Item : in out View);

   --  Report whether Item is locally attached.
   --  @param Item View to inspect
   --  @return True while Item retains local mapping information; this does not
   --     guarantee the cached initialization epoch is still current
   function Is_Attached (Item : View) return Boolean;

   --  Return the immutable stored configuration.
   --  @param Item Attached view
   --  @return Validated slab metadata
   --  @exception Region_Error Item is detached
   function Current_Metadata (Item : View) return Metadata;

   --  Attempt to create and allocate one free slot without waiting. The handle
   --  is published only after the bound creator returns. Every outcome is
   --  bounded by one scan of the validated capacity. A process that terminates
   --  after the slot becomes live but before it records the returned handle
   --  leaves a committed allocation that cannot be identified from the slab
   --  alone; applications needing recovery must journal that ownership or
   --  exclusively reinitialize the whole pool.
   --  @param Item Any concurrently attached slab view
   --  @param Data Application value accepted by the bound creator
   --  @param Value New generation-stamped handle or Null_Handle
   --  @param Result Allocated, exhausted, or bounded-contention outcome
   procedure Try_Allocate
     (Item : in out View; Data : Element.Source; Value : out Handles.Handle; Result : out Allocation_Result);

   --  Retry bounded allocation contention through one timeout. A genuinely
   --  exhausted slab still returns Exhausted immediately after a full scan.
   --  @param Item Any concurrently attached slab view
   --  @param Data Application value accepted by the bound creator
   --  @param Timeout Maximum wait; zero permits one bounded scan
   --  @param Value New generation-stamped handle or Null_Handle
   --  @param Result Allocated or exhausted outcome
   --  @exception Timeout_Error Free-slot claims contend through the deadline
   procedure Try_Allocate
     (Item    : in out View;
      Data    : Element.Source;
      Timeout : Wait_Timeout;
      Value   : out Handles.Handle;
      Result  : out Allocation_Result);

   --  Reclaim Value and advance its generation so every copy becomes stale.
   --  Releasing the maximum generation permanently poisons that slot until
   --  exclusive whole-pool initialization instead of wrapping to an old stamp.
   --  @param Item Any concurrently attached slab view
   --  @param Value Live handle returned by this slab
   --  @exception Handle_Error Value is null, malformed, stale, or reclaimed
   --  @exception Busy_Error The bounded claim budget is exhausted
   --  @exception Poison_Error Value addresses a poisoned slot
   --     or its generation is exhausted and the slot was retired
   --  @exception Layout_Error Slot bookkeeping is corrupt
   procedure Release (Item : in out View; Value : Handles.Handle);

   --  Reclaim Value after waiting through transient same-slot contention.
   --  @param Item Any concurrently attached slab view
   --  @param Value Live handle returned by this slab
   --  @param Timeout Maximum wait; zero permits one bounded claim campaign
   --  @exception Timeout_Error Slot contention persists through the deadline
   procedure Release (Item : in out View; Value : Handles.Handle; Timeout : Wait_Timeout);

   --  Observe exactly one immutable slot without copying its representation.
   --  @param Item Any concurrently attached slab view
   --  @param Value Live handle returned by this slab
   --  @param Data Observation assigned only on success
   --  @exception Handle_Error Value is invalid or stale
   --  @exception Busy_Error The bounded claim budget is exhausted
   --  @exception Poison_Error Value addresses a poisoned slot
   procedure Read (Item : View; Value : Handles.Handle; Data : out Element.Observed);

   --  Read one slot after waiting through transient same-slot contention.
   --  @param Item Any concurrently attached slab view
   --  @param Value Live handle returned by this slab
   --  @param Data Observation assigned only on success
   --  @param Timeout Maximum wait; zero permits one bounded claim campaign
   --  @exception Timeout_Error Slot contention persists through the deadline
   procedure Read (Item : View; Value : Handles.Handle; Data : out Element.Observed; Timeout : Wait_Timeout);

   --  Replace exactly one immutable slot from Data. Independent creation
   --  completes before the slot claim, so a raising creator cannot mutate it.
   --  @param Item Any concurrently attached slab view
   --  @param Value Live handle returned by this slab
   --  @param Data Application value accepted by the bound creator
   --  @exception Handle_Error Value is invalid or stale
   --  @exception Busy_Error The bounded claim budget is exhausted
   --  @exception Poison_Error Value addresses a poisoned slot
   procedure Replace (Item : in out View; Value : Handles.Handle; Data : Element.Source);

   --  Replace one slot after waiting through transient same-slot contention.
   --  @param Item Any concurrently attached slab view
   --  @param Value Live handle returned by this slab
   --  @param Data Application value accepted by the bound creator
   --  @param Timeout Maximum wait; zero permits one bounded claim campaign
   --  @exception Timeout_Error Slot contention persists through the deadline
   procedure Replace
     (Item : in out View; Value : Handles.Handle; Data : Element.Source; Timeout : Wait_Timeout);

   --  Mark a transitional slot abandoned. The caller is the recovery
   --  authority and must first establish that its owner has terminated and
   --  that no operation can still access the target slot. Live and free slots
   --  are rejected; an already poisoned slot is accepted idempotently.
   --  @param Item Any attached slab view
   --  @param Slot One-based slot selected by the recovery authority
   --  @exception Handle_Error Slot is null or out of range
   --  @exception Program_Error Slot is live or free rather than abandoned
   --  @exception Busy_Error The bounded poison claim budget expires
   procedure Poison_Abandoned (Item : in out View; Slot : Handles.Slot_Index);

   --  Validate immutable slab identity and geometry, then poison a
   --  transitional slot without requiring a retained pre-failure View or
   --  traversing unrelated mutable slots. The caller must establish owner
   --  death and target-slot quiescence before calling it.
   --  @param Region Attached backing region
   --  @param Location Stored slab offset
   --  @param Capacity Expected slot count
   --  @param Slot One-based slot selected by the recovery authority
   --  @exception Layout_Error Immutable identity or geometry is incompatible
   --  @exception Handle_Error Slot is null or out of range
   --  @exception Program_Error Slot is live or free rather than abandoned
   --  @exception Busy_Error The bounded poison claim budget expires
   procedure Poison_Abandoned_At
     (Region : Region_View; Location : Region_Offset; Capacity : Positive; Slot : Handles.Slot_Index);

   --  Explicitly recycle a poisoned slot after external recovery authority
   --  has established target-slot quiescence. The generation advances before
   --  the slot is published, so every earlier handle remains stale. A maximum
   --  generation cannot advance and remains poisoned until whole-object
   --  exclusive Initialize. Other failures also leave the slot poisoned.
   --  @param Item Any attached slab view
   --  @param Slot One-based poisoned slot to reclaim
   --  @exception Handle_Error Slot is null or out of range
   --  @exception Program_Error Slot is not poisoned
   --  @exception Poison_Error The slot generation is exhausted
   procedure Recover_Poisoned (Item : in out View; Slot : Handles.Slot_Index);

   --  Invalidate an empty slab and detach Item. Every view and handle must be
   --  quiescent; live slots make destruction fail rather than leak ownership.
   --  @param Item Exclusively synchronized slab view
   --  @exception Program_Error One or more slots remain live
   procedure Destroy (Item : in out View);

   pragma Inline (Try_Allocate, Release, Read, Replace);

private
   type View is limited record
      Core                      : Layouts.Local_View;
      Capacity_Value            : Interfaces.Unsigned_32 := 0;
      Element_Value             : Interfaces.Unsigned_32 := 0;
      Alignment_Value           : Interfaces.Unsigned_32 := 0;
      Payload_Offset            : Byte_Count := 0;
      Stride                    : Byte_Count := 0;
      Allocation_Cursor_Address : System.Address := System.Null_Address;
   end record;
end Flyology.Data_Structures.Slab_Pools;
