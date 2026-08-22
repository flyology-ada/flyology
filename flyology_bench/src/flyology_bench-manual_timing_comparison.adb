--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

package body Flyology_Bench.Manual_Timing_Comparison is
   function Output_Resolution return Long_Float is
   begin
      if Resolution /= Resolution
        or else Resolution <= 0.0
        or else Resolution > Long_Float'Last
        or else Scale_To_Unit /= Scale_To_Unit
        or else Scale_To_Unit <= 0.0
        or else Scale_To_Unit > Long_Float'Last
      then
         raise Constraint_Error with "invalid alternate timing conversion";
      elsif Scale_To_Unit > 1.0 and then Resolution > Long_Float'Last / Scale_To_Unit then
         raise Constraint_Error with "alternate timing resolution conversion overflow";
      end if;
      return Resolution * Scale_To_Unit;
   end Output_Resolution;

   procedure Compare (Config : Configuration := Default_Configuration; Result : out Comparison) is
      Effective         : Configuration := Config;
      Caller_Probe      : constant Custom_Probe := Effective.Custom_Metrics.Provider;
      Source_Resolution : constant Long_Float := Output_Resolution;
      Timer_Axis        : Custom_Metric_Index := Custom_Metric_Index'First;
      Latest            : Custom_Value := (Status => Metric_Not_Requested, others => <>);

      procedure Store (Raw : Long_Float; Status : Metric_Availability) is
      begin
         Latest := (Status => Status, Sample_Value => 0.0, Counter_Value => 0);
         if Status = Metric_Collected then
            if Raw /= Raw
              or else abs Raw > Long_Float'Last
              or else Raw < 0.0
              or else Scale_To_Unit /= Scale_To_Unit
              or else abs Scale_To_Unit > Long_Float'Last
              or else Scale_To_Unit < 0.0
            then
               Latest.Status := Invalid_Value;
            elsif Scale_To_Unit > 1.0 and then Raw > Long_Float'Last / Scale_To_Unit then
               Latest.Status := Conversion_Overflow;
            else
               Latest.Sample_Value := Raw * Scale_To_Unit;
            end if;
         end if;
      end Store;

      procedure Run_Reference (Iterations : Iteration_Count) is
         Raw    : Long_Float;
         Status : Metric_Availability;
      begin
         Reference_Batch (Iterations, Raw, Status);
         Store (Raw, Status);
      end Run_Reference;

      procedure Run_Contender (Iterations : Iteration_Count) is
         Raw    : Long_Float;
         Status : Metric_Availability;
      begin
         Contender_Batch (Iterations, Raw, Status);
         Store (Raw, Status);
      end Run_Contender;

      procedure Read (Snapshot : in out Custom_Snapshot) is
      begin
         if Caller_Probe /= null then
            begin
               Caller_Probe.all (Snapshot);
            exception
               when others =>
                  Snapshot := [others => (Status => Probe_Failed, others => <>)];
            end;
         end if;
         Snapshot (Timer_Axis) := Latest;
      end Read;

      procedure Underlying is new Flyology_Bench.Compare_Batched (Run_Reference, Run_Contender);
   begin
      Register_Custom_Metric
        (Effective.Custom_Metrics,
         Name           => "primary_time",
         Unit           => Unit,
         Scope          => Scope,
         Attribution    => Attribution,
         Direction      => Lower_Is_Better,
         Semantics      => Completed_Elapsed,
         Normalization  => Per_Operation,
         Comparison     => Relative_Positive,
         Primary_Timing => True,
         Timing_Source  => Source_Name,
         Resolution     => Source_Resolution);
      Timer_Axis := Custom_Metric_Index (Custom_Metrics (Effective.Custom_Metrics));
      --  Effective is consumed synchronously and completed results copy only
      --  metadata and values, never this instance-local callback address.
      Set_Custom_Probe (Effective.Custom_Metrics, Read'Unrestricted_Access);
      Underlying (Effective, Result);
      Result.Reference_Data.Custom_Data.Data.Descriptors (Timer_Axis).Resolution_Value :=
        Source_Resolution / Long_Float (Iterations_Per_Sample (Result.Reference_Data));
      Result.Contender_Data.Custom_Data.Data.Descriptors (Timer_Axis).Resolution_Value :=
        Source_Resolution / Long_Float (Iterations_Per_Sample (Result.Contender_Data));
   end Compare;
end Flyology_Bench.Manual_Timing_Comparison;
