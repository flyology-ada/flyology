with Ada.Streams;
with Interfaces;
private with Flyology.Data_Structures.Layouts;
private with System;

--  Provides variable-size allocation inside a fixed caller-owned relocatable
--  region. The stored buddy tree contains only fixed-width states and
--  generations. Allocation and reclamation are serialized across mappings by
--  one persisted nonblocking guard; immediate allocation reports contention
--  and timed overloads yield between attempts. Payload access does not acquire
--  that metadata guard: the application or receiving data structure must
--  exclude release of a handle from reads, writes, and copies using it.
--  A dead metadata-guard owner leaves the arena locked. An independently
--  authorized supervisor may poison the arena after establishing owner death
--  and whole-arena quiescence; exclusive reinitialization is the only
--  recovery.
package Flyology.Data_Structures.Arenas with Preelaborate is

   --  Eight-byte magic stored in every arena header.
   Magic : constant Interfaces.Unsigned_64 := 16#4644_5341_5245_3031#;

   --  Schema identifier for the buddy-tree allocation contract.
   Schema : constant Interfaces.Unsigned_64 := 16#0001_4152_454E_0001#;

   --  Leaf-specific stored-layout version.
   Layout_Version : constant Interfaces.Unsigned_32 := 1;

   --  Complete stable layout identity for envelopes and tooling.
   Identity : constant Layout_Identity :=
     (Magic => Magic, Version => Layout_Version, Schema => Schema);

   --  Minimum supported buddy block and guaranteed payload alignment.
   Minimum_Block_Limit : constant Positive := 16;

   --  Stable allocation identity. Node is a buddy-tree slot rather than a
   --  native address. Arena_Epoch rejects handles across arena
   --  reinitialization; Generation rejects a released and reused node.
   --  @field Node Zero-based buddy-tree node index
   --  @field Arena_Epoch Persisted arena initialization epoch
   --  @field Generation Monotonic nonzero allocation generation
   type Allocation_Handle is record
      Node        : Interfaces.Unsigned_32 := 0;
      Arena_Epoch : Interfaces.Unsigned_32 := 0;
      Generation  : Interfaces.Unsigned_64 := 0;
   end record;

   --  Null allocation relationship.
   Null_Allocation : constant Allocation_Handle :=
     (Node => 0, Arena_Epoch => 0, Generation => 0);

   --  Allocation attempt outcome.
   --  @enum Allocated Value names a newly allocated block
   --  @enum Exhausted No free buddy block can satisfy Requested_Size
   --  @enum Allocation_Contended Another caller owns the metadata guard
   type Allocation_Result is
     (Allocated, Exhausted, Allocation_Contended);

   --  Process-local attached arena view. It owns neither the backing region
   --  nor any allocation and must be detached before the mapping disappears.
   type View is limited private;

   --  Immutable stored arena configuration.
   --  @field Usable_Capacity Bytes managed by the buddy tree
   --  @field Minimum_Block_Size Smallest block and payload alignment
   --  @field Instance_ID Caller-selected nonzero arena identity
   --  @field Incarnation Persisted initialization epoch for dependencies
   --  @field Extent Complete arena header, tree, padding, and payload extent
   type Metadata is record
      Usable_Capacity   : Interfaces.Unsigned_32;
      Minimum_Block_Size : Interfaces.Unsigned_32;
      Instance_ID       : Interfaces.Unsigned_64;
      Incarnation       : Interfaces.Unsigned_32;
      Extent            : Byte_Count;
   end record;

   --  Compute the complete arena extent. Both sizes must be powers of two,
   --  Minimum_Block_Size must be at least Minimum_Block_Limit, and usable
   --  capacity must be an exact multiple of the minimum block.
   --  @param Usable_Capacity Payload bytes managed by the buddy tree
   --  @param Minimum_Block_Size Smallest block and payload alignment
   --  @return Required shared header, node table, padding, and payload bytes
   --  @exception Constraint_Error Geometry is invalid or cannot be represented
   function Required_Storage
     (Usable_Capacity    : Positive;
      Minimum_Block_Size : Positive) return Byte_Count;

   --  Destructively initialize an empty arena and attach Item. The caller must
   --  exclusively own the complete extent. Reinitialization invalidates every
   --  allocation handle and attached arena-dependent structure.
   --  @param Item View attached on success
   --  @param Region Attached caller-owned backing region
   --  @param Location Nonzero location aligned to Minimum_Block_Size
   --  @param Usable_Capacity Power-of-two managed payload bytes
   --  @param Minimum_Block_Size Power-of-two minimum block and alignment
   --  @param Instance_ID Nonzero caller-selected arena instance identity
   procedure Initialize
     (Item               : out View;
      Region             : Region_View;
      Location           : Region_Offset;
      Usable_Capacity    : Positive;
      Minimum_Block_Size : Positive;
      Instance_ID        : Interfaces.Unsigned_64);

   --  Atomically initialize allocation-certified virgin bytes or attach to a
   --  ready compatible arena. Every immutable creation parameter must match an
   --  existing arena. The operation does not wait for another initializer or
   --  the metadata guard. Concurrent calls are valid only while the outer
   --  allocation protocol still guarantees virgin bytes; otherwise attachment
   --  quiescence applies.
   --  @param Item Attached view, or detached while initialization is active
   --  @param Region Independently attached backing region
   --  @param Location Stored arena offset
   --  @param Usable_Capacity Expected managed payload bytes
   --  @param Minimum_Block_Size Expected minimum block and alignment
   --  @param Instance_ID Expected nonzero arena instance identity
   --  @param Result Creation, attachment, or in-progress outcome
   procedure Create_Or_Attach
     (Item               : out View;
      Region             : Region_View;
      Location           : Region_Offset;
      Usable_Capacity    : Positive;
      Minimum_Block_Size : Positive;
      Instance_ID        : Interfaces.Unsigned_64;
      Result             : out Open_Result);

   --  Attach to a quiescent arena and validate its complete buddy tree and
   --  immutable configuration.
   --  @param Item View attached on success
   --  @param Region Independently attached backing region
   --  @param Location Stored arena offset
   --  @param Usable_Capacity Expected managed payload bytes
   --  @param Minimum_Block_Size Expected minimum block and alignment
   --  @param Instance_ID Expected arena instance identity
   --  @exception Layout_Error Stored identity, geometry, or tree is corrupt
   --  @exception Busy_Error The arena metadata guard is active or abandoned
   --  @exception Poison_Error The arena lifecycle is poisoned
   procedure Attach
     (Item               : out View;
      Region             : Region_View;
      Location           : Region_Offset;
      Usable_Capacity    : Positive;
      Minimum_Block_Size : Positive;
      Instance_ID        : Interfaces.Unsigned_64);

   --  Detach Item without releasing allocations or modifying backing bytes.
   --  @param Item Local view to detach
   procedure Detach (Item : in out View);

   --  Report whether Item retains process-local mapping information.
   --  @param Item View to inspect
   --  @return True while the local arena view is attached
   function Is_Attached (Item : View) return Boolean;

   --  Return the immutable arena configuration.
   --  @param Item Attached arena view
   --  @return Validated arena metadata
   function Current_Metadata (Item : View) return Metadata;

   --  Report whether an attached arena was explicitly poisoned.
   --  @param Item Attached arena view
   --  @return True only for the persisted Poisoned lifecycle state
   function Is_Poisoned (Item : View) return Boolean;

   --  Poison a ready or abandoned-locked arena after independently
   --  establishing whole-arena quiescence and owner death where applicable.
   --  @param Region Attached backing region
   --  @param Location Stored arena offset
   procedure Poison (Region : Region_View; Location : Region_Offset);

   --  Attempt one variable-size allocation without waiting. Requested_Size is
   --  rounded to a buddy block and every returned block is aligned to the
   --  arena's Minimum_Block_Size.
   --  @param Item Any concurrently attached arena view
   --  @param Requested_Size Positive payload bytes requested
   --  @param Value New handle or Null_Allocation
   --  @param Result Allocated, exhausted, or contended outcome
   procedure Try_Allocate
     (Item           : in out View;
      Requested_Size : Positive;
      Value          : out Allocation_Handle;
      Result         : out Allocation_Result);

   --  Allocate after waiting only for metadata-guard contention. Genuine
   --  exhaustion still returns Exhausted after one complete search.
   --  @param Item Any concurrently attached arena view
   --  @param Requested_Size Positive payload bytes requested
   --  @param Timeout Maximum wait; zero permits one immediate attempt
   --  @param Value New handle or Null_Allocation
   --  @param Result Allocated or exhausted outcome
   --  @exception Timeout_Error Metadata contention persists through deadline
   procedure Try_Allocate
     (Item           : in out View;
      Requested_Size : Positive;
      Timeout        : Wait_Timeout;
      Value          : out Allocation_Handle;
      Result         : out Allocation_Result);

   --  Release a live allocation and coalesce free buddies. The caller must
   --  exclude every payload access through Value.
   --  @param Item Any concurrently attached arena view
   --  @param Value Live handle issued by this arena incarnation
   --  @exception Busy_Error Another caller owns the metadata guard
   --  @exception Handle_Error Value is null, stale, reclaimed, or foreign
   procedure Release (Item : in out View; Value : Allocation_Handle);

   --  Release after waiting for metadata-guard contention.
   --  @param Item Any concurrently attached arena view
   --  @param Value Live handle issued by this arena incarnation
   --  @param Timeout Maximum wait; zero permits one immediate attempt
   --  @exception Timeout_Error Metadata contention persists through deadline
   procedure Release
     (Item    : in out View;
      Value   : Allocation_Handle;
      Timeout : Wait_Timeout);

   --  Return the rounded capacity of a live allocation.
   --  @param Item Attached arena view
   --  @param Value Live allocation handle
   --  @return Usable bytes in the selected buddy block
   --  @exception Handle_Error Value is invalid or stale
   function Block_Capacity
     (Item : View; Value : Allocation_Handle) return Byte_Count;

   --  Attach Region to the exact bytes of a live allocation. No native address
   --  is returned or persisted. The resulting region owns neither the arena
   --  nor the allocation and must be detached before Value is released or its
   --  arena mapping disappears. Because Region_Offset zero is the null
   --  sentinel, nested relocatable objects need leading padding and a nonzero
   --  location inside this allocation region.
   --  @param Region Process-local allocation-region view attached on success
   --  @param Item Attached arena view
   --  @param Value Live allocation handle
   procedure Attach_Allocation
     (Region : in out Region_View;
      Item   : View;
      Value  : Allocation_Handle);

   --  Copy a checked allocation slice into Data. Release of Value must not
   --  race with this operation.
   --  @param Item Attached arena view
   --  @param Value Live allocation handle
   --  @param Offset Byte offset within the allocation
   --  @param Data Destination byte array
   procedure Read
     (Item   : View;
      Value  : Allocation_Handle;
      Offset : Byte_Count;
      Data   : out Ada.Streams.Stream_Element_Array);

   --  Copy Data into a checked allocation slice. Release of Value must not
   --  race with this operation.
   --  @param Item Attached arena view
   --  @param Value Live allocation handle
   --  @param Offset Byte offset within the allocation
   --  @param Data Source byte array
   procedure Write
     (Item   : View;
      Value  : Allocation_Handle;
      Offset : Byte_Count;
      Data   : Ada.Streams.Stream_Element_Array);

   --  Copy between two nonoverlapping or overlapping live allocation slices.
   --  Release of either handle must not race with this operation.
   --  @param Item Attached arena view
   --  @param Source Source allocation handle
   --  @param Source_Offset Byte offset in Source
   --  @param Target Target allocation handle
   --  @param Target_Offset Byte offset in Target
   --  @param Length Bytes to copy; zero performs validation only
   procedure Copy
     (Item          : View;
      Source        : Allocation_Handle;
      Source_Offset : Byte_Count;
      Target        : Allocation_Handle;
      Target_Offset : Byte_Count;
      Length        : Byte_Count);

   --  Destroy an empty quiescent arena and detach Item.
   --  @param Item Exclusively synchronized arena view
   --  @exception Layout_Error Live allocations remain
   procedure Destroy (Item : in out View);

private
   type View is limited record
      Core          : Layouts.Local_View;
      Guard_Address : System.Address := System.Null_Address;
      Counter_Address : System.Address := System.Null_Address;
      Usable_Value  : Interfaces.Unsigned_32 := 0;
      Minimum_Value : Interfaces.Unsigned_32 := 0;
      Node_Count    : Interfaces.Unsigned_32 := 0;
      Data_Offset   : Byte_Count := 0;
      Instance_Value : Interfaces.Unsigned_64 := 0;
   end record;
end Flyology.Data_Structures.Arenas;
