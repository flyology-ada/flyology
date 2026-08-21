--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

package body Flyology_Bench.Workers.Test_Support is
   procedure Corrupt_Comparison_Counts (Value : in out Comparison) is
   begin
      Value.Tie_Total := Natural (Value.Reference_Data.Sample_Total) + 1;
   end Corrupt_Comparison_Counts;

   procedure Corrupt_Comparison_Statistics (Value : in out Comparison) is
   begin
      Value.Geometric_Speedup := Value.Geometric_Speedup + 1.0;
   end Corrupt_Comparison_Statistics;

   procedure Corrupt_Metric_Request (Value : in out Measurement) is
   begin
      Value.Metric_Data.Data.Requested (Wall_Time) := False;
   end Corrupt_Metric_Request;

   procedure Corrupt_Iteration_Count (Value : in out Measurement) is
   begin
      Value.Iterations := Value.Iterations + 1;
   end Corrupt_Iteration_Count;

   procedure Corrupt_Sample_Count (Value : in out Measurement) is
   begin
      Value.Sample_Total := Value.Sample_Total - 1;
   end Corrupt_Sample_Count;

   procedure Corrupt_Statistics (Value : in out Measurement) is
   begin
      Value.Median := Value.Maximum + 1.0;
   end Corrupt_Statistics;

   procedure Corrupt_Environment_Report (Value : in out Measurement) is
   begin
      Value.Environment_Data.Contaminated_Samples := 1;
      Value.Environment_Data.Observed_Samples := 0;
   end Corrupt_Environment_Report;
end Flyology_Bench.Workers.Test_Support;
