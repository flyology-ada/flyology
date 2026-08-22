with Flyology.Data_Structures.Allocation_Algorithms.Adapter;
with Flyology_Allocators.Allocation_Algorithms.Best_Fit;

--  Flyology persisted-object adapter for the standalone best-fit allocator.
--  Version 3 distinguishes deferred free-block coalescing from the eager
--  version-2 invariant so older Flyology readers reject newer images before
--  reaching the standalone attachment path.
--  @exclude

package Flyology.Data_Structures.Allocation_Algorithms.Best_Fit_Kernel is new
  Flyology.Data_Structures.Allocation_Algorithms.Adapter
    (Algorithm_Magic   => 16#4644_5342_4654_3031#,
     Algorithm_Version => 3,
     Algorithm_Schema  => 16#0001_4246_4954_0003#,
     Algorithm         => Flyology_Allocators.Allocation_Algorithms.Best_Fit);
