with Flyology.Data_Structures.Allocation_Algorithms.Contract;
with Flyology.Data_Structures.Allocation_Algorithms.Slab_Span_Kernel;

--  Hybrid slab/span allocation for relocatable Flyology arenas. Small-object
--  classes use bitmap slots in fixed runs while larger allocations reserve
--  contiguous runs. Empty slabs remain reusable until allocation pressure
--  reclaims them. Flyology owns the outer identity and lifecycle; the nested
--  standalone algorithm remains identity-free.
package Flyology.Data_Structures.Allocation_Algorithms.Slab_Span is new
  Flyology.Data_Structures.Allocation_Algorithms.Contract
    (Algorithm_Identity => Slab_Span_Kernel.Identity,
     Algorithm_Minimum_Block_Limit => Slab_Span_Kernel.Minimum_Block_Limit,
     Algorithm_Capabilities =>
       (Search                => Allocation_Algorithms.Linear,
        Allocation_Contention => Allocation_Algorithms.Whole_Allocator,
        Release_Contention    => Allocation_Algorithms.Whole_Allocator,
        In_Band_Metadata      => False,
        Splits_Blocks         => True,
        Coalesces_On_Release  => False,
        Timed_Contention      => True,
        Release_Exclusion     => True),
     Algorithm_Configuration => Slab_Span_Kernel.Configuration,
     Algorithm_View => Slab_Span_Kernel.View,
     Implementation_Required_Storage => Slab_Span_Kernel.Required_Storage,
     Implementation_Initialize => Slab_Span_Kernel.Initialize,
     Implementation_Create_Or_Attach => Slab_Span_Kernel.Create_Or_Attach,
     Implementation_Attach => Slab_Span_Kernel.Attach,
     Implementation_Detach => Slab_Span_Kernel.Detach,
     Implementation_Is_Attached => Slab_Span_Kernel.Is_Attached,
     Implementation_Current_Metadata => Slab_Span_Kernel.Current_Metadata,
     Implementation_Is_Poisoned => Slab_Span_Kernel.Is_Poisoned,
     Implementation_Poison => Slab_Span_Kernel.Poison,
     Implementation_Try_Allocate_Immediate => Slab_Span_Kernel.Try_Allocate,
     Implementation_Try_Allocate_Timed => Slab_Span_Kernel.Try_Allocate,
     Implementation_Release_Immediate => Slab_Span_Kernel.Release,
     Implementation_Release_Timed => Slab_Span_Kernel.Release,
     Implementation_Block_Capacity => Slab_Span_Kernel.Block_Capacity,
     Implementation_Attach_Allocation => Slab_Span_Kernel.Attach_Allocation,
     Implementation_Bind_Allocation => Slab_Span_Kernel.Bind_Allocation,
     Implementation_Read => Slab_Span_Kernel.Read,
     Implementation_Write => Slab_Span_Kernel.Write,
     Implementation_Copy => Slab_Span_Kernel.Copy,
     Implementation_Destroy => Slab_Span_Kernel.Destroy);
