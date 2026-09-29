with Flyology.Data_Structures.Allocation_Algorithms.Adapter;
with Flyology_Allocators.Allocation_Algorithms.Slab_Span;

--  Flyology persisted-object adapter for the standalone slab/span allocator.
--  @exclude

package Flyology.Data_Structures.Allocation_Algorithms.Slab_Span_Kernel is new
  Flyology.Data_Structures.Allocation_Algorithms.Adapter
    (Algorithm_Magic   => 16#4644_5353_5041_3031#,
     Algorithm_Version => 1,
     Algorithm_Schema  => 16#0001_5350_414E_0001#,
     Algorithm         => Flyology_Allocators.Allocation_Algorithms.Slab_Span);
