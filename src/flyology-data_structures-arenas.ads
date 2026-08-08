with Ada.Streams;
with Flyology.Data_Structures.Allocation_Algorithms;
with Flyology.Data_Structures.Allocation_Algorithms.Contract;
with Interfaces;

--  Provides a fixed caller-owned relocatable allocation domain using one
--  statically selected allocation algorithm. Instantiation introduces no
--  runtime dispatch or stored callback. Algorithm identity and configuration
--  are validated by Create_Or_Attach and Attach. The selected algorithm owns
--  allocation synchronization, abandonment, poison, and recovery semantics.
--  @formal Algorithm Allocation implementation and persisted layout contract
generic
   with package Algorithm is new
     Flyology.Data_Structures.Allocation_Algorithms.Contract (<>);
package Flyology.Data_Structures.Arenas with Preelaborate is

   --  Complete persisted allocator identity.
   Identity : constant Layout_Identity := Algorithm.Identity;

   --  Minimum allocation unit accepted by the selected algorithm.
   Minimum_Block_Limit : constant Positive :=
     Algorithm.Minimum_Block_Limit;

   --  Compile-time behavioral characteristics of the selected algorithm.
   Capabilities : constant Allocation_Algorithms.Allocation_Capabilities :=
     Algorithm.Capabilities;

   --  Algorithm-specific immutable creation parameters.
   subtype Configuration is Algorithm.Configuration;

   --  Fixed-width address-independent allocation identity.
   subtype Allocation_Handle is
     Allocation_Algorithms.Allocation_Handle;

   --  Null allocation relationship.
   Null_Allocation : constant Allocation_Handle :=
     Allocation_Algorithms.Null_Allocation;

   --  Allocation attempt outcome.
   subtype Allocation_Result is Allocation_Algorithms.Allocation_Result;

   --  A newly allocated block was returned.
   Allocated : constant Allocation_Result :=
     Allocation_Algorithms.Allocated;

   --  No free block can satisfy the request.
   Exhausted : constant Allocation_Result :=
     Allocation_Algorithms.Exhausted;

   --  Another caller owns allocator metadata.
   Allocation_Contended : constant Allocation_Result :=
     Allocation_Algorithms.Allocation_Contended;

   --  Immutable stored arena configuration.
   subtype Metadata is Allocation_Algorithms.Metadata;

   --  Process-local attached arena view. It owns neither the backing region
   --  nor an allocation and must be detached before its mapping disappears.
   subtype View is Algorithm.View;

   --  Compute the complete allocator extent for Configuration.
   --  @param Configuration Algorithm-specific immutable geometry
   --  @return Complete allocator metadata, padding, and payload bytes
   --  @exception Constraint_Error Configuration is invalid or unrepresentable
   function Required_Storage
     (Configuration : Algorithm.Configuration) return Byte_Count
     renames Algorithm.Required_Storage;

   --  Destructively initialize an empty arena and attach Item. The caller must
   --  exclusively own the complete extent. Reinitialization invalidates every
   --  allocation handle and dependent structure.
   --  @param Item View attached on success
   --  @param Region Attached caller-owned backing region
   --  @param Location Nonzero suitably aligned stored location
   --  @param Configuration Algorithm-specific immutable geometry
   --  @param Instance_ID Nonzero caller-selected arena identity
   procedure Initialize
     (Item          : out Algorithm.View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : Algorithm.Configuration;
      Instance_ID   : Interfaces.Unsigned_64)
     renames Algorithm.Initialize;

   --  Atomically initialize allocation-certified virgin bytes or attach to a
   --  ready compatible arena. Algorithm identity, every configuration field,
   --  and Instance_ID must match an existing arena. This is not recovery.
   --  @param Item Attached view or detached during another initialization
   --  @param Region Independently attached backing region
   --  @param Location Stored arena offset
   --  @param Configuration Expected algorithm-specific geometry
   --  @param Instance_ID Expected nonzero arena identity
   --  @param Result Creation, attachment, or in-progress outcome
   procedure Create_Or_Attach
     (Item          : out Algorithm.View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : Algorithm.Configuration;
      Instance_ID   : Interfaces.Unsigned_64;
      Result        : out Open_Result)
     renames Algorithm.Create_Or_Attach;

   --  Attach to a quiescent compatible arena and validate its complete stored
   --  algorithm state.
   --  @param Item View attached on success
   --  @param Region Independently attached backing region
   --  @param Location Stored arena offset
   --  @param Configuration Expected algorithm-specific geometry
   --  @param Instance_ID Expected arena identity
   --  @exception Layout_Error Identity, configuration, or metadata is corrupt
   --  @exception Busy_Error Allocator metadata is active or abandoned
   --  @exception Poison_Error Arena lifecycle is poisoned
   procedure Attach
     (Item          : out Algorithm.View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : Algorithm.Configuration;
      Instance_ID   : Interfaces.Unsigned_64)
     renames Algorithm.Attach;

   --  Detach Item without releasing allocations or modifying backing bytes.
   --  @param Item Local view to detach
   procedure Detach (Item : in out Algorithm.View)
     renames Algorithm.Detach;

   --  Report whether Item retains process-local mapping information.
   --  @param Item View to inspect
   --  @return True while the local arena view is attached
   function Is_Attached (Item : Algorithm.View) return Boolean
     renames Algorithm.Is_Attached;

   --  Return the immutable common arena configuration.
   --  @param Item Attached arena view
   --  @return Validated capacity, allocation unit, identity, and incarnation
   function Current_Metadata
     (Item : Algorithm.View) return Allocation_Algorithms.Metadata
     renames Algorithm.Current_Metadata;

   --  Report whether an attached arena was explicitly poisoned.
   --  @param Item Attached arena view
   --  @return True only for the persisted Poisoned lifecycle state
   function Is_Poisoned (Item : Algorithm.View) return Boolean
     renames Algorithm.Is_Poisoned;

   --  Poison an arena only after the selected algorithm's documented external
   --  owner-death and quiescence conditions are established.
   --  @param Region Attached backing region
   --  @param Location Stored arena offset
   procedure Poison (Region : Region_View; Location : Region_Offset)
     renames Algorithm.Poison;

   --  Attempt one variable-size allocation without waiting.
   --  @param Item Any concurrently attached arena view
   --  @param Requested_Size Positive payload bytes requested
   --  @param Value New handle or Null_Allocation
   --  @param Result Allocated, exhausted, or contended outcome
   procedure Try_Allocate
     (Item           : in out Algorithm.View;
      Requested_Size : Positive;
      Value          : out Allocation_Algorithms.Allocation_Handle;
      Result         : out Allocation_Algorithms.Allocation_Result)
     renames Algorithm.Try_Allocate;

   --  Allocate after waiting only for allocator-metadata contention. Genuine
   --  exhaustion still returns Exhausted after one complete attempt.
   --  @param Item Any concurrently attached arena view
   --  @param Requested_Size Positive payload bytes requested
   --  @param Timeout Maximum wait; zero permits one immediate attempt
   --  @param Value New handle or Null_Allocation
   --  @param Result Allocated or exhausted outcome
   --  @exception Timeout_Error Metadata contention persists through deadline
   procedure Try_Allocate
     (Item           : in out Algorithm.View;
      Requested_Size : Positive;
      Timeout        : Wait_Timeout;
      Value          : out Allocation_Algorithms.Allocation_Handle;
      Result         : out Allocation_Algorithms.Allocation_Result)
     renames Algorithm.Try_Allocate;

   --  Release a live allocation. The caller must exclude every payload access
   --  through Value.
   --  @param Item Any concurrently attached arena view
   --  @param Value Live handle issued by this arena incarnation
   --  @exception Busy_Error Another caller owns allocator metadata
   --  @exception Handle_Error Value is null, stale, reclaimed, or foreign
   procedure Release
     (Item  : in out Algorithm.View;
      Value : Allocation_Algorithms.Allocation_Handle)
     renames Algorithm.Release;

   --  Release after waiting for allocator-metadata contention.
   --  @param Item Any concurrently attached arena view
   --  @param Value Live handle issued by this arena incarnation
   --  @param Timeout Maximum wait; zero permits one immediate attempt
   --  @exception Timeout_Error Metadata contention persists through deadline
   procedure Release
     (Item    : in out Algorithm.View;
      Value   : Allocation_Algorithms.Allocation_Handle;
      Timeout : Wait_Timeout)
     renames Algorithm.Release;

   --  Return the rounded capacity of a live allocation.
   --  @param Item Attached arena view
   --  @param Value Live allocation handle
   --  @return Usable bytes in the selected block
   --  @exception Handle_Error Value is invalid or stale
   function Block_Capacity
     (Item  : Algorithm.View;
      Value : Allocation_Algorithms.Allocation_Handle) return Byte_Count
     renames Algorithm.Block_Capacity;

   --  Attach Region to the exact bytes of a live allocation. The region must
   --  be detached before release or backing-mapping destruction.
   --  @param Region Process-local allocation-region view attached on success
   --  @param Item Attached arena view
   --  @param Value Live allocation handle
   procedure Attach_Allocation
     (Region : in out Region_View;
      Item   : Algorithm.View;
      Value  : Allocation_Algorithms.Allocation_Handle)
     renames Algorithm.Attach_Allocation;

   --  Bind one checked allocation slice for an immutable element adapter.
   --  @param Item Attached arena view
   --  @param Value Live allocation handle
   --  @param Offset Byte offset within the allocation
   --  @param Extent Exact immutable representation bytes
   --  @param Alignment Required power-of-two native alignment
   --  @param Signature Stable immutable representation signature
   --  @param Version Immutable representation layout version
   --  @param Writable Whether an unpublished builder may bind the slice
   --  @return Opaque checked immutable-storage binding
   --  @exclude
   function Bind_Allocation
     (Item      : Algorithm.View;
      Value     : Allocation_Algorithms.Allocation_Handle;
      Offset    : Byte_Count;
      Extent    : Byte_Count;
      Alignment : Byte_Count;
      Signature : Interfaces.Unsigned_64;
      Version   : Interfaces.Unsigned_32;
      Writable  : Boolean) return Immutable_Storage_View
     renames Algorithm.Bind_Allocation;

   --  Copy a checked allocation slice into Data.
   --  @param Item Attached arena view
   --  @param Value Live allocation handle
   --  @param Offset Byte offset within the allocation
   --  @param Data Destination byte array
   procedure Read
     (Item   : Algorithm.View;
      Value  : Allocation_Algorithms.Allocation_Handle;
      Offset : Byte_Count;
      Data   : out Ada.Streams.Stream_Element_Array)
     renames Algorithm.Read;

   --  Copy Data into a checked allocation slice.
   --  @param Item Attached arena view
   --  @param Value Live allocation handle
   --  @param Offset Byte offset within the allocation
   --  @param Data Source byte array
   procedure Write
     (Item   : Algorithm.View;
      Value  : Allocation_Algorithms.Allocation_Handle;
      Offset : Byte_Count;
      Data   : Ada.Streams.Stream_Element_Array)
     renames Algorithm.Write;

   --  Copy between two live allocation slices.
   --  @param Item Attached arena view
   --  @param Source Source allocation handle
   --  @param Source_Offset Byte offset in Source
   --  @param Target Target allocation handle
   --  @param Target_Offset Byte offset in Target
   --  @param Length Bytes to copy; zero performs validation only
   procedure Copy
     (Item          : Algorithm.View;
      Source        : Allocation_Algorithms.Allocation_Handle;
      Source_Offset : Byte_Count;
      Target        : Allocation_Algorithms.Allocation_Handle;
      Target_Offset : Byte_Count;
      Length        : Byte_Count)
     renames Algorithm.Copy;

   --  Destroy an empty quiescent arena and detach Item.
   --  @param Item Exclusively synchronized arena view
   --  @exception Layout_Error Live allocations remain
   procedure Destroy (Item : in out Algorithm.View)
     renames Algorithm.Destroy;

end Flyology.Data_Structures.Arenas;
