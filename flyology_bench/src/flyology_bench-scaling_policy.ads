--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Flyology_Bench.Sweeps;

--  Exact, proved classification used before floating-point model fitting.
private package Flyology_Bench.Scaling_Policy
  with SPARK_Mode => On
is
   use type Sweeps.Exact_Value;

   --  Report whether the inclusive positive input range spans less than a
   --  factor of two. Division avoids overflow at the Exact_Value upper bound.
   function Range_Is_Degenerate
     (Minimum : Sweeps.Exact_Value;
      Maximum : Sweeps.Exact_Value) return Boolean
   with Pre  => Minimum <= Maximum,
        Post =>
          Range_Is_Degenerate'Result =
            (Minimum > Sweeps.Exact_Value'Last / 2
             or else Maximum < Minimum * 2);
end Flyology_Bench.Scaling_Policy;
