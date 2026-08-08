with Ada.Streams;
with Interfaces;

--  Adapts one allocation implementation to the compile-time arena contract.
--  The generic contains only static renames: instantiation adds no runtime
--  dispatch, stored callback, or process-local pointer to backing bytes.
--  @formal Algorithm_Identity Complete persisted allocator layout identity
--  @formal Algorithm_Minimum_Block_Limit Smallest permitted allocation unit
--  @formal Algorithm_Capabilities Compile-time behavioral capabilities
--  @formal Algorithm_Configuration Immutable algorithm creation parameters
--  @formal Algorithm_View Process-local implementation view
--  @formal Implementation_Required_Storage Compute complete stored extent
--  @formal Implementation_Initialize Destructively initialize storage
--  @formal Implementation_Create_Or_Attach Create virgin or attach compatible
--  @formal Implementation_Attach Attach and validate compatible storage
--  @formal Implementation_Detach Detach one process-local view
--  @formal Implementation_Is_Attached Test process-local attachment
--  @formal Implementation_Current_Metadata Return immutable metadata
--  @formal Implementation_Is_Poisoned Test persisted poison state
--  @formal Implementation_Poison Poison after external quiescence authority
--  @formal Implementation_Try_Allocate_Immediate Attempt one allocation
--  @formal Implementation_Try_Allocate_Timed Wait for allocator contention
--  @formal Implementation_Release_Immediate Release without internal waiting
--  @formal Implementation_Release_Timed Wait for release contention
--  @formal Implementation_Block_Capacity Return a live block's capacity
--  @formal Implementation_Attach_Allocation Attach a checked allocation region
--  @formal Implementation_Bind_Allocation Bind checked immutable storage
--  @formal Implementation_Read Copy from a live allocation
--  @formal Implementation_Write Copy into a live allocation
--  @formal Implementation_Copy Copy between live allocations
--  @formal Implementation_Destroy Destroy an empty quiescent allocator
generic
   Algorithm_Identity : Layout_Identity;
   Algorithm_Minimum_Block_Limit : Positive;
   Algorithm_Capabilities : Allocation_Algorithms.Allocation_Capabilities;
   type Algorithm_Configuration is private;
   type Algorithm_View is limited private;
   with function Implementation_Required_Storage
     (Configuration : Algorithm_Configuration) return Byte_Count;
   with procedure Implementation_Initialize
     (Item          : out Algorithm_View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : Algorithm_Configuration;
      Instance_ID   : Interfaces.Unsigned_64);
   with procedure Implementation_Create_Or_Attach
     (Item          : out Algorithm_View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : Algorithm_Configuration;
      Instance_ID   : Interfaces.Unsigned_64;
      Result        : out Open_Result);
   with procedure Implementation_Attach
     (Item          : out Algorithm_View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : Algorithm_Configuration;
      Instance_ID   : Interfaces.Unsigned_64);
   with procedure Implementation_Detach (Item : in out Algorithm_View);
   with function Implementation_Is_Attached
     (Item : Algorithm_View) return Boolean;
   with function Implementation_Current_Metadata
     (Item : Algorithm_View) return Allocation_Algorithms.Metadata;
   with function Implementation_Is_Poisoned
     (Item : Algorithm_View) return Boolean;
   with procedure Implementation_Poison
     (Region : Region_View; Location : Region_Offset);
   with procedure Implementation_Try_Allocate_Immediate
     (Item           : in out Algorithm_View;
      Requested_Size : Positive;
      Value          : out Allocation_Algorithms.Allocation_Handle;
      Result         : out Allocation_Algorithms.Allocation_Result);
   with procedure Implementation_Try_Allocate_Timed
     (Item           : in out Algorithm_View;
      Requested_Size : Positive;
      Timeout        : Wait_Timeout;
      Value          : out Allocation_Algorithms.Allocation_Handle;
      Result         : out Allocation_Algorithms.Allocation_Result);
   with procedure Implementation_Release_Immediate
     (Item  : in out Algorithm_View;
      Value : Allocation_Algorithms.Allocation_Handle);
   with procedure Implementation_Release_Timed
     (Item    : in out Algorithm_View;
      Value   : Allocation_Algorithms.Allocation_Handle;
      Timeout : Wait_Timeout);
   with function Implementation_Block_Capacity
     (Item  : Algorithm_View;
      Value : Allocation_Algorithms.Allocation_Handle) return Byte_Count;
   with procedure Implementation_Attach_Allocation
     (Region : in out Region_View;
      Item   : Algorithm_View;
      Value  : Allocation_Algorithms.Allocation_Handle);
   with function Implementation_Bind_Allocation
     (Item      : Algorithm_View;
      Value     : Allocation_Algorithms.Allocation_Handle;
      Offset    : Byte_Count;
      Extent    : Byte_Count;
      Alignment : Byte_Count;
      Signature : Interfaces.Unsigned_64;
      Version   : Interfaces.Unsigned_32;
      Writable  : Boolean) return Immutable_Storage_View;
   with procedure Implementation_Read
     (Item   : Algorithm_View;
      Value  : Allocation_Algorithms.Allocation_Handle;
      Offset : Byte_Count;
      Data   : out Ada.Streams.Stream_Element_Array);
   with procedure Implementation_Write
     (Item   : Algorithm_View;
      Value  : Allocation_Algorithms.Allocation_Handle;
      Offset : Byte_Count;
      Data   : Ada.Streams.Stream_Element_Array);
   with procedure Implementation_Copy
     (Item          : Algorithm_View;
      Source        : Allocation_Algorithms.Allocation_Handle;
      Source_Offset : Byte_Count;
      Target        : Allocation_Algorithms.Allocation_Handle;
      Target_Offset : Byte_Count;
      Length        : Byte_Count);
   with procedure Implementation_Destroy (Item : in out Algorithm_View);
package Flyology.Data_Structures.Allocation_Algorithms.Contract is
   pragma Preelaborate;

   --  Complete persisted identity checked by the implementation.
   Identity : constant Layout_Identity := Algorithm_Identity;

   --  Smallest allocation unit accepted by this implementation.
   Minimum_Block_Limit : constant Positive :=
     Algorithm_Minimum_Block_Limit;

   --  Compile-time synchronization, placement, and search characteristics.
   Capabilities : constant Allocation_Algorithms.Allocation_Capabilities :=
     Algorithm_Capabilities;

   --  Algorithm-specific immutable creation parameters.
   subtype Configuration is Algorithm_Configuration;

   --  Process-local allocator view.
   subtype View is Algorithm_View;

   --  Compute the complete allocator extent.
   --  @param Configuration Algorithm-specific immutable geometry
   --  @return Complete metadata, padding, and payload extent
   function Required_Storage
     (Configuration : Algorithm_Configuration) return Byte_Count
     renames Implementation_Required_Storage;

   --  Destructively initialize allocator storage.
   --  @param Item View attached on success
   --  @param Region Attached caller-owned region
   --  @param Location Stored allocator location
   --  @param Configuration Algorithm-specific immutable geometry
   --  @param Instance_ID Nonzero caller-selected identity
   procedure Initialize
     (Item          : out Algorithm_View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : Algorithm_Configuration;
      Instance_ID   : Interfaces.Unsigned_64)
     renames Implementation_Initialize;

   --  Create in virgin storage or attach to an exact compatible allocator.
   --  @param Item Attached view or detached during concurrent initialization
   --  @param Region Attached caller-owned region
   --  @param Location Stored allocator location
   --  @param Configuration Expected algorithm-specific geometry
   --  @param Instance_ID Expected nonzero caller-selected identity
   --  @param Result Creation, attachment, or in-progress outcome
   procedure Create_Or_Attach
     (Item          : out Algorithm_View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : Algorithm_Configuration;
      Instance_ID   : Interfaces.Unsigned_64;
      Result        : out Open_Result)
     renames Implementation_Create_Or_Attach;

   --  Attach and validate an existing allocator.
   --  @param Item View attached on success
   --  @param Region Attached caller-owned region
   --  @param Location Stored allocator location
   --  @param Configuration Expected algorithm-specific geometry
   --  @param Instance_ID Expected caller-selected identity
   procedure Attach
     (Item          : out Algorithm_View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : Algorithm_Configuration;
      Instance_ID   : Interfaces.Unsigned_64)
     renames Implementation_Attach;

   --  Detach a process-local view without modifying stored bytes.
   --  @param Item View to detach
   procedure Detach (Item : in out Algorithm_View)
     renames Implementation_Detach;
   --  Test whether a process-local view remains attached.
   --  @param Item View to inspect
   --  @return True while Item retains mapping information
   function Is_Attached (Item : Algorithm_View) return Boolean
     renames Implementation_Is_Attached;
   --  Return common immutable allocator metadata.
   --  @param Item Attached allocator view
   --  @return Capacity, minimum unit, identity, incarnation, and extent
   function Current_Metadata
     (Item : Algorithm_View) return Allocation_Algorithms.Metadata
     renames Implementation_Current_Metadata;
   --  Test the persisted poison lifecycle.
   --  @param Item Attached allocator view
   --  @return True only when explicitly poisoned
   function Is_Poisoned (Item : Algorithm_View) return Boolean
     renames Implementation_Is_Poisoned;
   --  Poison after algorithm-specific external quiescence authorization.
   --  @param Region Attached backing region
   --  @param Location Stored allocator location
   procedure Poison (Region : Region_View; Location : Region_Offset)
     renames Implementation_Poison;

   --  Attempt one allocation without waiting.
   --  @param Item Attached allocator view
   --  @param Requested_Size Positive requested payload bytes
   --  @param Value New handle or Null_Allocation
   --  @param Result Allocation, exhaustion, or contention outcome
   procedure Try_Allocate
     (Item           : in out Algorithm_View;
      Requested_Size : Positive;
      Value          : out Allocation_Algorithms.Allocation_Handle;
      Result         : out Allocation_Algorithms.Allocation_Result)
     renames Implementation_Try_Allocate_Immediate;
   --  Attempt allocation while waiting only for metadata contention.
   --  @param Item Attached allocator view
   --  @param Requested_Size Positive requested payload bytes
   --  @param Timeout Maximum contention wait
   --  @param Value New handle or Null_Allocation
   --  @param Result Allocation or exhaustion outcome
   procedure Try_Allocate
     (Item           : in out Algorithm_View;
      Requested_Size : Positive;
      Timeout        : Wait_Timeout;
      Value          : out Allocation_Algorithms.Allocation_Handle;
      Result         : out Allocation_Algorithms.Allocation_Result)
     renames Implementation_Try_Allocate_Timed;
   --  Release one live allocation without waiting.
   --  @param Item Attached allocator view
   --  @param Value Live allocation handle
   procedure Release
     (Item  : in out Algorithm_View;
      Value : Allocation_Algorithms.Allocation_Handle)
     renames Implementation_Release_Immediate;
   --  Release one live allocation while waiting for metadata contention.
   --  @param Item Attached allocator view
   --  @param Value Live allocation handle
   --  @param Timeout Maximum contention wait
   procedure Release
     (Item    : in out Algorithm_View;
      Value   : Allocation_Algorithms.Allocation_Handle;
      Timeout : Wait_Timeout)
     renames Implementation_Release_Timed;
   --  Return the usable capacity of one live allocation.
   --  @param Item Attached allocator view
   --  @param Value Live allocation handle
   --  @return Usable allocation bytes
   function Block_Capacity
     (Item  : Algorithm_View;
      Value : Allocation_Algorithms.Allocation_Handle) return Byte_Count
     renames Implementation_Block_Capacity;
   --  Attach a checked region view to one live allocation.
   --  @param Region Allocation-region view attached on success
   --  @param Item Attached allocator view
   --  @param Value Live allocation handle
   procedure Attach_Allocation
     (Region : in out Region_View;
      Item   : Algorithm_View;
      Value  : Allocation_Algorithms.Allocation_Handle)
     renames Implementation_Attach_Allocation;
   --  Bind a checked allocation slice to immutable storage operations.
   --  @param Item Attached allocator view
   --  @param Value Live allocation handle
   --  @param Offset Slice offset
   --  @param Extent Slice extent
   --  @param Alignment Required native alignment
   --  @param Signature Immutable representation signature
   --  @param Version Immutable representation version
   --  @param Writable Whether a builder may write unpublished bytes
   --  @return Opaque checked immutable-storage binding
   --  @exclude
   function Bind_Allocation
     (Item      : Algorithm_View;
      Value     : Allocation_Algorithms.Allocation_Handle;
      Offset    : Byte_Count;
      Extent    : Byte_Count;
      Alignment : Byte_Count;
      Signature : Interfaces.Unsigned_64;
      Version   : Interfaces.Unsigned_32;
      Writable  : Boolean) return Immutable_Storage_View
     renames Implementation_Bind_Allocation;
   --  Copy a live allocation slice into Data.
   --  @param Item Attached allocator view
   --  @param Value Live allocation handle
   --  @param Offset Slice offset
   --  @param Data Destination bytes
   procedure Read
     (Item   : Algorithm_View;
      Value  : Allocation_Algorithms.Allocation_Handle;
      Offset : Byte_Count;
      Data   : out Ada.Streams.Stream_Element_Array)
     renames Implementation_Read;
   --  Copy Data into a live allocation slice.
   --  @param Item Attached allocator view
   --  @param Value Live allocation handle
   --  @param Offset Slice offset
   --  @param Data Source bytes
   procedure Write
     (Item   : Algorithm_View;
      Value  : Allocation_Algorithms.Allocation_Handle;
      Offset : Byte_Count;
      Data   : Ada.Streams.Stream_Element_Array)
     renames Implementation_Write;
   --  Copy between live allocation slices.
   --  @param Item Attached allocator view
   --  @param Source Source allocation handle
   --  @param Source_Offset Source slice offset
   --  @param Target Target allocation handle
   --  @param Target_Offset Target slice offset
   --  @param Length Bytes to copy
   procedure Copy
     (Item          : Algorithm_View;
      Source        : Allocation_Algorithms.Allocation_Handle;
      Source_Offset : Byte_Count;
      Target        : Allocation_Algorithms.Allocation_Handle;
      Target_Offset : Byte_Count;
      Length        : Byte_Count)
     renames Implementation_Copy;
   --  Destroy an empty quiescent allocator and detach Item.
   --  @param Item Exclusively synchronized allocator view
   procedure Destroy (Item : in out Algorithm_View)
     renames Implementation_Destroy;

end Flyology.Data_Structures.Allocation_Algorithms.Contract;
