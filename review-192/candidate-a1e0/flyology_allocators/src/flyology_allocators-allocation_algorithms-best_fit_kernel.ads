with Interfaces;
private with Flyology_Allocators.Layouts;
private with System;

--  Provides variable-size best-fit allocation inside a fixed caller-owned
--  relocatable region. Free blocks are indexed by an in-region AVL tree keyed
--  by size and arena-relative offset. Physical-neighbor sizes support checked
--  splitting and deferred coalescing. Stored metadata contains only
--  fixed-width scalar
--  fields. Allocation and reclamation are serialized across views by one
--  persisted nonblocking guard; immediate allocation reports contention and
--  timed overloads yield between attempts. Payload access does not acquire the
--  metadata guard: the application or receiving data structure must exclude
--  release of a handle from reads, writes, and copies using it.
--  A dead metadata-guard owner leaves the arena locked. An independently
--  authorized supervisor may poison the arena after establishing owner death
--  and whole-arena quiescence; exclusive reinitialization is the only
--  recovery.
--  @exclude

package Flyology_Allocators.Allocation_Algorithms.Best_Fit_Kernel is

   --  Minimum supported allocation quantum and payload alignment.
   Minimum_Block_Limit : constant Positive := 16;

   --  Immutable best-fit geometry selected when opening an arena.
   --  @field Usable_Capacity Bytes occupied by in-band blocks
   --  @field Minimum_Block_Size Power-of-two quantum and payload alignment
   type Configuration is record
      Usable_Capacity    : Positive;
      Minimum_Block_Size : Positive;
   end record;

   function Configuration_Usable_Capacity (Value : Configuration) return Positive
   is (Value.Usable_Capacity);

   function Configuration_Minimum_Block_Size (Value : Configuration) return Positive
   is (Value.Minimum_Block_Size);

   --  Local attached arena view. It owns neither the backing region nor any
   --  allocation and must be detached before storage becomes unavailable.
   type View is limited private;

   --  Compute the complete arena extent. Minimum_Block_Size must be a power of
   --  two at least Minimum_Block_Limit. Usable_Capacity must be an exact
   --  multiple large enough for one block prefix and one allocation quantum.
   --  @param Configuration Managed capacity and minimum block size
   --  @return Required stored header, index, padding, and managed block bytes
   --  @exception Constraint_Error Geometry is invalid or cannot be represented
   function Required_Storage (Configuration : Best_Fit_Kernel.Configuration) return Byte_Count;

   --  Destructively initialize an empty arena and attach Item. The caller must
   --  exclusively own the complete extent. Reinitialization invalidates every
   --  allocation handle and attached arena-dependent structure.
   --  @param Item View attached on success
   --  @param Region Attached caller-owned backing region
   --  @param Location Nonzero location aligned to Minimum_Block_Size
   --  @param Configuration Managed capacity and minimum block size
   --  @param Instance_ID Nonzero caller-selected arena instance identity
   procedure Initialize
     (Item          : out View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : Best_Fit_Kernel.Configuration;
      Instance_ID   : Interfaces.Unsigned_64);

   --  Atomically initialize allocation-certified virgin bytes or attach to a
   --  ready compatible arena. Every immutable creation parameter must match an
   --  existing arena. The operation does not wait for another initializer or
   --  the metadata guard. Concurrent calls are valid only while the outer
   --  allocation protocol still guarantees virgin bytes; otherwise attachment
   --  quiescence applies.
   --  @param Item Attached view, or detached while initialization is active
   --  @param Region Independently attached backing region
   --  @param Location Stored arena offset
   --  @param Configuration Expected managed capacity and minimum block size
   --  @param Instance_ID Expected nonzero arena instance identity
   --  @param Result Creation, attachment, or in-progress outcome
   procedure Create_Or_Attach
     (Item          : out View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : Best_Fit_Kernel.Configuration;
      Instance_ID   : Interfaces.Unsigned_64;
      Result        : out Open_Result);

   --  Attach to a quiescent arena and validate its complete physical block
   --  chain, free-tree ordering and balance, and immutable configuration.
   --  @param Item View attached on success
   --  @param Region Independently attached backing region
   --  @param Location Stored arena offset
   --  @param Configuration Expected managed capacity and minimum block size
   --  @param Instance_ID Expected arena instance identity
   --  @exception Layout_Error Stored identity, geometry, or tree is corrupt
   --  @exception Busy_Error The arena metadata guard is active or abandoned
   --  @exception Poison_Error The arena lifecycle is poisoned
   procedure Attach
     (Item          : out View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : Best_Fit_Kernel.Configuration;
      Instance_ID   : Interfaces.Unsigned_64);

   --  Detach Item without releasing allocations or modifying backing bytes.
   --  @param Item Local view to detach
   procedure Detach (Item : in out View);

   --  Report whether Item retains local attachment information.
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
   --  rounded to the arena quantum. The smallest indexed fitting block is
   --  split when its remainder can represent another allocation. If no
   --  indexed block fits, one validated physical pass coalesces adjacent free
   --  runs and the search is retried before reporting exhaustion.
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
   --  exhaustion returns Exhausted only after any adjacent free runs have
   --  been coalesced and searched again.
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

   --  Release a live allocation for immediate exact-block reuse. Adjacent
   --  free blocks are coalesced on demand before allocation reports
   --  exhaustion. The caller must
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
   procedure Release (Item : in out View; Value : Allocation_Handle; Timeout : Wait_Timeout);

   --  Return the rounded capacity of a live allocation.
   --  @param Item Attached arena view
   --  @param Value Live allocation handle
   --  @return Usable bytes after the selected block's in-band prefix
   --  @exception Handle_Error Value is invalid or stale
   function Block_Capacity (Item : View; Value : Allocation_Handle) return Byte_Count;

   --  Attach Region to the exact bytes of a live allocation. No native address
   --  is returned or persisted. The resulting region owns neither the arena
   --  nor the allocation and must be detached before Value is released or its
   --  arena storage is released or repurposed. Because Region_Offset zero is
   --  the null
   --  sentinel, nested relocatable objects need leading padding and a nonzero
   --  location inside this allocation region.
   --  @param Region Local allocation-region view attached on success
   --  @param Item Attached arena view
   --  @param Value Live allocation handle
   procedure Attach_Allocation (Region : in out Region_View; Item : View; Value : Allocation_Handle);

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
      Core               : Layouts.Local_View;
      Guard_Address      : System.Address := System.Null_Address;
      Counter_Address    : System.Address := System.Null_Address;
      Index_Base         : System.Address := System.Null_Address;
      Data_Base          : System.Address := System.Null_Address;
      Root_Address       : System.Address := System.Null_Address;
      Live_Count_Address : System.Address := System.Null_Address;
      Usable_Value       : Interfaces.Unsigned_32 := 0;
      Minimum_Value      : Interfaces.Unsigned_32 := 0;
      Prefix_Value       : Interfaces.Unsigned_32 := 0;
      Last_Block_Value   : Interfaces.Unsigned_32 := 0;
      Data_Offset        : Byte_Count := 0;
      Instance_Value     : Interfaces.Unsigned_64 := 0;
   end record;
end Flyology_Allocators.Allocation_Algorithms.Best_Fit_Kernel;
