with Flyology.Data_Structures.Allocation_Algorithms.Adapter;
with Flyology_Allocators.Allocation_Algorithms.TLSF;

--  Flyology persisted-object adapter for the standalone TLSF allocator.
--  Version 3 distinguishes lazy-coalescing images, whose valid physical chain
--  may contain adjacent free blocks, from version 2 images whose validator
--  required every such pair to be coalesced on release.
--  @exclude
package Flyology.Data_Structures.Allocation_Algorithms.TLSF_Kernel is new
  Flyology.Data_Structures.Allocation_Algorithms.Adapter
    (Algorithm_Magic   => 16#4644_5354_4C53_4631#,
     Algorithm_Version => 3,
     Algorithm_Schema  => 16#0001_544C_5346_0003#,
     Algorithm => Flyology_Allocators.Allocation_Algorithms.TLSF);
