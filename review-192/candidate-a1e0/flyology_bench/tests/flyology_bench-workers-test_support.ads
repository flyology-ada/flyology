--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

--  Test-only access to private result fields for malformed-envelope fixtures.

package Flyology_Bench.Workers.Test_Support is
   procedure Corrupt_Comparison_Counts (Value : in out Comparison);
   procedure Corrupt_Comparison_Statistics (Value : in out Comparison);
   procedure Corrupt_Control_Metadata (Value : in out Measurement);
   procedure Corrupt_Condition_Windows (Value : in out Measurement);
   procedure Corrupt_Disabled_Condition_State (Value : in out Measurement);
   procedure Corrupt_Enabled_Condition_State (Value : in out Measurement);
   procedure Corrupt_Condition_Detector_Category (Value : in out Measurement);
   procedure Corrupt_Fail_Affected (Value : in out Measurement);
   procedure Corrupt_Environment_Report (Value : in out Measurement);
   procedure Corrupt_Interference_Metadata (Value : in out Measurement);
   procedure Corrupt_Metric_Request (Value : in out Measurement);
   procedure Corrupt_Telemetry (Value : in out Measurement);
   procedure Corrupt_Unavailable_Telemetry (Value : in out Measurement);
   procedure Corrupt_Unavailable_Metric (Value : in out Measurement);
   procedure Corrupt_Unrequested_Metric (Value : in out Measurement);
   procedure Corrupt_Iteration_Count (Value : in out Measurement);
   procedure Corrupt_Sample_Count (Value : in out Measurement);
   procedure Corrupt_Statistics (Value : in out Measurement);
end Flyology_Bench.Workers.Test_Support;
