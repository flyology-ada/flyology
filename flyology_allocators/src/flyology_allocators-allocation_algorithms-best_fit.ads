with Flyology_Allocators.Allocation_Algorithms.Best_Fit_Kernel;
with Flyology_Allocators.Allocation_Algorithms.Contract;

--  Best-fit allocation for relocatable arenas. Free blocks are indexed by an
--  offset-based AVL tree ordered by size and position; in-band boundary
--  metadata supports splitting and allocation-triggered coalescing. One
--  persisted nonblocking guard serializes allocation and release across
--  attached views.
--  Payload access requires the handle owner to exclude release. A dead guard
--  owner leaves the allocator locked until an external authority poisons it,
--  and exclusive reinitialization is the only recovery.
package Flyology_Allocators.Allocation_Algorithms.Best_Fit is new
  Flyology_Allocators.Allocation_Algorithms.Contract
    (Algorithm_Minimum_Block_Limit =>
       Best_Fit_Kernel.Minimum_Block_Limit,
     Algorithm_Capabilities =>
       (Search                => Allocation_Algorithms.Linear,
        Allocation_Contention => Allocation_Algorithms.Whole_Allocator,
        Release_Contention    => Allocation_Algorithms.Whole_Allocator,
        In_Band_Metadata      => True,
        Splits_Blocks         => True,
        Coalesces_On_Release  => False,
        Timed_Contention      => True,
        Release_Exclusion     => True),
     Algorithm_Configuration => Best_Fit_Kernel.Configuration,
     Algorithm_View => Best_Fit_Kernel.View,
     Implementation_Usable_Capacity =>
       Best_Fit_Kernel.Configuration_Usable_Capacity,
     Implementation_Minimum_Block_Size =>
       Best_Fit_Kernel.Configuration_Minimum_Block_Size,
     Implementation_Required_Storage =>
       Best_Fit_Kernel.Required_Storage,
     Implementation_Initialize => Best_Fit_Kernel.Initialize,
     Implementation_Create_Or_Attach =>
       Best_Fit_Kernel.Create_Or_Attach,
     Implementation_Attach => Best_Fit_Kernel.Attach,
     Implementation_Detach => Best_Fit_Kernel.Detach,
     Implementation_Is_Attached => Best_Fit_Kernel.Is_Attached,
     Implementation_Current_Metadata =>
       Best_Fit_Kernel.Current_Metadata,
     Implementation_Is_Poisoned => Best_Fit_Kernel.Is_Poisoned,
     Implementation_Poison => Best_Fit_Kernel.Poison,
     Implementation_Try_Allocate_Immediate =>
       Best_Fit_Kernel.Try_Allocate,
     Implementation_Try_Allocate_Timed => Best_Fit_Kernel.Try_Allocate,
     Implementation_Release_Immediate => Best_Fit_Kernel.Release,
     Implementation_Release_Timed => Best_Fit_Kernel.Release,
     Implementation_Block_Capacity => Best_Fit_Kernel.Block_Capacity,
     Implementation_Attach_Allocation =>
       Best_Fit_Kernel.Attach_Allocation,
     Implementation_Copy => Best_Fit_Kernel.Copy,
     Implementation_Destroy => Best_Fit_Kernel.Destroy);
