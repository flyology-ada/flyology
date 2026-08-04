with Ada.Task_Identification;
with System;
with System.Storage_Elements;
with System.Storage_Pools.Subpools;

--  Provides explicitly task-owned allocation regions with bulk release.
package Flyology.Memory_Regions is

   --  Raised when a pool or region is used by a task other than its owner,
   --  or when Release is given a handle not created by this package.
   Ownership_Error : exception;

   --  Pool owned by the task that declares it. Each access type associated
   --  with the pool must use a named Region_Handle in every allocator. An
   --  allocator without a region raises Program_Error. The pool is not
   --  synchronized and must not outlive its owning task.
   type Task_Pool is limited new
     System.Storage_Pools.Subpools.Root_Storage_Pool_With_Subpools
       with private;

   --  Standard Ada subpool handle accepted by a named allocator.
   subtype Region_Handle is System.Storage_Pools.Subpools.Subpool_Handle;

   --  Accounting for storage retained by live regions. Consumed_Storage
   --  includes alignment and compiler finalization overhead. Reserved_Storage
   --  is the total capacity of backing chunks.
   --  @field Live_Regions Number of regions not yet released
   --  @field Consumed_Storage Storage consumed within live regions
   --  @field Reserved_Storage Backing storage retained by live regions
   type Pool_Statistics is record
      Live_Regions     : Natural;
      Consumed_Storage : System.Storage_Elements.Storage_Count;
      Reserved_Storage : System.Storage_Elements.Storage_Count;
   end record;

   --  Create a region owned by Pool and the calling task. Chunk_Storage is
   --  the preferred backing-chunk capacity; a larger allocation receives a
   --  dedicated sufficiently large chunk. Region-backed references must not
   --  escape the region's lifetime.
   --  @param Pool Task-owned storage pool
   --  @param Chunk_Storage Preferred backing-chunk capacity
   --  @return Handle for use in a named allocator, new (Handle) T
   --  @exception Ownership_Error The calling task does not own Pool
   --  @exception Constraint_Error Chunk_Storage is zero
   function Create_Region
     (Pool          : in out Task_Pool;
      Chunk_Storage : System.Storage_Elements.Storage_Count := 65_536)
      return not null Region_Handle;

   --  Finalize every controlled object in Region and release all of its
   --  backing chunks. References into the region become invalid. Null is an
   --  idempotent no-op; a successful call sets the handle to null. If
   --  controlled finalization raises, storage is still reclaimed before the
   --  exception propagates. Ada does not copy an in out scalar back after an
   --  exceptional return, so the caller must treat every handle copy as
   --  invalid and set the passed variable to null in its handler.
   --  @param Region Region to finalize and release
   --  @exception Ownership_Error Region belongs to another pool type or task
   procedure Release (Region : in out Region_Handle);

   --  Return accounting for Pool. Only the owner task may query it.
   --  @param Pool Task-owned storage pool
   --  @return Current live-region storage accounting
   --  @exception Ownership_Error The calling task does not own Pool
   function Statistics (Pool : Task_Pool) return Pool_Statistics;

private
   package Subpools renames System.Storage_Pools.Subpools;
   package Storage renames System.Storage_Elements;

   type Chunk;
   type Chunk_Access is access Chunk;

   type Chunk (Last : Storage.Storage_Offset) is record
      Next : Chunk_Access := null;
      Used : Storage.Storage_Count := 0;
      Data : aliased Storage.Storage_Array (1 .. Last);
   end record;

   type Region_Data is limited new Subpools.Root_Subpool with record
      First       : Chunk_Access := null;
      Chunk_Size  : Storage.Storage_Count := 0;
      Consumed    : Storage.Storage_Count := 0;
      Reserved    : Storage.Storage_Count := 0;
   end record;
   type Region_Access is access all Region_Data;

   type Task_Pool is limited new
     Subpools.Root_Storage_Pool_With_Subpools with record
      Owner       : Ada.Task_Identification.Task_Id :=
        Ada.Task_Identification.Current_Task;
      Live_Count  : Natural := 0;
      Consumed    : Storage.Storage_Count := 0;
      Reserved    : Storage.Storage_Count := 0;
   end record;

   --  @exclude
   --  @param Pool Task-owned storage pool
   --  @return Newly created default-sized region
   overriding function Create_Subpool
     (Pool : in out Task_Pool) return not null Region_Handle;

   --  @exclude
   --  @param Pool Owning storage pool
   --  @param Storage_Address Address of the allocated storage
   --  @param Size_In_Storage_Elements Requested size
   --  @param Alignment Requested alignment
   --  @param Subpool Region receiving the allocation
   overriding procedure Allocate_From_Subpool
     (Pool                     : in out Task_Pool;
      Storage_Address          : out System.Address;
      Size_In_Storage_Elements : Storage.Storage_Count;
      Alignment                : Storage.Storage_Count;
      Subpool                  : not null Region_Handle);

   --  @exclude
   --  @param Pool Owning storage pool
   --  @param Subpool Finalized region being reclaimed
   overriding procedure Deallocate_Subpool
     (Pool    : in out Task_Pool;
      Subpool : in out Region_Handle);

end Flyology.Memory_Regions;
