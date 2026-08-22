--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

--  Paired static adapter for caller-completed alternate elapsed values. Each
--  Compare invocation owns its state and composes with an existing custom
--  provider while consuming one free registry slot. Reference and contender
--  resolutions are normalized by their respective iteration counts.
generic
   Source_Name : String;
   Unit : String;
   Resolution : Long_Float;
   Scale_To_Unit : Long_Float := 1.0;
   Scope : Metric_Scope;
   Attribution : Metric_Attribution;
   with procedure Reference_Batch
     (Iterations : Iteration_Count;
      Elapsed    : out Long_Float;
      Status     : out Metric_Availability);
   with procedure Contender_Batch
     (Iterations : Iteration_Count;
      Elapsed    : out Long_Float;
      Status     : out Metric_Availability);
package Flyology_Bench.Manual_Timing_Comparison is
   procedure Compare
     (Config : Configuration := Default_Configuration;
      Result : out Comparison);
end Flyology_Bench.Manual_Timing_Comparison;
