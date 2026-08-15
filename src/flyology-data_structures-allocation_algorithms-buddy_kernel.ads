with Flyology.Data_Structures.Allocation_Algorithms.Adapter;
with Flyology_Allocators.Allocation_Algorithms.Buddy;

--  Flyology persisted-object adapter for the standalone buddy allocator.
--  Version 3 excludes eager-coalescing readers: they accept a retained split
--  node with two free children but can falsely exhaust a parent-sized request.
--  @exclude
package Flyology.Data_Structures.Allocation_Algorithms.Buddy_Kernel is new
  Flyology.Data_Structures.Allocation_Algorithms.Adapter
    (Algorithm_Magic   => 16#4644_5341_5245_3031#,
     Algorithm_Version => 3,
     Algorithm_Schema  => 16#0001_4152_454E_0003#,
     Algorithm => Flyology_Allocators.Allocation_Algorithms.Buddy);
