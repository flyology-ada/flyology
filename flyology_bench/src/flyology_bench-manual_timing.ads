--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

--  Static adapter for a caller-completed alternate timing source. The batch
--  must synchronize all measured work before returning Elapsed; asynchronous
--  submission latency is not device execution time. Harness wall time remains
--  the calibration, budget, interference, and progress clock. Each Measure
--  invocation owns its adapter state, so one generic instance is reentrant.
generic
   Source_Name : String;
   Unit : String;
   Resolution : Long_Float;
   Scale_To_Unit : Long_Float := 1.0;
   Scope : Metric_Scope;
   Attribution : Metric_Attribution;
   with procedure Batch
     (Iterations : Iteration_Count;
      Elapsed    : out Long_Float;
      Status     : out Metric_Availability);
package Flyology_Bench.Manual_Timing is
   --  Measure batches using equal harness-wall calibration. The completed
   --  alternate elapsed value is retained as custom axis "primary_time" and
   --  divided by the exact logical-operation count. Its reported resolution
   --  is divided by the same count. Existing custom axes and their provider
   --  remain active; the timer consumes one free registry slot. No wall timer
   --  cost is subtracted from it.
   procedure Measure
     (Config : Configuration := Default_Configuration;
      Result : out Measurement);
end Flyology_Bench.Manual_Timing;
