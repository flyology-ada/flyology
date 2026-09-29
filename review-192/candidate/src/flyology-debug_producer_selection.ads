--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

--  Automatic producer-shard selection for an independently instantiated
--  Flyology_Debug.Tracers package. This package does not make Flyology depend
--  on Flyology_Debug; pass Choose as the tracer's Select_Producer actual.

package Flyology.Debug_Producer_Selection
  with Preelaborate
is

   --  Select a shard without allocation or locking. A lightweight task maps
   --  its current execution group modulo Producer_Count, so tasks that can run
   --  concurrently use different shards when the configured counts permit it.
   --  Migration may change the shard used by later traces. A native task maps
   --  a stable hash of pthread_self instead. Producer_Count equal to one
   --  avoids both runtime identity queries.
   --  @param Producer_Count Number of configured producer shards
   --  @return Producer identifier in 1 .. Producer_Count
   function Choose (Producer_Count : Positive) return Positive
   with Inline;
end Flyology.Debug_Producer_Selection;
