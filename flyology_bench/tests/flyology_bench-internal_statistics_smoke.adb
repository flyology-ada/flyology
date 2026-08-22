--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Text_IO;
with Flyology_Bench.Internal_Statistics;

procedure Flyology_Bench.Internal_Statistics_Smoke is
   package Statistics renames Flyology_Bench.Internal_Statistics;
   use type Statistics.Bootstrap_Work_Count;

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   Values : Statistics.Float_Array (1 .. 10_000);
   Work   : Statistics.Bootstrap_Work_Count := 0;
begin
   for Index in Values'Range loop
      Values (Index) := Long_Float (Values'Last - Index);
   end loop;
   Statistics.Sort (Values);
   for Index in Values'First + 1 .. Values'Last loop
      Check (Values (Index - 1) <= Values (Index), "10,000-element statistical sort is not ordered");
   end loop;

   Check (Statistics.Lower_Tail (95.0) = 0.025, "confidence tail conversion changed");
   Check (Statistics.Percentile (Values, 0.5) = 4_999.5, "shared percentile calculation changed");

   Statistics.Add_Bootstrap_Work
     (Total => Work, Samples => 1_000, Resamples => 10_000, Intervals => 10, Context => "exact-bound test");
   Check (Work = Statistics.Maximum_Bootstrap_Sample_Draws, "maximum permitted bootstrap work was rejected");

   declare
      Rejected : Boolean := False;
   begin
      begin
         Statistics.Add_Bootstrap_Work
           (Total => Work, Samples => 1, Resamples => 100, Intervals => 1, Context => "over-bound test");
      exception
         when Constraint_Error =>
            Rejected := True;
      end;
      Check (Rejected, "bootstrap work above the limit was accepted");
   end;

   declare
      Overflow_Work : Statistics.Bootstrap_Work_Count := 0;
      Rejected      : Boolean := False;
   begin
      begin
         Statistics.Add_Bootstrap_Work
           (Total     => Overflow_Work,
            Samples   => Natural'Last,
            Resamples => Flyology_Bench.Bootstrap_Resample_Count'Last,
            Intervals => Natural'Last,
            Context   => "overflow test");
      exception
         when Constraint_Error =>
            Rejected := True;
      end;
      Check (Rejected, "overflow-sized bootstrap work was accepted");
   end;

   Ada.Text_IO.Put_Line ("flyology_bench internal statistics smoke: PASS");
end Flyology_Bench.Internal_Statistics_Smoke;
