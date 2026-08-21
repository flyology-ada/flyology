--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

package body Flyology_Bench.Manual_Timing_Comparison is
   Latest : Custom_Value;

   function Output_Resolution return Long_Float is
   begin
      if Resolution /= Resolution or else Resolution <= 0.0
        or else Resolution > Long_Float'Last
        or else Scale_To_Unit /= Scale_To_Unit
        or else Scale_To_Unit <= 0.0
        or else Scale_To_Unit > Long_Float'Last
      then
         raise Constraint_Error with "invalid alternate timing conversion";
      elsif Scale_To_Unit > 1.0
        and then Resolution > Long_Float'Last / Scale_To_Unit
      then
         raise Constraint_Error with
           "alternate timing resolution conversion overflow";
      end if;
      return Resolution * Scale_To_Unit;
   end Output_Resolution;

   procedure Store (Raw : Long_Float; Status : Metric_Availability) is
   begin
      Latest := (Status => Status, Sample_Value => 0.0, Counter_Value => 0);
      if Status = Metric_Collected then
         if Raw /= Raw or else abs Raw > Long_Float'Last or else Raw < 0.0
           or else Scale_To_Unit /= Scale_To_Unit
           or else abs Scale_To_Unit > Long_Float'Last
           or else Scale_To_Unit < 0.0
         then
            Latest.Status := Invalid_Value;
         elsif Scale_To_Unit > 1.0
           and then Raw > Long_Float'Last / Scale_To_Unit
         then
            Latest.Status := Conversion_Overflow;
         else
            Latest.Sample_Value := Raw * Scale_To_Unit;
         end if;
      end if;
   end Store;

   procedure Run_Reference (Iterations : Iteration_Count) is
      Raw : Long_Float;
      Status : Metric_Availability;
   begin
      Reference_Batch (Iterations, Raw, Status);
      Store (Raw, Status);
   end Run_Reference;

   procedure Run_Contender (Iterations : Iteration_Count) is
      Raw : Long_Float;
      Status : Metric_Availability;
   begin
      Contender_Batch (Iterations, Raw, Status);
      Store (Raw, Status);
   end Run_Contender;

   procedure Read (Snapshot : in out Custom_Snapshot) is
   begin
      Snapshot := [others => (Status => Metric_Not_Requested, others => <>)];
      Snapshot (1) := Latest;
   end Read;

   procedure Underlying is new Flyology_Bench.Compare_Batched
     (Run_Reference, Run_Contender);

   procedure Compare
     (Config : Configuration := Default_Configuration;
      Result : out Comparison)
   is
      Effective : Configuration := Config;
   begin
      if Custom_Metrics (Effective.Custom_Metrics) /= 0 then
         raise Constraint_Error with
           "manual timing adapter requires an empty custom metric registry";
      end if;
      Register_Custom_Metric
        (Effective.Custom_Metrics,
         Name => "primary_time", Unit => Unit, Scope => Scope,
         Attribution => Attribution, Direction => Lower_Is_Better,
         Semantics => Completed_Elapsed, Normalization => Per_Operation,
         Comparison => Relative_Positive, Primary_Timing => True,
         Timing_Source => Source_Name, Resolution => Output_Resolution);
      --  Effective is consumed synchronously and completed results copy only
      --  metadata and values, never this instance-local callback address.
      Set_Custom_Probe (Effective.Custom_Metrics, Read'Unrestricted_Access);
      Underlying (Effective, Result);
   end Compare;
end Flyology_Bench.Manual_Timing_Comparison;
