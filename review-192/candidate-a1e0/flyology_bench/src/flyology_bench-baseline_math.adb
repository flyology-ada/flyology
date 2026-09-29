--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

package body Flyology_Bench.Baseline_Math
  with SPARK_Mode => On
is
   procedure Add_To_Sum (Sum : in out Long_Float; Value : Long_Float) is
   begin
      Sum := Sum + Value;
   end Add_To_Sum;

   function Mean (Sum : Long_Float; Count : Sample_Count) return Long_Float
   is (Sum / Long_Float (Count));

   function Ratio (Numerator, Denominator : Long_Float) return Long_Float
   is (Numerator / Denominator);

   function Time_Change (Speedup : Long_Float) return Long_Float is
      Result : Long_Float;
   begin
      if Speedup >= 1.0 then
         Result := -100.0 * (1.0 - 1.0 / Speedup);
         pragma Assert (Result >= -100.0);
      else
         Result := 100.0 / Speedup - 100.0;
         pragma Assert (Result <= Maximum_Time_Change);
      end if;
      return Result;
   end Time_Change;

   function Interpolate (Low, High, Weight : Long_Float) return Long_Float
   is (Low + (High - Low) * Weight);

   function Classify
     (Change_Low, Change_High : Long_Float; Threshold : Threshold_Percentage) return Comparison_Verdict is
   begin
      if Change_High < -Threshold then
         return Contender_Faster;
      elsif Change_Low > Threshold then
         return Reference_Faster;
      elsif Change_Low >= -Threshold and then Change_High <= Threshold then
         return Practically_Equivalent;
      else
         return Inconclusive;
      end if;
   end Classify;
end Flyology_Bench.Baseline_Math;
