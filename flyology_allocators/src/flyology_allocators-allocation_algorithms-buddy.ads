with Flyology_Allocators.Allocation_Algorithms.Buddy_Kernel;
with Flyology_Allocators.Allocation_Algorithms.Contract;

--  Buddy allocation for relocatable arenas. The persisted complete binary
--  tree splits power-of-two blocks and retains released paths for reuse. An
--  allocation miss coalesces the complete tree before reporting exhaustion,
--  so worst-case search is linear in the stored node count. One persisted
--  nonblocking guard serializes allocation and release across attached views;
--  payload access requires the handle owner to exclude release. A dead guard
--  owner leaves the allocator locked until an external authority poisons it,
--  and exclusive reinitialization is the only recovery.

package Flyology_Allocators.Allocation_Algorithms.Buddy is new
  Flyology_Allocators.Allocation_Algorithms.Contract
    (Algorithm_Minimum_Block_Limit         => Buddy_Kernel.Minimum_Block_Limit,
     Algorithm_Capabilities                =>
       (Search                => Allocation_Algorithms.Linear,
        Allocation_Contention => Allocation_Algorithms.Whole_Allocator,
        Release_Contention    => Allocation_Algorithms.Whole_Allocator,
        In_Band_Metadata      => False,
        Splits_Blocks         => True,
        Coalesces_On_Release  => False,
        Timed_Contention      => True,
        Release_Exclusion     => True),
     Algorithm_Configuration               => Buddy_Kernel.Configuration,
     Algorithm_View                        => Buddy_Kernel.View,
     Implementation_Usable_Capacity        => Buddy_Kernel.Configuration_Usable_Capacity,
     Implementation_Minimum_Block_Size     => Buddy_Kernel.Configuration_Minimum_Block_Size,
     Implementation_Required_Storage       => Buddy_Kernel.Required_Storage,
     Implementation_Initialize             => Buddy_Kernel.Initialize,
     Implementation_Create_Or_Attach       => Buddy_Kernel.Create_Or_Attach,
     Implementation_Attach                 => Buddy_Kernel.Attach,
     Implementation_Detach                 => Buddy_Kernel.Detach,
     Implementation_Is_Attached            => Buddy_Kernel.Is_Attached,
     Implementation_Current_Metadata       => Buddy_Kernel.Current_Metadata,
     Implementation_Is_Poisoned            => Buddy_Kernel.Is_Poisoned,
     Implementation_Poison                 => Buddy_Kernel.Poison,
     Implementation_Try_Allocate_Immediate => Buddy_Kernel.Try_Allocate,
     Implementation_Try_Allocate_Timed     => Buddy_Kernel.Try_Allocate,
     Implementation_Release_Immediate      => Buddy_Kernel.Release,
     Implementation_Release_Timed          => Buddy_Kernel.Release,
     Implementation_Block_Capacity         => Buddy_Kernel.Block_Capacity,
     Implementation_Attach_Allocation      => Buddy_Kernel.Attach_Allocation,
     Implementation_Copy                   => Buddy_Kernel.Copy,
     Implementation_Destroy                => Buddy_Kernel.Destroy);
