--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Containers.Generic_Array_Sort;

package body Flyology_Bench.Internal_Statistics is
   procedure Sort_Array is new
     Ada.Containers.Generic_Array_Sort
       (Index_Type   => Positive,
        Element_Type => Long_Float,
        Array_Type   => Float_Array);

   procedure Sort (Values : in out Float_Array) is
   begin
      Sort_Array (Values);
   end Sort;

   function Percentile (Ordered : Float_Array; Fraction : Long_Float) return Long_Float is
      Position : constant Long_Float :=
        Long_Float (Ordered'First) + Fraction * Long_Float (Ordered'Length - 1);
      Lower    : constant Positive := Positive (Long_Float'Floor (Position));
      Upper    : constant Positive := Positive (Long_Float'Ceiling (Position));
      Weight   : constant Long_Float := Position - Long_Float (Lower);
   begin
      return Ordered (Lower) * (1.0 - Weight) + Ordered (Upper) * Weight;
   end Percentile;

   function Lower_Tail (Confidence : Confidence_Percentage) return Long_Float
   is ((100.0 - Long_Float (Confidence)) / 200.0);

   procedure Add_Bootstrap_Work
     (Total     : in out Bootstrap_Work_Count;
      Samples   : Natural;
      Resamples : Bootstrap_Resample_Count;
      Intervals : Natural;
      Context   : String)
   is
      Limit : constant Bootstrap_Work_Count := Maximum_Bootstrap_Sample_Draws;
      Work  : Bootstrap_Work_Count;

      procedure Reject is
      begin
         raise Constraint_Error
           with
             Context & " bootstrap analysis exceeds" & Maximum_Bootstrap_Sample_Draws'Image & " sample draws";
      end Reject;
   begin
      if Samples = 0 or else Intervals = 0 then
         return;
      end if;

      Work := Bootstrap_Work_Count (Samples);
      if Bootstrap_Work_Count (Intervals) > Limit / Work then
         Reject;
      end if;
      Work := Work * Bootstrap_Work_Count (Intervals);

      if Bootstrap_Work_Count (Resamples) > Limit / Work then
         Reject;
      end if;
      Work := Work * Bootstrap_Work_Count (Resamples);

      if Total > Limit - Work then
         Reject;
      end if;
      Total := Total + Work;
   end Add_Bootstrap_Work;
end Flyology_Bench.Internal_Statistics;
