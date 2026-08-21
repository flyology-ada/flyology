--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Text_IO;
with Ada.Task_Attributes;
with Flyology_Bench;
with Flyology_Bench.Manual_Timing;
with Flyology_Bench.Manual_Timing_Comparison;
with Flyology_Bench.Reporters;

procedure Custom_Metrics_Smoke is
   use type Flyology_Bench.Metric_Availability;
   use type Flyology_Bench.Metric_Comparison_Method;
   use type Flyology_Bench.Metric_Verdict;
   use type Flyology_Bench.Metric_Attribution;

   Counter : Long_Long_Integer := 0;
   Probe_Calls : Natural := 0;

   procedure Counter_Probe (Snapshot : in out Flyology_Bench.Custom_Snapshot) is
   begin
      Probe_Calls := Probe_Calls + 1;
      Snapshot := [others => (Status => Flyology_Bench.Metric_Not_Requested,
                              others => <>)];
      Snapshot (1) :=
        (Status => Flyology_Bench.Metric_Collected,
         Counter_Value => Counter,
         Sample_Value => 0.0);
   end Counter_Probe;

   procedure Domain_Batch (Iterations : Flyology_Bench.Iteration_Count) is
   begin
      for Index in 1 .. Iterations loop
         Counter := Counter + 3;
      end loop;
   end Domain_Batch;
   procedure Domain_Measure is new Flyology_Bench.Measure_Batched (Domain_Batch);

   procedure Reference_Batch (Iterations : Flyology_Bench.Iteration_Count) is
   begin
      for Index in 1 .. Iterations loop
         Counter := Counter + 2;
      end loop;
   end Reference_Batch;
   procedure Contender_Batch (Iterations : Flyology_Bench.Iteration_Count) is
   begin
      for Index in 1 .. Iterations loop
         Counter := Counter + 4;
      end loop;
   end Contender_Batch;
   procedure Domain_Compare is new Flyology_Bench.Compare_Batched
     (Reference_Batch, Contender_Batch);

   type Multi_Case is (Reference_Case, Middle_Case, High_Case);
   procedure Multi_Batch
     (Which : Multi_Case; Iterations : Flyology_Bench.Iteration_Count) is
   begin
      for Index in 1 .. Iterations loop
         Counter := Counter + Long_Long_Integer (Multi_Case'Pos (Which) + 1);
      end loop;
   end Multi_Batch;
   procedure Domain_Multi is new Flyology_Bench.Compare_Many
     (Multi_Case, Multi_Batch);

   Reset_Call : Natural := 0;
   procedure Reset_Probe (Snapshot : in out Flyology_Bench.Custom_Snapshot) is
   begin
      Reset_Call := Reset_Call + 1;
      Snapshot := [others => (Status => Flyology_Bench.Metric_Not_Requested,
                              others => <>)];
      Snapshot (1) :=
        (Status => Flyology_Bench.Metric_Collected,
         Counter_Value => (if Reset_Call mod 2 = 1 then 10 else 5),
         Sample_Value => 0.0);
   end Reset_Probe;

   procedure Noop_Batch (Iterations : Flyology_Bench.Iteration_Count) is
      pragma Unreferenced (Iterations);
   begin
      null;
   end Noop_Batch;
   procedure Reset_Measure is new Flyology_Bench.Measure_Batched (Noop_Batch);

   Overflow_Call : Natural := 0;
   procedure Overflow_Probe
     (Snapshot : in out Flyology_Bench.Custom_Snapshot) is
   begin
      Overflow_Call := Overflow_Call + 1;
      Snapshot := [others => (Status => Flyology_Bench.Metric_Not_Requested,
                              others => <>)];
      Snapshot (1) :=
        (Status => Flyology_Bench.Metric_Collected,
         Counter_Value =>
           (if Overflow_Call mod 2 = 1
            then Long_Long_Integer'First else Long_Long_Integer'Last),
         Sample_Value => 0.0);
   end Overflow_Probe;

   Failed_Call : Natural := 0;
   Dummy : Long_Long_Integer := 0 with Volatile;
   procedure Partial_Probe (Snapshot : in out Flyology_Bench.Custom_Snapshot) is
   begin
      Failed_Call := Failed_Call + 1;
      Snapshot := [others => (Status => Flyology_Bench.Metric_Not_Requested,
                              others => <>)];
      Snapshot (1) :=
        (Status => (if Failed_Call = 2 then Flyology_Bench.Probe_Failed
                    else Flyology_Bench.Metric_Collected),
         Counter_Value => Long_Long_Integer (Failed_Call),
         Sample_Value => 0.0);
   end Partial_Probe;
   procedure Partial_Measure is new Flyology_Bench.Measure_Batched (Noop_Batch);

   procedure Raising_Probe
     (Snapshot : in out Flyology_Bench.Custom_Snapshot) is
      pragma Unreferenced (Snapshot);
   begin
      raise Program_Error with "synthetic probe failure";
   end Raising_Probe;

   procedure Composed_Probe
     (Snapshot : in out Flyology_Bench.Custom_Snapshot) is
   begin
      Snapshot := [others => (Status => Flyology_Bench.Metric_Not_Requested,
                              others => <>)];
      Snapshot (1) :=
        (Status => Flyology_Bench.Metric_Collected,
         Counter_Value => 0, Sample_Value => 11.0);
   end Composed_Probe;

   Signed_Value : Long_Float := 0.0;
   procedure Signed_Probe (Snapshot : in out Flyology_Bench.Custom_Snapshot) is
   begin
      Snapshot := [others => (Status => Flyology_Bench.Metric_Not_Requested,
                              others => <>)];
      Snapshot (1) := (Status => Flyology_Bench.Metric_Collected,
                       Sample_Value => Signed_Value, Counter_Value => 0);
   end Signed_Probe;
   procedure Zero_Batch (Iterations : Flyology_Bench.Iteration_Count) is
   begin
      Signed_Value := 0.0;
      for Index in 1 .. Iterations loop
         Dummy := Dummy + Long_Long_Integer (Index);
      end loop;
   end Zero_Batch;
   procedure Negative_Batch (Iterations : Flyology_Bench.Iteration_Count) is
   begin
      Signed_Value := -2.0;
      for Index in 1 .. Iterations loop
         Dummy := Dummy + Long_Long_Integer (Index);
      end loop;
   end Negative_Batch;
   procedure Signed_Compare is new Flyology_Bench.Compare_Batched
     (Zero_Batch, Negative_Batch);

   procedure Fake_Batch
     (Iterations : Flyology_Bench.Iteration_Count;
      Elapsed : out Long_Float;
      Status : out Flyology_Bench.Metric_Availability) is
   begin
      for Index in 1 .. Iterations loop
         Dummy := Dummy + Long_Long_Integer (Index);
      end loop;
      Elapsed := 7.0 * Long_Float (Iterations);
      Status := Flyology_Bench.Metric_Collected;
   end Fake_Batch;
   package Fake_Timer is new Flyology_Bench.Manual_Timing
     (Source_Name => "deterministic_fake_ticks", Unit => "quanta/op",
      Resolution => 2.0, Scale_To_Unit => 0.5,
      Scope => Flyology_Bench.Simulated_Clock,
      Attribution => Flyology_Bench.Unattributable,
      Batch => Fake_Batch);

   procedure Invalid_Elapsed_Batch
     (Iterations : Flyology_Bench.Iteration_Count;
      Elapsed : out Long_Float;
      Status : out Flyology_Bench.Metric_Availability) is
   begin
      for Index in 1 .. Iterations loop
         Dummy := Dummy + Long_Long_Integer (Index);
      end loop;
      Elapsed := -1.0;
      Status := Flyology_Bench.Metric_Collected;
   end Invalid_Elapsed_Batch;
   package Invalid_Timer is new Flyology_Bench.Manual_Timing
     (Source_Name => "invalid_fake_clock", Unit => "ticks/op",
      Resolution => 1.0, Scope => Flyology_Bench.Simulated_Clock,
      Attribution => Flyology_Bench.Unattributable,
      Batch => Invalid_Elapsed_Batch);

   procedure Fake_Reference
     (Iterations : Flyology_Bench.Iteration_Count;
      Elapsed : out Long_Float;
      Status : out Flyology_Bench.Metric_Availability) is
   begin
      for Index in 1 .. Iterations loop
         Dummy := Dummy + Long_Long_Integer (Index);
      end loop;
      Elapsed := 5.0 * Long_Float (Iterations);
      Status := Flyology_Bench.Metric_Collected;
   end Fake_Reference;
   procedure Fake_Contender
     (Iterations : Flyology_Bench.Iteration_Count;
      Elapsed : out Long_Float;
      Status : out Flyology_Bench.Metric_Availability) is
   begin
      for Index in 1 .. Iterations loop
         Dummy := Dummy + Long_Long_Integer (Index);
      end loop;
      Elapsed := 8.0 * Long_Float (Iterations);
      Status := Flyology_Bench.Metric_Collected;
   end Fake_Contender;
   package Fake_Comparison is new Flyology_Bench.Manual_Timing_Comparison
     (Source_Name => "deterministic_fake_ticks", Unit => "ticks/op",
      Resolution => 1.0, Scope => Flyology_Bench.Simulated_Clock,
      Attribution => Flyology_Bench.Unattributable,
      Reference_Batch => Fake_Reference,
      Contender_Batch => Fake_Contender);

   Ordered_Call : Natural := 0;
   Ordered_Value : Long_Float := 0.0;
   procedure Ordered_Probe
     (Snapshot : in out Flyology_Bench.Custom_Snapshot) is
   begin
      Snapshot := [others => (Status => Flyology_Bench.Metric_Not_Requested,
                              others => <>)];
      Snapshot (1) :=
        (Status => Flyology_Bench.Metric_Collected,
         Counter_Value => 0, Sample_Value => Ordered_Value);
   end Ordered_Probe;
   procedure Ordered_Batch (Iterations : Flyology_Bench.Iteration_Count) is
   begin
      Ordered_Call := Ordered_Call + 1;
      Ordered_Value := (if Ordered_Call mod 2 = 0 then 0.0 else 10.0);
      for Index in 1 .. Iterations loop
         Dummy := Dummy + Long_Long_Integer (Index);
      end loop;
   end Ordered_Batch;
   procedure Ordered_Measure is new Flyology_Bench.Measure_Batched
     (Ordered_Batch);

   Threshold_Value : Long_Float := 100.0;
   Threshold_Contender_Call : Natural := 0;
   procedure Threshold_Probe
     (Snapshot : in out Flyology_Bench.Custom_Snapshot) is
   begin
      Snapshot := [others => (Status => Flyology_Bench.Metric_Not_Requested,
                              others => <>)];
      Snapshot (1) :=
        (Status => Flyology_Bench.Metric_Collected,
         Counter_Value => 0, Sample_Value => Threshold_Value);
   end Threshold_Probe;
   procedure Threshold_Reference
     (Iterations : Flyology_Bench.Iteration_Count) is
   begin
      Threshold_Value := 100.0;
      for Index in 1 .. Iterations loop
         Dummy := Dummy + Long_Long_Integer (Index);
      end loop;
   end Threshold_Reference;
   procedure Threshold_Contender
     (Iterations : Flyology_Bench.Iteration_Count) is
   begin
      Threshold_Contender_Call := Threshold_Contender_Call + 1;
      Threshold_Value :=
        (if Threshold_Contender_Call mod 2 = 0 then 100.5 else 101.5);
      for Index in 1 .. Iterations loop
         Dummy := Dummy + Long_Long_Integer (Index);
      end loop;
   end Threshold_Contender;
   procedure Threshold_Compare is new Flyology_Bench.Compare_Batched
     (Threshold_Reference, Threshold_Contender);

   Failure_Status : Flyology_Bench.Metric_Availability :=
     Flyology_Bench.Probe_Failed;
   procedure Failure_Probe
     (Snapshot : in out Flyology_Bench.Custom_Snapshot) is
   begin
      Snapshot := [others => (Status => Flyology_Bench.Metric_Not_Requested,
                              others => <>)];
      Snapshot (1) :=
        (Status => Failure_Status, Counter_Value => 0, Sample_Value => 0.0);
   end Failure_Probe;
   procedure Failure_Reference
     (Iterations : Flyology_Bench.Iteration_Count) is
   begin
      Failure_Status := Flyology_Bench.Counter_Reset;
      for Index in 1 .. Iterations loop
         Dummy := Dummy + Long_Long_Integer (Index);
      end loop;
   end Failure_Reference;
   procedure Failure_Contender
     (Iterations : Flyology_Bench.Iteration_Count) is
   begin
      Failure_Status := Flyology_Bench.Probe_Failed;
      for Index in 1 .. Iterations loop
         Dummy := Dummy + Long_Long_Integer (Index);
      end loop;
   end Failure_Contender;
   procedure Failure_Compare is new Flyology_Bench.Compare_Batched
     (Failure_Reference, Failure_Contender);

   function Base return Flyology_Bench.Configuration is
      Result : Flyology_Bench.Configuration := Flyology_Bench.Default_Configuration;
   begin
      Result.Warmup_Time := 0.0;
      Result.Measurement_Time := 0.001;
      Result.Minimum_Sample_Time := 0.000_001;
      Result.Maximum_Iterations := 1_000;
      Result.Samples := 10;
      Result.Comparison_Batching := Flyology_Bench.Shared_Iterations;
      return Result;
   end Base;

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   Config : Flyology_Bench.Configuration;
   Measured : Flyology_Bench.Measurement;
   Failed_Measured : Flyology_Bench.Measurement;
   Compared : Flyology_Bench.Comparison;
   Failed_Compared : Flyology_Bench.Comparison;
   Multi : Flyology_Bench.Multi_Comparison;
   Item : Flyology_Bench.Metric_Comparison_Result;
begin
   Check
     (Flyology_Bench.Metric_Availability'Pos
        (Flyology_Bench.Metric_Partially_Collected) = 7,
      "custom statuses changed an established availability ordinal");
   Check
     (Flyology_Bench.Metric_Scope'Pos (Flyology_Bench.Flyology_Runtime) = 4,
      "custom scopes changed an established scope ordinal");

   Config := Base;
   Flyology_Bench.Register_Custom_Metric
     (Config.Custom_Metrics, "domain_events", "events/op",
      Flyology_Bench.Caller_Defined_Window,
      Flyology_Bench.Shared_Process_Window,
      Flyology_Bench.Lower_Is_Better);
   Flyology_Bench.Set_Custom_Probe
     (Config.Custom_Metrics, Counter_Probe'Unrestricted_Access);
   Domain_Measure (Config, Measured);
   Check (Probe_Calls = 2 * Natural (Flyology_Bench.Samples (Measured)),
          "custom probe did not run exactly twice per retained batch");
   for Index in 1 .. Flyology_Bench.Samples (Measured) loop
      Check (Flyology_Bench.Custom_Metric_Sample (Measured, 1, Index) = 3.0,
             "cumulative delta or iteration normalization is wrong");
   end loop;
   Check (Flyology_Bench.Custom_Metric_Attribution (Measured, 1)
            = Flyology_Bench.Shared_Process_Window,
          "caller attribution was changed");

   Counter := 0;
   Probe_Calls := 0;
   Domain_Compare (Config, Compared);
   Item := Flyology_Bench.Compare_Custom_Metric (Compared, 1);
   Check (Item.Available and then Item.Method = Flyology_Bench.Relative_Ratio,
          "positive custom counter did not use paired relative comparison");
   Check (Item.Change > 99.9 and then Item.Change < 100.1,
          "paired custom metric lost reference/contender schedule");
   Check (Item.Verdict = Flyology_Bench.Reference_Better,
          "lower-is-better custom direction was not applied");
   Flyology_Bench.Reporters.Put_Comparison_Console
     ("reference", "contender", Compared,
      Style => Flyology_Bench.Reporters.Plain);

   Counter := 0;
   Domain_Multi (Config, Multi);
   Item := Flyology_Bench.Compare_Custom_Metric
     (Flyology_Bench.Versus_Reference (Multi, 3), 1);
   Check (Item.Available and then Item.Change > 199.9,
          "multi-way custom metric lost common rounds");

   Config := Base;
   Flyology_Bench.Register_Custom_Metric
     (Config.Custom_Metrics, "reset_counter", "events/op",
      Flyology_Bench.Caller_Defined_Window,
      Flyology_Bench.Unattributable, Flyology_Bench.Diagnostic);
   Flyology_Bench.Set_Custom_Probe
     (Config.Custom_Metrics, Reset_Probe'Unrestricted_Access);
   Reset_Measure (Config, Measured);
   Check (Flyology_Bench.Custom_Metric_Status (Measured, 1)
            = Flyology_Bench.Counter_Reset,
          "counter reset became a numeric zero");

   Config := Base;
   Flyology_Bench.Register_Custom_Metric
     (Config.Custom_Metrics, "overflow_counter", "events/op",
      Flyology_Bench.Caller_Defined_Window,
      Flyology_Bench.Unattributable, Flyology_Bench.Diagnostic);
   Flyology_Bench.Set_Custom_Probe
     (Config.Custom_Metrics, Overflow_Probe'Unrestricted_Access);
   Reset_Measure (Config, Measured);
   Check (Flyology_Bench.Custom_Metric_Status (Measured, 1)
            = Flyology_Bench.Conversion_Overflow,
          "cumulative overflow became a numeric value");

   Config := Base;
   Flyology_Bench.Register_Custom_Metric
     (Config.Custom_Metrics, "partial_counter", "events/op",
      Flyology_Bench.Caller_Defined_Window,
      Flyology_Bench.Unattributable, Flyology_Bench.Diagnostic);
   Flyology_Bench.Set_Custom_Probe
     (Config.Custom_Metrics, Partial_Probe'Unrestricted_Access);
   Partial_Measure (Config, Measured);
   Check (Flyology_Bench.Custom_Metric_Status (Measured, 1)
            = Flyology_Bench.Metric_Partially_Collected,
          "partial availability was collapsed");
   Check (Flyology_Bench.Custom_Metric_Statistics (Measured, 1).Samples = 9,
          "failed sample was substituted with zero");
   Check (Flyology_Bench.Custom_Metric_Sample_Status (Measured, 1, 1)
            = Flyology_Bench.Probe_Failed,
          "per-sample probe failure status was not retained");

   Config := Base;
   Flyology_Bench.Register_Custom_Metric
     (Config.Custom_Metrics, "raising_probe", "events/op",
      Flyology_Bench.Caller_Defined_Window,
      Flyology_Bench.Unattributable, Flyology_Bench.Diagnostic);
   Flyology_Bench.Set_Custom_Probe
     (Config.Custom_Metrics, Raising_Probe'Unrestricted_Access);
   Partial_Measure (Config, Measured);
   Check (Flyology_Bench.Custom_Metric_Status (Measured, 1)
            = Flyology_Bench.Probe_Failed,
          "callback exception escaped or became zero");
   Failed_Measured := Measured;

   Config := Base;
   Flyology_Bench.Register_Custom_Metric
     (Config.Custom_Metrics, "signed_balance", "credits/batch",
      Flyology_Bench.Caller_Defined_Window,
      Flyology_Bench.Unattributable, Flyology_Bench.Diagnostic,
      Semantics => Flyology_Bench.Absolute_Sample,
      Normalization => Flyology_Bench.Per_Batch,
      Comparison => Flyology_Bench.Absolute);
   Flyology_Bench.Set_Custom_Probe
     (Config.Custom_Metrics, Signed_Probe'Unrestricted_Access);
   Signed_Compare (Config, Compared);
   Item := Flyology_Bench.Compare_Custom_Metric (Compared, 1);
   Check (Item.Available
            and then Item.Method = Flyology_Bench.Absolute_Difference
            and then Item.Change = -2.0
            and then Item.Verdict = Flyology_Bench.Metric_Diagnostic,
          "signed or zero custom samples did not use absolute comparison");

   Config := Base;
   Config.Samples := 16;
   Flyology_Bench.Register_Custom_Metric
     (Config.Custom_Metrics, "ordered_sample", "units/batch",
      Flyology_Bench.Caller_Defined_Window,
      Flyology_Bench.Unattributable, Flyology_Bench.Diagnostic,
      Semantics => Flyology_Bench.Absolute_Sample,
      Normalization => Flyology_Bench.Per_Batch,
      Comparison => Flyology_Bench.Absolute);
   Flyology_Bench.Set_Custom_Probe
     (Config.Custom_Metrics, Ordered_Probe'Unrestricted_Access);
   Ordered_Measure (Config, Measured);
   Check
     (Flyology_Bench.Custom_Metric_Statistics
        (Measured, 1).Confidence_Low = 5.0
      and then Flyology_Bench.Custom_Metric_Statistics
        (Measured, 1).Confidence_High = 5.0,
      "custom block bootstrap did not retain chronological sample order");

   Config := Base;
   Config.Samples := 25;
   Config.Practical_Threshold_Percent := 1.0;
   Flyology_Bench.Register_Custom_Metric
     (Config.Custom_Metrics, "threshold_metric", "units/batch",
      Flyology_Bench.Caller_Defined_Window,
      Flyology_Bench.Unattributable, Flyology_Bench.Lower_Is_Better,
      Semantics => Flyology_Bench.Absolute_Sample,
      Normalization => Flyology_Bench.Per_Batch);
   Flyology_Bench.Set_Custom_Probe
     (Config.Custom_Metrics, Threshold_Probe'Unrestricted_Access);
   Threshold_Compare (Config, Compared);
   Item := Flyology_Bench.Compare_Custom_Metric (Compared, 1);
   Check
     (Item.Available
      and then Item.Confidence_Low > 0.0
      and then Item.Confidence_Low < 1.0
      and then Item.Confidence_High > 1.0
      and then Item.Verdict = Flyology_Bench.Metric_Inconclusive,
      "custom relative verdict did not require clearing the practical threshold");

   Fake_Timer.Measure (Base, Measured);
   Check (Flyology_Bench.Custom_Metric_Sample (Measured, 1, 1) = 3.5,
          "manual timer conversion or normalization is wrong");
   Check
     (Flyology_Bench.Custom_Metric_Resolution (Measured, 1)
        = 1.0
          / Long_Float (Flyology_Bench.Iterations_Per_Sample (Measured)),
          "manual timer resolution was not normalized");
   Check (Flyology_Bench.Primary_Timing_Axis (Measured) = 1,
          "primary timing axis was not discoverable");
   Check (Flyology_Bench.Custom_Metric_Timing_Source (Measured, 1)
            = "deterministic_fake_ticks",
          "manual timing source identity was lost");
   Check (Flyology_Bench.Metric_Available (Measured, Flyology_Bench.Wall_Time),
          "harness wall time disappeared under alternate timing");
   Flyology_Bench.Reporters.Put_Console
     ("manual timer", Measured, Style => Flyology_Bench.Reporters.Plain,
      Include_Telemetry => False);

   declare
      package Timer_Values is new Ada.Task_Attributes (Long_Float, 0.0);
      procedure Concurrent_Batch
        (Iterations : Flyology_Bench.Iteration_Count;
         Elapsed : out Long_Float;
         Status : out Flyology_Bench.Metric_Availability) is
      begin
         Elapsed := Timer_Values.Value * Long_Float (Iterations);
         Status := Flyology_Bench.Metric_Collected;
      end Concurrent_Batch;
      package Concurrent_Timer is new Flyology_Bench.Manual_Timing
        (Source_Name => "task_local_fake_ticks", Unit => "ticks/op",
         Resolution => 1.0, Scope => Flyology_Bench.Simulated_Clock,
         Attribution => Flyology_Bench.Unattributable,
         Batch => Concurrent_Batch);
      type Outcome_Array is array (Positive range 1 .. 2) of Boolean;
      protected Outcomes is
         procedure Report (Id : Positive; Passed : Boolean);
         entry Wait (Passed : out Boolean);
      private
         Values : Outcome_Array := [others => False];
         Completed : Natural := 0;
      end Outcomes;
      protected body Outcomes is
         procedure Report (Id : Positive; Passed : Boolean) is
         begin
            Values (Id) := Passed;
            Completed := Completed + 1;
         end Report;
         entry Wait (Passed : out Boolean) when Completed = 2 is
         begin
            Passed := Values (1) and then Values (2);
         end Wait;
      end Outcomes;
      task type Runner (Id : Positive);
      task body Runner is
         Local_Config : Flyology_Bench.Configuration := Base;
         Local_Result : Flyology_Bench.Measurement;
         Passed : Boolean := True;
      begin
         Local_Config.Samples := 50;
         Timer_Values.Set_Value (Long_Float (Id));
         Concurrent_Timer.Measure (Local_Config, Local_Result);
         for Index in 1 .. Flyology_Bench.Samples (Local_Result) loop
            if Flyology_Bench.Custom_Metric_Sample
                 (Local_Result, 1, Index) /= Long_Float (Id)
            then
               Passed := False;
            end if;
         end loop;
         Outcomes.Report (Id, Passed);
      exception
         when others => Outcomes.Report (Id, False);
      end Runner;
      First_Runner : Runner (1);
      Second_Runner : Runner (2);
      All_Passed : Boolean;
   begin
      Outcomes.Wait (All_Passed);
      Check (All_Passed,
             "one manual timing instance shared mutable state across invocations");
   end;

   Invalid_Timer.Measure (Base, Measured);
   Check (Flyology_Bench.Custom_Metric_Status (Measured, 1)
            = Flyology_Bench.Invalid_Value,
          "negative manual elapsed value was accepted");

   Config := Base;
   Flyology_Bench.Register_Custom_Metric
     (Config.Custom_Metrics, "missing_provider", "units/batch",
      Flyology_Bench.Caller_Defined_Window,
      Flyology_Bench.Unattributable, Flyology_Bench.Diagnostic,
      Semantics => Flyology_Bench.Absolute_Sample,
      Normalization => Flyology_Bench.Per_Batch,
      Comparison => Flyology_Bench.Absolute);
   Fake_Timer.Measure (Config, Measured);
   Check
     (Flyology_Bench.Custom_Metric_Status (Measured, 1)
        = Flyology_Bench.Probe_Failed
      and then Flyology_Bench.Custom_Metric_Status (Measured, 2)
        = Flyology_Bench.Metric_Collected,
      "manual timing relabeled a missing custom provider");
   Config.Comparison_Batching := Flyology_Bench.Equal_Time;
   Fake_Comparison.Compare (Config, Compared);
   Item := Flyology_Bench.Compare_Custom_Metric (Compared, 1);
   Check
     (not Item.Available
      and then Flyology_Bench.Custom_Metric_Status
        (Flyology_Bench.Reference_Measurement (Compared), 1)
          = Flyology_Bench.Probe_Failed
      and then Flyology_Bench.Custom_Metric_Status
        (Flyology_Bench.Contender_Measurement (Compared), 1)
          = Flyology_Bench.Probe_Failed,
      "paired manual timing relabeled a missing custom provider");

   Config := Base;
   Flyology_Bench.Register_Custom_Metric
     (Config.Custom_Metrics, "long_custom_metric_identity_over_32",
      "custom-units-per-batch", Flyology_Bench.Caller_Defined_Window,
      Flyology_Bench.Unattributable, Flyology_Bench.Diagnostic,
      Semantics => Flyology_Bench.Absolute_Sample,
      Normalization => Flyology_Bench.Per_Batch,
      Comparison => Flyology_Bench.Absolute);
   Flyology_Bench.Set_Custom_Probe
     (Config.Custom_Metrics, Composed_Probe'Unrestricted_Access);
   Fake_Timer.Measure (Config, Measured);
   Check
     (Flyology_Bench.Custom_Metric_Total (Measured) = 2
      and then Flyology_Bench.Primary_Timing_Axis (Measured) = 2
      and then Flyology_Bench.Custom_Metric_Sample (Measured, 1, 1) = 11.0
      and then Flyology_Bench.Custom_Metric_Sample (Measured, 2, 1) = 3.5,
      "manual timing did not compose with an existing custom provider");

   Config.Comparison_Batching := Flyology_Bench.Equal_Time;
   Fake_Comparison.Compare (Config, Compared);
   Check
     (Flyology_Bench.Primary_Timing_Axis
        (Flyology_Bench.Reference_Measurement (Compared)) = 2,
      "paired primary timing axis was not discoverable");
   Check
     (Flyology_Bench.Custom_Metric_Resolution
        (Flyology_Bench.Reference_Measurement (Compared), 2)
      = 1.0 / Long_Float
          (Flyology_Bench.Iterations_Per_Sample
             (Flyology_Bench.Reference_Measurement (Compared)))
      and then Flyology_Bench.Custom_Metric_Resolution
        (Flyology_Bench.Contender_Measurement (Compared), 2)
      = 1.0 / Long_Float
          (Flyology_Bench.Iterations_Per_Sample
             (Flyology_Bench.Contender_Measurement (Compared))),
      "paired manual timer resolutions do not match their denominators");
   Item := Flyology_Bench.Compare_Custom_Metric (Compared, 2);
   Check (Item.Available and then Item.Change > 59.9 and then Item.Change < 60.1,
          "manual timing paired comparison is not iteration-normalized");
   Check (Item.Verdict = Flyology_Bench.Reference_Better,
          "manual timing direction was not retained");
   Flyology_Bench.Reporters.Put_Comparison_Console
     ("old timer", "new timer", Compared,
      Style => Flyology_Bench.Reporters.Plain);

   Config := Base;
   Flyology_Bench.Register_Custom_Metric
     (Config.Custom_Metrics, "failed_pair", "units/batch",
      Flyology_Bench.Caller_Defined_Window,
      Flyology_Bench.Unattributable, Flyology_Bench.Diagnostic,
      Semantics => Flyology_Bench.Absolute_Sample,
      Normalization => Flyology_Bench.Per_Batch,
      Comparison => Flyology_Bench.Absolute);
   Flyology_Bench.Set_Custom_Probe
     (Config.Custom_Metrics, Failure_Probe'Unrestricted_Access);
   Failure_Compare (Config, Failed_Compared);
   Flyology_Bench.Reporters.Put_Comparison_Console
     ("failed old", "failed new", Failed_Compared,
      Style => Flyology_Bench.Reporters.Plain);

   --  These rows are checked structurally by scripts/test.sh.
   Ada.Text_IO.Put_Line ("-- custom machine output begin --");
   Flyology_Bench.Reporters.Put_Extended_Metrics_CSV_Header;
   Flyology_Bench.Reporters.Put_Extended_Metrics_CSV ("fake, timer", Measured);
   Flyology_Bench.Reporters.Put_Metrics_NDJSON ("fake ""timer", Measured);
   Flyology_Bench.Reporters.Put_Extended_Metrics_CSV
     ("failed_custom", Failed_Measured);
   Flyology_Bench.Reporters.Put_Metrics_NDJSON
     ("failed_custom", Failed_Measured);
   Flyology_Bench.Reporters.Put_Extended_Comparison_Metrics_CSV_Header;
   Flyology_Bench.Reporters.Put_Extended_Comparison_Metrics_CSV
     ("old", "new", Compared);
   Flyology_Bench.Reporters.Put_Comparison_Metrics_NDJSON
     ("old", "new", Compared);
   Flyology_Bench.Reporters.Put_Extended_Comparison_Metrics_CSV
     ("failed old", "failed new", Failed_Compared);
   Flyology_Bench.Reporters.Put_Comparison_Metrics_NDJSON
     ("failed old", "failed new", Failed_Compared);
   Ada.Text_IO.Put_Line ("-- custom machine output end --");

   declare
      Registry : Flyology_Bench.Custom_Metric_Registry;
   begin
      Flyology_Bench.Register_Custom_Metric
        (Registry, "domain_events", "events/op",
         Flyology_Bench.Caller_Defined_Window, Flyology_Bench.Unattributable,
         Flyology_Bench.Diagnostic);
      begin
         Flyology_Bench.Register_Custom_Metric
           (Registry, "domain_events", "other/op",
            Flyology_Bench.Caller_Defined_Window, Flyology_Bench.Unattributable,
            Flyology_Bench.Diagnostic);
         raise Program_Error with "duplicate custom name was accepted";
      exception
         when Constraint_Error => null;
      end;
      begin
         Flyology_Bench.Register_Custom_Metric
           (Registry, "bad_unit", "items,op",
            Flyology_Bench.Caller_Defined_Window, Flyology_Bench.Unattributable,
            Flyology_Bench.Diagnostic);
         raise Program_Error with "invalid custom unit was accepted";
      exception
         when Constraint_Error => null;
      end;
      begin
         Flyology_Bench.Register_Custom_Metric
           (Registry, "bad_timer", "ticks/op",
            Flyology_Bench.Simulated_Clock, Flyology_Bench.Unattributable,
            Flyology_Bench.Lower_Is_Better,
            Semantics => Flyology_Bench.Completed_Elapsed,
            Primary_Timing => True, Timing_Source => "fake",
            Resolution => 0.0);
         raise Program_Error with "zero timing resolution was accepted";
      exception
         when Constraint_Error => null;
      end;
      begin
         Flyology_Bench.Register_Custom_Metric
           (Registry, "wall_time", "ticks/op",
            Flyology_Bench.Caller_Defined_Window, Flyology_Bench.Unattributable,
            Flyology_Bench.Diagnostic);
         raise Program_Error with "built-in name collision was accepted";
      exception
         when Constraint_Error => null;
      end;
      begin
         Flyology_Bench.Register_Custom_Metric
           (Registry, "Bad Name", "ticks/op",
            Flyology_Bench.Caller_Defined_Window, Flyology_Bench.Unattributable,
            Flyology_Bench.Diagnostic);
         raise Program_Error with "invalid custom name was accepted";
      exception
         when Constraint_Error => null;
      end;
      for Offset in 1 .. Flyology_Bench.Max_Custom_Metrics - 1 loop
         Flyology_Bench.Register_Custom_Metric
           (Registry,
            "axis_" & Character'Val (Character'Pos ('a') + Offset - 1),
            "items/op", Flyology_Bench.Caller_Defined_Window,
            Flyology_Bench.Unattributable, Flyology_Bench.Diagnostic);
      end loop;
      begin
         Flyology_Bench.Register_Custom_Metric
           (Registry, "one_too_many", "items/op",
            Flyology_Bench.Caller_Defined_Window, Flyology_Bench.Unattributable,
            Flyology_Bench.Diagnostic);
         raise Program_Error with "custom metric bound was not enforced";
      exception
         when Flyology_Bench.Capacity_Error => null;
      end;
   end;
end Custom_Metrics_Smoke;
