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

   procedure Corrupt_Control_Metadata (Value : in out Measurement) is
   begin
      Value.Environment_Data.Placement := Placement_Strict;
      Value.Environment_Data.Attribution := Core_Scoped;
      Value.Environment_Data.Watched_CPUs := 1;
   end Corrupt_Control_Metadata;

   procedure Corrupt_Metric_Request (Value : in out Measurement) is
   begin
      Value.Metric_Data.Data.Requested (Wall_Time) := False;
   end Corrupt_Metric_Request;

   procedure Corrupt_Telemetry (Value : in out Measurement) is
   begin
      Value.Telemetry_Available := True;
      Value.Telemetry_CPU_Total := 1.0;
      Value.Telemetry_Wall_Total := 1.0;
      Value.Telemetry_RSS_Start := 1.0;
      Value.Telemetry_RSS_Final := 1.0;
      Value.Telemetry_RSS_Peak := 1.0;
   end Corrupt_Telemetry;

   procedure Corrupt_Unavailable_Telemetry (Value : in out Measurement) is
   begin
      Value.Telemetry_Available := False;
      Value.Telemetry_CPU_Total := 1.0;
   end Corrupt_Unavailable_Telemetry;

   procedure Corrupt_Unavailable_Metric (Value : in out Measurement) is
   begin
      Value.Metric_Data.Data.Summaries (Flyology_Dispatches).Mean := 1.0;
   end Corrupt_Unavailable_Metric;

   procedure Corrupt_Unrequested_Metric (Value : in out Measurement) is
   begin
      Value.Metric_Data.Data.Summaries (Process_CPU_Time).Mean := 1.0;
      Value.Metric_Data.Data.Values (Process_CPU_Time, 1) := 1.0;
   end Corrupt_Unrequested_Metric;

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

   procedure Corrupt_Interference_Metadata (Value : in out Measurement) is
   begin
      Value.Environment_Data.Watched := True;
      Value.Environment_Data.Windows := 1;
      Value.Environment_Data.Mean_Foreign_CPU_Percent := 1.0;
      Value.Environment_Data.Peak_Foreign_CPU_Percent := 1.0;
   end Corrupt_Interference_Metadata;
end Flyology_Bench.Workers.Test_Support;
