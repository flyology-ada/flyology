--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

--  Optional host controls for reducing benchmark placement noise.
package Flyology_Bench.Host_Control is
   --  Strength of the placement policy applied by the host.
   type Placement_Strength is (Advisory, Strict);

   --  Pin or affinity-tag the calling native thread. Linux applies strict CPU
   --  affinity; Darwin applies a scheduler affinity tag and is advisory.
   --  Call this from the thread that will execute the benchmark.
   --  @param CPU Zero-based logical CPU or Darwin affinity tag index.
   --  @return Strength of the applied platform policy.
   --  @exception Program_Error If the platform rejects the request.
   function Pin_Current_Thread (CPU : Natural) return Placement_Strength;
end Flyology_Bench.Host_Control;
