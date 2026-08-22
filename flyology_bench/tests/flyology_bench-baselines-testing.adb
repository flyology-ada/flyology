--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

package body Flyology_Bench.Baselines.Testing is
   function Measurement_From
     (Values : Sample_Vector) return Flyology_Bench.Measurement
   is
      Result : Flyology_Bench.Measurement;
   begin
      if Values'Length not in
        Natural (Sample_Count'First) .. Natural (Sample_Count'Last)
      then
         raise Constraint_Error with
           "test sample count is outside the measurement range";
      end if;

      Result.Sample_Total := Sample_Count (Values'Length);
      for Index in Values'Range loop
         Result.Values
           (Sample_Index (Index - Values'First + 1)) := Values (Index);
      end loop;
      return Result;
   end Measurement_From;
end Flyology_Bench.Baselines.Testing;
