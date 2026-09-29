--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

package Flyology_Bench.Host_Control is
   --  Optional host controls for reducing benchmark placement noise.

   --  Strength of the placement policy applied by the host.
   --  @enum Advisory Placement is a scheduler hint rather than a hard binding.
   --  @enum Strict The calling thread is bound to the selected logical CPU.
   type Placement_Strength is (Advisory, Strict);

   --  Pin or affinity-tag the calling native thread. Linux applies strict CPU
   --  affinity. Darwin applies a scheduler affinity tag, which is advisory and
   --  groups threads by cache affinity rather than naming a CPU; Apple Silicon
   --  implements no thread affinity at all and rejects every request, so
   --  placement there is unavailable rather than weak.
   --  Call this from the thread that will execute the benchmark.
   --  @param CPU Zero-based logical CPU or Darwin affinity tag index.
   --  @return Strength of the applied platform policy.
   --  @exception Program_Error If the platform rejects the request.
   function Pin_Current_Thread (CPU : Natural) return Placement_Strength;
end Flyology_Bench.Host_Control;
