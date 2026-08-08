with Interfaces;

--  Defines representation shared by relocatable allocation algorithms.
--  Algorithm packages interpret allocation tokens, own their metadata layout,
--  and state their synchronization and recovery rules. No stored handle
--  contains a native address or Ada access value.
package Flyology.Data_Structures.Allocation_Algorithms with Preelaborate is

   --  Asymptotic search bound stated by an allocation implementation.
   --  @enum Constant_Class_Bound Search examines a fixed number of classes
   --  @enum Logarithmic Search grows logarithmically with managed blocks
   --  @enum Linear Search may inspect every managed block
   type Search_Bound is
     (Constant_Class_Bound, Logarithmic, Linear);

   --  Stored-metadata contention scope used by one operation class.
   --  @enum Whole_Allocator One persisted guard serializes the allocator
   --  @enum Per_Allocation Independent allocations have separate state
   --  @enum External_Exclusion The caller supplies synchronization
   type Contention_Scope is
     (Whole_Allocator, Per_Allocation, External_Exclusion);

   --  Compile-time behavioral capabilities of an allocation algorithm. These
   --  values describe its public contract; the algorithm's persisted identity
   --  remains the compatibility authority on attachment.
   --  @field Search Worst-case allocation search class
   --  @field Allocation_Contention Contention scope for allocation
   --  @field Release_Contention Contention scope for reclamation
   --  @field In_Band_Metadata Whether managed bytes contain block metadata
   --  @field Splits_Blocks Whether allocation can split a larger free block
   --  @field Coalesces_On_Release Whether release immediately joins neighbors
   --  @field Timed_Contention Whether timed allocation and release are present
   --  @field Release_Exclusion Whether payload access must exclude release
   type Allocation_Capabilities is record
      Search               : Search_Bound;
      Allocation_Contention : Contention_Scope;
      Release_Contention    : Contention_Scope;
      In_Band_Metadata      : Boolean;
      Splits_Blocks         : Boolean;
      Coalesces_On_Release  : Boolean;
      Timed_Contention      : Boolean;
      Release_Exclusion     : Boolean;
   end record;

   --  Fixed-width opaque allocation identity. Token is interpreted only by
   --  the selected algorithm. Generation is nonzero for every live allocation
   --  and must not wrap to revive an older handle.
   --  @field Token Algorithm-defined arena-relative allocation token
   --  @field Generation Nonzero allocation generation
   type Allocation_Handle is record
      Token      : Interfaces.Unsigned_64 := 0;
      Generation : Interfaces.Unsigned_64 := 0;
   end record;
   for Allocation_Handle use record
      Token      at 0 range 0 .. 63;
      Generation at 8 range 0 .. 63;
   end record;
   for Allocation_Handle'Size use 128;

   --  Null allocation relationship.
   Null_Allocation : constant Allocation_Handle :=
     (Token => 0, Generation => 0);

   --  Allocation attempt outcome.
   --  @enum Allocated Value names a newly allocated block
   --  @enum Exhausted No free block can satisfy the request
   --  @enum Allocation_Contended Another caller owns allocator metadata
   type Allocation_Result is
     (Allocated, Exhausted, Allocation_Contended);

   --  Immutable configuration common to attached allocator instances.
   --  @field Usable_Capacity Bytes in the algorithm-managed allocation area;
   --    in-band algorithms may reserve part of this area for block metadata
   --  @field Minimum_Block_Size Smallest allocation unit and alignment
   --  @field Instance_ID Caller-selected nonzero arena identity
   --  @field Incarnation Persisted initialization epoch for dependencies
   --  @field Extent Complete allocator metadata and payload extent
   type Metadata is record
      Usable_Capacity    : Interfaces.Unsigned_32;
      Minimum_Block_Size : Interfaces.Unsigned_32;
      Instance_ID        : Interfaces.Unsigned_64;
      Incarnation        : Interfaces.Unsigned_32;
      Extent             : Byte_Count;
   end record;

end Flyology.Data_Structures.Allocation_Algorithms;
