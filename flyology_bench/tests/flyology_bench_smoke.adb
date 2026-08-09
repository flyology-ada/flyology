--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Text_IO;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Real_Time;
with Ada.Strings.Fixed;
with Flyology_Bench;
with Flyology_Bench.Baselines;
with Flyology_Bench.Metadata;
with Flyology_Bench.Reporters;
with Interfaces;

procedure Flyology_Bench_Smoke is
   use type Flyology_Bench.Iteration_Count;
   use type Flyology_Bench.Progress_Phase;
   use type Flyology_Bench.Shootout_Schedule_Policy;
   use type Flyology_Bench.Comparison_Batch_Policy;
   use type Flyology_Bench.Metric_Set;
   use type Flyology_Bench.Metric_Availability;
   use type Flyology_Bench.Metric_Scope;

   Counter : Natural := 0 with Volatile;

   procedure Scheduler_Probe
     (Snapshot : out Flyology_Bench.Flyology_Scheduler_Snapshot) is
   begin
      Snapshot :=
        (Available  => True,
         Dispatches => Interfaces.Unsigned_64 (Counter),
         others     => 0);
   end Scheduler_Probe;

   procedure Operation is
   begin
      Counter := Counter + 1;
   end Operation;

   procedure Operation_Benchmark is new Flyology_Bench.Measure (Operation);

   procedure Contender_Operation is
   begin
      Counter := Counter + 1;
      Counter := Counter + 1;
   end Contender_Operation;

   procedure Operation_Comparison is new Flyology_Bench.Compare
     (Reference_Operation => Operation,
      Contender_Operation => Contender_Operation);

   Batched_Calls : Flyology_Bench.Iteration_Count := 0 with Volatile;

   procedure Batch (Iterations : Flyology_Bench.Iteration_Count) is
   begin
      Batched_Calls := Batched_Calls + Iterations;
      for Iteration in Flyology_Bench.Iteration_Count range 1 .. Iterations loop
         Counter := Counter + 1;
      end loop;
   end Batch;

   procedure Batched_Benchmark is new Flyology_Bench.Measure_Batched (Batch);

   procedure Batched_Comparison is new Flyology_Bench.Compare_Batched
     (Reference_Batch => Batch,
      Contender_Batch => Batch);

   Setup_Count : Natural := 0;
   Teardown_Count : Natural := 0;

   procedure Setup is
   begin
      Setup_Count := Setup_Count + 1;
   end Setup;

   procedure Teardown is
   begin
      Teardown_Count := Teardown_Count + 1;
   end Teardown;

   procedure Hooked_Benchmark is new Flyology_Bench.Measure_With_Hooks
     (Setup => Setup, Operation => Operation, Teardown => Teardown);

   procedure Result_Batch
     (Iterations : Flyology_Bench.Iteration_Count;
      Value      : out Natural) is
   begin
      Value := 0;
      for Iteration in Flyology_Bench.Iteration_Count range 1 .. Iterations loop
         Value := Value + 1;
      end loop;
   end Result_Batch;

   procedure Result_Benchmark is new Flyology_Bench.Measure_Result_Batched
     (Element => Natural, Batch => Result_Batch);

   procedure Slow_Batch
     (Iterations : Flyology_Bench.Iteration_Count) is
      pragma Unreferenced (Iterations);
   begin
      delay 0.002;
   end Slow_Batch;

   procedure Budgeted_Benchmark is new
     Flyology_Bench.Measure_Batched (Slow_Batch);

   --  Inherited-counter attribution fixture. The serial batch performs one
   --  mix per logical operation on the calling task; the worker batch starts
   --  four Ada tasks after the counters exist and each performs the same
   --  count, so a counter that reaches the whole native task tree reports
   --  about four times as much work per logical operation.
   Worker_Slots : constant := 4;
   subtype Attribution_Slot is Positive range 1 .. Worker_Slots;
   type Attribution_Results is
     array (Attribution_Slot) of Interfaces.Unsigned_64
     with Volatile_Components;
   Attribution_Values : Attribution_Results := (others => 1);

   procedure Mix_Slot
     (Slot       : Attribution_Slot;
      Iterations : Flyology_Bench.Iteration_Count)
   is
      use type Interfaces.Unsigned_64;

      Value : Interfaces.Unsigned_64 := Attribution_Values (Slot);
   begin
      for Iteration in Flyology_Bench.Iteration_Count range 1 .. Iterations loop
         Value := Value * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407;
      end loop;
      Attribution_Values (Slot) := Value;
   end Mix_Slot;

   procedure Serial_Attribution_Batch
     (Iterations : Flyology_Bench.Iteration_Count) is
   begin
      Mix_Slot (1, Iterations);
   end Serial_Attribution_Batch;

   procedure Worker_Attribution_Batch
     (Iterations : Flyology_Bench.Iteration_Count)
   is
      task type Worker
        (Count : Flyology_Bench.Iteration_Count;
         Slot  : Attribution_Slot);

      task body Worker is
      begin
         Mix_Slot (Slot, Count);
      end Worker;

      Worker_1 : Worker (Iterations, 1);
      Worker_2 : Worker (Iterations, 2);
      Worker_3 : Worker (Iterations, 3);
      Worker_4 : Worker (Iterations, 4);
   begin
      null;
   end Worker_Attribution_Batch;

   procedure Serial_Attribution is new
     Flyology_Bench.Measure_Batched (Serial_Attribution_Batch);
   procedure Worker_Attribution is new
     Flyology_Bench.Measure_Batched (Worker_Attribution_Batch);

   type Smoke_Case is (Reference_Case, Same_Case, Double_Case);

   procedure Multi_Batch
     (Which      : Smoke_Case;
      Iterations : Flyology_Bench.Iteration_Count) is
   begin
      for Iteration in Flyology_Bench.Iteration_Count range 1 .. Iterations loop
         case Which is
            when Reference_Case | Same_Case => Operation;
            when Double_Case => Contender_Operation;
         end case;
      end loop;
   end Multi_Batch;

   procedure Multi_Benchmark is new Flyology_Bench.Compare_Many
     (Case_Id => Smoke_Case, Batch => Multi_Batch);
   procedure Put_Multi_Console is new
     Flyology_Bench.Reporters.Put_Multi_Comparison_Console (Smoke_Case);
   procedure Put_Multi_CSV is new
     Flyology_Bench.Reporters.Put_Multi_Comparison_CSV (Smoke_Case);
   procedure Put_Multi_Metrics_CSV is new
     Flyology_Bench.Reporters.Put_Multi_Comparison_Metrics_CSV (Smoke_Case);
   procedure Put_Multi_JSON is new
     Flyology_Bench.Reporters.Put_Multi_Comparison_JSON (Smoke_Case);

   --  Markers delimiting the machine-readable reporter output on stdout.
   Machine_Output_Begin : constant String := "-- machine output begin --";
   Machine_Output_End : constant String := "-- machine output end --";

   Saw_Reference_Progress : Boolean := False;
   Saw_Same_Progress : Boolean := False;
   Saw_Double_Progress : Boolean := False;
   Saw_Quiescence_Progress : Boolean := False;

   procedure Observe_Quiescence_Progress
     (Name      : String;
      Phase     : Flyology_Bench.Progress_Phase;
      Completed : Natural;
      Total     : Natural)
   is
      pragma Unreferenced (Name, Completed, Total);
   begin
      Saw_Quiescence_Progress :=
        Saw_Quiescence_Progress
        or else Phase = Flyology_Bench.Waiting_For_CPU_Quiescence;
   end Observe_Quiescence_Progress;

   procedure Observe_Multi_Progress
     (Name      : String;
      Phase     : Flyology_Bench.Progress_Phase;
      Completed : Natural;
      Total     : Natural)
   is
      pragma Unreferenced (Completed, Total);
   begin
      if Phase = Flyology_Bench.Sampling then
         Saw_Reference_Progress :=
           Saw_Reference_Progress
           or else Ada.Strings.Fixed.Index (Name, "reference case") > 0;
         Saw_Same_Progress :=
           Saw_Same_Progress
           or else Ada.Strings.Fixed.Index (Name, "same case") > 0;
         Saw_Double_Progress :=
           Saw_Double_Progress
           or else Ada.Strings.Fixed.Index (Name, "double case") > 0;
      end if;
   end Observe_Multi_Progress;

   Config : constant Flyology_Bench.Configuration :=
     (Warmup_Time         => 0.005,
      Measurement_Time    => 0.020,
      Maximum_Sampling_Time => 0.0,
      Samples             => 10,
      Minimum_Sample_Time => 0.000_010,
      Maximum_Iterations  => 10_000_000,
      Comparison_Batching => Flyology_Bench.Equal_Time,
      Shootout_Scheduling => Flyology_Bench.Balanced_Rounds,
      Subtract_Timer_Cost => False,
      Practical_Threshold_Percent => 1.0,
      Random_Seed         => 42,
      Metrics             =>
        Flyology_Bench.Process_Resource_Metrics or
          Flyology_Bench.Linux_Hardware_Metrics or
          Flyology_Bench.Flyology_Scheduler_Metrics,
      Scheduler_Probe     => Scheduler_Probe'Unrestricted_Access,
      CPU_Quiescence      => (others => <>),
      Collect_Process_Telemetry => False,
      Progress            => null,
      Progress_Name       => <>);
   First  : Flyology_Bench.Measurement;
   Second : Flyology_Bench.Measurement;
   Compared : Flyology_Bench.Comparison;
   Shared_Compared : Flyology_Bench.Comparison;
   Batched_Compared : Flyology_Bench.Comparison;
   Hooked : Flyology_Bench.Measurement;
   Result_Produced : Flyology_Bench.Measurement;
   Budgeted : Flyology_Bench.Measurement;
   Multi_Compared : Flyology_Bench.Multi_Comparison;
   Sequential_Compared : Flyology_Bench.Multi_Comparison;
   Baseline_Path : constant String := ".flyology_bench_test_baseline.tmp";

   --  Hosted runners commonly expose no PMU, so hardware-counter collection
   --  is only required when the runner opts in. The attribution check itself
   --  runs whenever the counters are actually collected.
   Require_Hardware : constant Boolean :=
     Ada.Environment_Variables.Value
       ("FLYOLOGY_BENCH_REQUIRE_PERF", Default => "0") = "1";

   --  Batches long enough that starting four tasks is a small share of the
   --  sample, so the ratio reflects the workers' own computation rather than
   --  their creation cost.
   Attribution_Config : constant Flyology_Bench.Configuration :=
     (Config with delta
        Warmup_Time => 0.010,
        Measurement_Time => 0.100,
        Minimum_Sample_Time => 0.010,
        Metrics => Flyology_Bench.Time_Metrics
          or Flyology_Bench.Linux_Hardware_Metrics,
        Scheduler_Probe => null);

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;
begin
   Operation_Benchmark
     ((Config with delta
        CPU_Quiescence =>
          (Enabled                     => True,
           Maximum_Average_CPU_Percent => 100.0,
           Maximum_Core_CPU_Percent    => 100.0,
           Stable_Time                 => 0.020,
           Poll_Interval               => 0.010,
           Timeout                     => 0.200),
        Progress => Observe_Quiescence_Progress'Unrestricted_Access),
      First);
   Check
     (Saw_Quiescence_Progress,
      "CPU quiescence did not report its preflight phase");

   declare
      use type Ada.Real_Time.Time;

      Timed_Out : Boolean := False;
      Discarded : Flyology_Bench.Measurement;

      task CPU_Burner;

      task body CPU_Burner is
         Deadline : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.Milliseconds (300);
         Spin : Natural := 0 with Volatile;
      begin
         while Ada.Real_Time.Clock < Deadline loop
            if Spin = Natural'Last then
               Spin := 0;
            else
               Spin := Spin + 1;
            end if;
         end loop;
      end CPU_Burner;
   begin
      begin
         Operation_Benchmark
           ((Config with delta
              CPU_Quiescence =>
                (Enabled                     => True,
                 Maximum_Average_CPU_Percent => 0.0,
                 Maximum_Core_CPU_Percent    => 0.0,
                 Stable_Time                 => 0.100,
                 Poll_Interval               => 0.020,
                 Timeout                     => 0.100)),
            Discarded);
      exception
         when Flyology_Bench.CPU_Quiescence_Timeout =>
            Timed_Out := True;
      end;
      Check
        (Timed_Out,
         "CPU quiescence did not time out while a local task was busy");
   end;

   Check (Counter > 0, "ordinary benchmark did not run the operation");
   Check
     (Flyology_Bench.Samples (First) = Config.Samples,
      "ordinary benchmark returned the wrong sample count");
   Check
     (Flyology_Bench.Iterations_Per_Sample (First) > 1,
      "ordinary benchmark did not calibrate a nanosecond operation");
   Check
     (Flyology_Bench.Minimum_Nanoseconds (First) >= 0.0,
      "ordinary benchmark returned a negative duration");
   Check
     (Flyology_Bench.Clock_Resolution_Nanoseconds (First) > 0.0
      and then Flyology_Bench.Observed_Clock_Resolution_Nanoseconds (First)
        > 0.0,
      "native benchmark clock was not characterized");
   Check
     (Flyology_Bench.Median_Batch_Nanoseconds (First)
        >= Flyology_Bench.Clock_Resolution_Nanoseconds (First),
      "calibrated sample is shorter than the clock resolution");
   Check
     (Flyology_Bench.Mean_Confidence_Low_Nanoseconds (First)
        <= Flyology_Bench.Mean_Nanoseconds (First)
      and then Flyology_Bench.Mean_Nanoseconds (First)
        <= Flyology_Bench.Mean_Confidence_High_Nanoseconds (First),
      "mean lies outside its bootstrap interval");
   Check
     (Flyology_Bench.Metric_Available
        (First, Flyology_Bench.Process_CPU_Time)
      and then Flyology_Bench.Metric_Available
        (First, Flyology_Bench.Thread_CPU_Time)
      and then Flyology_Bench.Metric_Available
        (First, Flyology_Bench.Process_RSS),
      "portable resource axes were not collected");
   Check
     (Flyology_Bench.Metric_Sample
        (First, Flyology_Bench.Wall_Time, 1)
      = Flyology_Bench.Sample_Nanoseconds (First, 1),
      "wall-time axis diverges from the retained latency sample");
   Check
     (Flyology_Bench.Metric_Statistics
        (First, Flyology_Bench.Process_RSS).Median > 0.0,
      "resident-memory samples are empty");
   Check
     (Flyology_Bench.Metric_Available
        (First, Flyology_Bench.Flyology_Dispatches),
      "scheduler probe samples were not collected");
   Check
     (Flyology_Bench.Metric_Requested (First, Flyology_Bench.CPU_Cycles),
      "Linux hardware axes were not retained as requested");
   Check
     (not Flyology_Bench.Metric_Available
        (First, Flyology_Bench.CPU_Cycles)
      or else Flyology_Bench.Metric_Statistics
        (First, Flyology_Bench.CPU_Cycles).Median > 0.0,
      "available Linux CPU-cycle samples are empty");
   for Axis in Flyology_Bench.CPU_Cycles .. Flyology_Bench.Branch_Misses loop
      Check
        (Flyology_Bench.Metric_Status (First, Axis)
           /= Flyology_Bench.Metric_Not_Requested,
         "requested hardware axis has no availability status");
      Check
        (Flyology_Bench.Metric_Available (First, Axis)
           = (Flyology_Bench.Metric_Status (First, Axis)
                = Flyology_Bench.Metric_Collected),
         "hardware metric status disagrees with availability");
      if Flyology_Bench.Metadata.Operating_System /= "linux" then
         Check
           (Flyology_Bench.Metric_Status (First, Axis)
              = Flyology_Bench.Unsupported_Platform,
            "non-Linux hardware axis lacks unsupported-platform status");
      end if;
   end loop;
   Check
     (Flyology_Bench.Scope (Flyology_Bench.CPU_Cycles)
        = Flyology_Bench.Native_Task_Tree,
      "inherited hardware counter scope is not explicit");

   if Require_Hardware
     or else Flyology_Bench.Metric_Available (First, Flyology_Bench.CPU_Cycles)
   then
      declare
         Serial_Result : Flyology_Bench.Measurement;
         Worker_Result : Flyology_Bench.Measurement;
      begin
         Serial_Attribution (Attribution_Config, Serial_Result);
         Worker_Attribution (Attribution_Config, Worker_Result);
         if Require_Hardware then
            for Axis in Flyology_Bench.CPU_Cycles
              .. Flyology_Bench.Instructions_Per_Cycle
            loop
               Check
                 (Flyology_Bench.Metric_Available (Worker_Result, Axis),
                  "required hardware axis "
                  & Flyology_Bench.Metric_Name (Axis) & " unavailable: "
                  & Flyology_Bench.Metric_Availability'Image
                      (Flyology_Bench.Metric_Status (Worker_Result, Axis)));
            end loop;
         end if;
         if Flyology_Bench.Metric_Available
              (Serial_Result, Flyology_Bench.CPU_Cycles)
           and then Flyology_Bench.Metric_Available
             (Worker_Result, Flyology_Bench.CPU_Cycles)
         then
            declare
               Serial_Cycles : constant Long_Float :=
                 Flyology_Bench.Metric_Statistics
                   (Serial_Result, Flyology_Bench.CPU_Cycles).Median;
               Worker_Cycles : constant Long_Float :=
                 Flyology_Bench.Metric_Statistics
                   (Worker_Result, Flyology_Bench.CPU_Cycles).Median;
            begin
               --  Four workers each repeat the serial batch's work, so an
               --  inherited counter reports about four times as many cycles
               --  per logical operation. Only the parent's own cycles would
               --  leave the two batches comparable.
               Check
                 (Serial_Cycles > 0.0
                    and then Worker_Cycles >= 2.0 * Serial_Cycles,
                  "worker-task cycles were not counted: serial"
                  & Long_Float'Image (Serial_Cycles) & " worker"
                  & Long_Float'Image (Worker_Cycles) & " cycles per operation");
            end;
         end if;
      end;
   end if;

   Batched_Benchmark (Config, Second);
   Check (Batched_Calls > 0, "batched benchmark did not run");
   Check
     (Flyology_Bench.Sample_Nanoseconds (Second, 1) >= 0.0,
      "raw sample is negative");

   Operation_Comparison (Config, Compared);
   Check
     (abs
        (Flyology_Bench.Compare_Metric
           (Compared, Flyology_Bench.Wall_Time).Change
         - Flyology_Bench.Relative_Time_Change_Percent (Compared)) < 0.000_001,
      "wall-time metric comparison diverges from the latency comparison");
   Check
     (Flyology_Bench.Samples
        (Flyology_Bench.Reference_Measurement (Compared)) = Config.Samples,
      "comparison returned the wrong sample count");
   Check
     (Flyology_Bench.Median_Batch_Nanoseconds
        (Flyology_Bench.Reference_Measurement (Compared))
        <= 4.0 * Flyology_Bench.Median_Batch_Nanoseconds
          (Flyology_Bench.Contender_Measurement (Compared))
      and then Flyology_Bench.Median_Batch_Nanoseconds
        (Flyology_Bench.Contender_Measurement (Compared))
        <= 4.0 * Flyology_Bench.Median_Batch_Nanoseconds
          (Flyology_Bench.Reference_Measurement (Compared)),
      "equal-time comparison produced dissimilar timed slices");
   Check
     (Flyology_Bench.Reference_First_Samples (Compared)
        + Flyology_Bench.Contender_First_Samples (Compared)
      = Natural (Config.Samples),
      "comparison order counts do not cover every sample");
   Check
     (Flyology_Bench.Reference_First_Samples (Compared) > 0
      and then Flyology_Bench.Contender_First_Samples (Compared) > 0,
      "comparison did not use both sample orders");
   Check
     (Flyology_Bench.Contender_Wins (Compared)
        + Flyology_Bench.Reference_Wins (Compared)
        + Flyology_Bench.Ties (Compared)
      = Natural (Config.Samples),
      "comparison outcomes do not cover every sample");
   Check
     (Flyology_Bench.Sample_Speedup (Compared, 1) > 0.0,
      "comparison returned a nonpositive speedup");
   Check
     (Flyology_Bench.Speedup_Confidence_Low (Compared) > 0.0
      and then Flyology_Bench.Speedup_Confidence_Low (Compared)
        <= Flyology_Bench.Speedup_Confidence_High (Compared),
      "comparison returned an invalid speedup interval");
   Check
     (Flyology_Bench.Relative_Time_Change_Confidence_Low (Compared)
        <= Flyology_Bench.Relative_Time_Change_Confidence_High (Compared),
      "comparison returned an invalid relative-change interval");
   Check
     (abs Flyology_Bench.Lag_One_Correlation (Compared) <= 1.0,
      "comparison returned an invalid lag-one correlation");

   Operation_Comparison
     ((Config with delta
        Comparison_Batching => Flyology_Bench.Shared_Iterations),
      Shared_Compared);
   Check
     (Flyology_Bench.Iterations_Per_Sample
        (Flyology_Bench.Reference_Measurement (Shared_Compared))
      = Flyology_Bench.Iterations_Per_Sample
          (Flyology_Bench.Contender_Measurement (Shared_Compared)),
      "shared-iteration comparison used different iteration counts");

   Batched_Comparison (Config, Batched_Compared);
   Check
     (Flyology_Bench.Geometric_Mean_Speedup (Batched_Compared) > 0.0,
      "batched comparison returned a nonpositive speedup");

   Hooked_Benchmark (Config, Hooked);
   Check
     (Setup_Count > 0 and then Setup_Count = Teardown_Count,
      "untimed setup and teardown hooks are unbalanced");
   Check
     (abs
        (Flyology_Bench.Metric_Statistics
           (Hooked, Flyology_Bench.Flyology_Dispatches).Median - 1.0)
        < 0.000_001,
      "scheduler axis included untimed setup or teardown hooks");
   Result_Benchmark (Config, Result_Produced);
   Check
     (Flyology_Bench.Median_Nanoseconds (Result_Produced) >= 0.0,
      "result-producing benchmark failed");

   Budgeted_Benchmark
     ((Config with delta
        Warmup_Time => 0.0,
        Measurement_Time => 0.010,
        Maximum_Sampling_Time => 0.008,
        Samples => 20),
      Budgeted);
   Check
     (Flyology_Bench.Samples (Budgeted) = Flyology_Bench.Sample_Count'First,
      "sampling budget did not stop after the minimum sample count");

   Multi_Benchmark
     ((Config with delta
        Progress => Observe_Multi_Progress'Unrestricted_Access),
      Multi_Compared);
   Check
     (Flyology_Bench.Cases (Multi_Compared) = 3,
      "multi-way comparison returned the wrong case count");
   Check
     (Flyology_Bench.Geometric_Mean_Speedup
        (Flyology_Bench.Versus_Reference (Multi_Compared, 2)) > 0.0,
      "multi-way comparison returned an invalid speedup");
   Check
     (Saw_Reference_Progress
      and then Saw_Same_Progress
      and then Saw_Double_Progress,
      "multi-way sampling progress did not identify every case");
   Check
     (Flyology_Bench.Shootout_Schedule (Multi_Compared)
        = Flyology_Bench.Balanced_Rounds
      and then Flyology_Bench.Shootout_Batching (Multi_Compared)
        = Flyology_Bench.Equal_Time,
      "multi-way comparison did not retain its collection policies");

   Multi_Benchmark
     ((Config with delta
        Shootout_Scheduling => Flyology_Bench.Sequential_Cases),
      Sequential_Compared);
   Check
     (Flyology_Bench.Shootout_Schedule (Sequential_Compared)
        = Flyology_Bench.Sequential_Cases,
      "sequential shootout did not retain its schedule");

   Flyology_Bench.Baselines.Save
     (Baseline_Path, "volatile_increment", First, "smoke-host");
   declare
      Saved : constant Flyology_Bench.Baselines.Baseline :=
        Flyology_Bench.Baselines.Load (Baseline_Path);
      Regression : constant Flyology_Bench.Baselines.Regression :=
        Flyology_Bench.Baselines.Compare
          (Saved, First, Fingerprint => "smoke-host");
      Incompatible : constant Flyology_Bench.Baselines.Regression :=
        Flyology_Bench.Baselines.Compare
          (Saved, First, Fingerprint => "different-host");
   begin
      Check
        (Flyology_Bench.Baselines.Name (Saved) = "volatile_increment",
         "baseline name did not round trip");
      Check
        (Flyology_Bench.Baselines.Compatible (Regression)
         and then Flyology_Bench.Baselines.Speedup (Regression) > 0.0,
         "compatible baseline comparison failed");
      Check
        (not Flyology_Bench.Baselines.Compatible (Incompatible),
         "baseline accepted an incompatible fingerprint");
   end;
   Ada.Directories.Delete_File (Baseline_Path);

   Flyology_Bench.Reporters.Put_Console ("volatile_increment", First);
   Flyology_Bench.Reporters.Put_Comparison_Console
     ("one_increment", "two_increments", Compared);
   Put_Multi_Console (Multi_Compared, Style => Flyology_Bench.Reporters.Plain);

   --  The machine-readable reporters are grouped between markers so a runner
   --  can extract exactly their output and check the published schemas.
   Ada.Text_IO.Put_Line (Machine_Output_Begin);
   Flyology_Bench.Reporters.Put_CSV_Header;
   Flyology_Bench.Reporters.Put_CSV ("volatile_increment", First);
   Flyology_Bench.Reporters.Put_Metrics_CSV_Header;
   Flyology_Bench.Reporters.Put_Metrics_CSV ("volatile_increment", First);
   Flyology_Bench.Reporters.Put_JSON ("volatile_increment", First);
   Flyology_Bench.Reporters.Put_Comparison_CSV_Header;
   Flyology_Bench.Reporters.Put_Comparison_CSV
     ("one_increment", "two_increments", Compared);
   Flyology_Bench.Reporters.Put_Comparison_Metrics_CSV_Header;
   Flyology_Bench.Reporters.Put_Comparison_Metrics_CSV
     ("one_increment", "two_increments", Compared);
   Flyology_Bench.Reporters.Put_Comparison_JSON
     ("one_increment", "two_increments", Compared);
   Flyology_Bench.Reporters.Put_Multi_Comparison_CSV_Header;
   Put_Multi_CSV (Multi_Compared);
   Flyology_Bench.Reporters.Put_Comparison_Metrics_CSV_Header;
   Put_Multi_Metrics_CSV (Multi_Compared);
   Put_Multi_JSON (Multi_Compared);
   Ada.Text_IO.Put_Line (Machine_Output_End);
   Ada.Text_IO.Put_Line ("flyology_bench smoke: PASS");
end Flyology_Bench_Smoke;
