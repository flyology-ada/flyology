--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

--  Shared bounded statistical mechanisms for benchmark analyses.

private package Flyology_Bench.Internal_Statistics is
   --  Maximum aggregate number of source-sample draws performed by one
   --  public analysis call. This bounds work independently of array sizes.
   Maximum_Bootstrap_Sample_Draws : constant := 100_000_000;

   --  Accumulated sample-draw work for one analysis call.
   type Bootstrap_Work_Count is range 0 .. Long_Long_Integer'Last;

   --  Shared floating-point array used by statistical calculations.
   type Float_Array is array (Positive range <>) of Long_Float;

   --  Sort values into nondecreasing order.
   --  @param Values Array to sort in place.
   procedure Sort (Values : in out Float_Array);

   --  Interpolate a percentile from an ordered array.
   --  @param Ordered Nonempty array in nondecreasing order.
   --  @param Fraction Quantile from zero through one.
   --  @return Interpolated quantile value.
   function Percentile (Ordered : Float_Array; Fraction : Long_Float) return Long_Float;

   --  Convert central confidence coverage into one two-sided tail fraction.
   --  @param Confidence Central interval coverage in percent.
   --  @return Tail probability from 0.0005 through 0.25.
   function Lower_Tail (Confidence : Confidence_Percentage) return Long_Float;

   --  Add one group of bootstrap intervals to Total. The calculation checks
   --  every factor before multiplication and raises Constraint_Error when the
   --  aggregate would exceed Maximum_Bootstrap_Sample_Draws.
   --  @param Total Accumulated work, updated on success.
   --  @param Samples Source-sample draws in each interval resample.
   --  @param Resamples Bootstrap distributions drawn for each interval.
   --  @param Intervals Number of intervals with the same sample count.
   --  @param Context Analysis name used in a rejection message.
   --  @exception Constraint_Error The aggregate exceeds the work ceiling.
   procedure Add_Bootstrap_Work
     (Total     : in out Bootstrap_Work_Count;
      Samples   : Natural;
      Resamples : Bootstrap_Resample_Count;
      Intervals : Natural;
      Context   : String);
end Flyology_Bench.Internal_Statistics;
