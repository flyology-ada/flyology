--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

--  Test-only construction of deterministic benchmark measurements.
package Flyology_Bench.Baselines.Testing is
   type Sample_Vector is array (Positive range <>) of Long_Float;

   function Measurement_From
     (Values : Sample_Vector) return Flyology_Bench.Measurement;
end Flyology_Bench.Baselines.Testing;
