--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

package body Flyology_Bench.Workers.Test_Support is
   procedure Corrupt_Comparison_Counts (Value : in out Comparison) is
   begin
      Value.Tie_Total := Natural (Value.Reference_Data.Sample_Total) + 1;
   end Corrupt_Comparison_Counts;

   procedure Corrupt_Metric_Request (Value : in out Measurement) is
   begin
      Value.Metric_Data.Data.Requested (Wall_Time) := False;
   end Corrupt_Metric_Request;
end Flyology_Bench.Workers.Test_Support;
