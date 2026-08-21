--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Interfaces;

--  Overflow-safe floating-point primitives for saved-baseline statistics.
private package Flyology_Bench.Baseline_Math
  with SPARK_Mode => On
is
   Minimum_Sample_Nanoseconds : constant Long_Float :=
     1.0 / Long_Float (Positive_Iteration_Count'Last);
   Maximum_Sample_Nanoseconds : constant Long_Float :=
     Long_Float (Interfaces.Unsigned_64'Last);
   Maximum_Sample_Sum : constant Long_Float :=
     Maximum_Sample_Nanoseconds * Long_Float (Sample_Count'Last);
   Minimum_Speedup : constant Long_Float :=
     Minimum_Sample_Nanoseconds / Maximum_Sample_Nanoseconds;
   Maximum_Speedup : constant Long_Float :=
     Maximum_Sample_Nanoseconds / Minimum_Sample_Nanoseconds;
   Maximum_Time_Change : constant Long_Float :=
     100.0 / Minimum_Speedup - 100.0;

   function Is_Supported_Sample (Value : Long_Float) return Boolean is
     (Value in Minimum_Sample_Nanoseconds .. Maximum_Sample_Nanoseconds);

   function Is_Supported_Speedup (Value : Long_Float) return Boolean is
     (Value in Minimum_Speedup .. Maximum_Speedup);

   function Is_Supported_Sum (Value : Long_Float) return Boolean is
     (Value in 0.0 .. Maximum_Sample_Sum);

   function Can_Add_To_Sum
     (Sum, Value : Long_Float) return Boolean is
     (Is_Supported_Sum (Sum)
      and then Is_Supported_Sample (Value)
      and then Sum <= Maximum_Sample_Sum - Value);

   procedure Add_To_Sum
     (Sum   : in out Long_Float;
      Value : Long_Float)
   with
     Pre  => Can_Add_To_Sum (Sum, Value)
       and then Is_Supported_Sum (Sum + Value),
     Post => Is_Supported_Sum (Sum);

   function Mean
     (Sum   : Long_Float;
      Count : Sample_Count) return Long_Float
   with
     Pre  => Is_Supported_Sum (Sum)
       and then Sum >= Minimum_Sample_Nanoseconds,
     Post => Mean'Result > 0.0
       and then Mean'Result <= Maximum_Sample_Sum;

   function Ratio
     (Numerator, Denominator : Long_Float) return Long_Float
   with
     Pre  => Is_Supported_Sample (Numerator)
       and then Is_Supported_Sample (Denominator),
     Post => Is_Supported_Speedup (Ratio'Result);

   function Time_Change (Speedup : Long_Float) return Long_Float
   with
     Pre  => Is_Supported_Speedup (Speedup),
     Post => Time_Change'Result >= -100.0
       and then Time_Change'Result <= Maximum_Time_Change;

   function Interpolate
     (Low, High, Weight : Long_Float) return Long_Float
   with
     Pre  => Is_Supported_Speedup (Low)
       and then Is_Supported_Speedup (High)
       and then Low <= High
       and then Weight in 0.0 .. 1.0;

   function Classify
     (Change_Low, Change_High : Long_Float;
      Threshold               : Threshold_Percentage)
      return Comparison_Verdict
   with Pre => Change_Low >= -100.0
     and then Change_High >= Change_Low
     and then Change_High <= Maximum_Time_Change,
     Contract_Cases =>
       (Change_High < -Threshold => Classify'Result = Contender_Faster,
        Change_Low > Threshold  => Classify'Result = Reference_Faster,
        Change_Low >= -Threshold and then Change_High <= Threshold =>
          Classify'Result = Practically_Equivalent,
        others => Classify'Result = Inconclusive);
end Flyology_Bench.Baseline_Math;
