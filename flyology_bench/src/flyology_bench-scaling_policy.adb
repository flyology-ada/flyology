--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

package body Flyology_Bench.Scaling_Policy
  with SPARK_Mode => On
is
   function Range_Is_Degenerate (Minimum : Sweeps.Exact_Value; Maximum : Sweeps.Exact_Value) return Boolean
   is (Maximum / 2 < Minimum);
end Flyology_Bench.Scaling_Policy;
