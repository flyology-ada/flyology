with Flyology.Data_Structures.Allocation_Algorithms.TLSF_Kernel;
with Flyology.Data_Structures.Allocation_Algorithms.Contract;

--  Two-level segregated-fit allocation for relocatable arenas. Fixed-size
--  bitmaps select offset-linked free lists; in-band boundary metadata supports
--  splitting and demand-driven adjacent-block coalescing. Release returns a
--  block directly to its size class; an allocation miss performs a bounded
--  physical coalescing pass before reporting exhaustion. One persisted
--  nonblocking guard serializes allocation and release across mappings.
--  Payload access requires the handle owner to exclude release. A dead guard
--  owner leaves the allocator locked until an external authority poisons it,
--  and exclusive reinitialization is the only recovery.
package Flyology.Data_Structures.Allocation_Algorithms.TLSF is new
  Flyology.Data_Structures.Allocation_Algorithms.Contract
    (Algorithm_Identity => TLSF_Kernel.Identity,
     Algorithm_Minimum_Block_Limit =>
       TLSF_Kernel.Minimum_Block_Limit,
     Algorithm_Capabilities =>
       (Search                => Allocation_Algorithms.Linear,
        Allocation_Contention => Allocation_Algorithms.Whole_Allocator,
        Release_Contention    => Allocation_Algorithms.Whole_Allocator,
        In_Band_Metadata      => True,
        Splits_Blocks         => True,
        Coalesces_On_Release  => False,
        Timed_Contention      => True,
        Release_Exclusion     => True),
     Algorithm_Configuration => TLSF_Kernel.Configuration,
     Algorithm_View => TLSF_Kernel.View,
     Implementation_Required_Storage =>
       TLSF_Kernel.Required_Storage,
     Implementation_Initialize => TLSF_Kernel.Initialize,
     Implementation_Create_Or_Attach =>
       TLSF_Kernel.Create_Or_Attach,
     Implementation_Attach => TLSF_Kernel.Attach,
     Implementation_Detach => TLSF_Kernel.Detach,
     Implementation_Is_Attached => TLSF_Kernel.Is_Attached,
     Implementation_Current_Metadata =>
       TLSF_Kernel.Current_Metadata,
     Implementation_Is_Poisoned => TLSF_Kernel.Is_Poisoned,
     Implementation_Poison => TLSF_Kernel.Poison,
     Implementation_Try_Allocate_Immediate =>
       TLSF_Kernel.Try_Allocate,
     Implementation_Try_Allocate_Timed => TLSF_Kernel.Try_Allocate,
     Implementation_Release_Immediate => TLSF_Kernel.Release,
     Implementation_Release_Timed => TLSF_Kernel.Release,
     Implementation_Block_Capacity => TLSF_Kernel.Block_Capacity,
     Implementation_Attach_Allocation =>
       TLSF_Kernel.Attach_Allocation,
     Implementation_Bind_Allocation =>
       TLSF_Kernel.Bind_Allocation,
     Implementation_Read => TLSF_Kernel.Read,
     Implementation_Write => TLSF_Kernel.Write,
     Implementation_Copy => TLSF_Kernel.Copy,
     Implementation_Destroy => TLSF_Kernel.Destroy);
