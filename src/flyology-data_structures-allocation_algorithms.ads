with Interfaces;

--  Defines representation shared by relocatable allocation algorithms.
--  Algorithm packages interpret allocation tokens, own their metadata layout,
--  and state their synchronization and recovery rules. No stored handle
--  contains a native address or Ada access value.
package Flyology.Data_Structures.Allocation_Algorithms with Preelaborate is

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
   --  @field Usable_Capacity Bytes managed for payload allocation
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
