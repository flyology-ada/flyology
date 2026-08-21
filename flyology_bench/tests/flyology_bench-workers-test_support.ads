--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

--  Test-only access to private result fields for malformed-envelope fixtures.
package Flyology_Bench.Workers.Test_Support is
   procedure Corrupt_Comparison_Counts (Value : in out Comparison);
   procedure Corrupt_Comparison_Statistics (Value : in out Comparison);
   procedure Corrupt_Environment_Report (Value : in out Measurement);
   procedure Corrupt_Metric_Request (Value : in out Measurement);
   procedure Corrupt_Statistics (Value : in out Measurement);
end Flyology_Bench.Workers.Test_Support;
