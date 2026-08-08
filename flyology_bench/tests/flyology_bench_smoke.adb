--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Text_IO;
with Ada.Directories;
with Ada.Real_Time;
with Ada.Strings.Fixed;
with Flyology_Bench;
with Flyology_Bench.Baselines;
with Flyology_Bench.Reporters;

procedure Flyology_Bench_Smoke is
   use type Flyology_Bench.Iteration_Count;
   use type Flyology_Bench.Progress_Phase;
   use type Flyology_Bench.Shootout_Schedule_Policy;
   use type Flyology_Bench.Comparison_Batch_Policy;

   Counter : Natural := 0 with Volatile;

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
   procedure Put_Multi_JSON is new
     Flyology_Bench.Reporters.Put_Multi_Comparison_JSON (Smoke_Case);

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
     (Warmup_Time         => 0.001,
      Measurement_Time    => 0.010,
      Maximum_Sampling_Time => 0.0,
      Samples             => 10,
      Minimum_Sample_Time => 0.000_010,
      Maximum_Iterations  => 10_000_000,
      Comparison_Batching => Flyology_Bench.Equal_Time,
      Shootout_Scheduling => Flyology_Bench.Balanced_Rounds,
      Subtract_Timer_Cost => False,
      Practical_Threshold_Percent => 1.0,
      Random_Seed         => 42,
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

   Batched_Benchmark (Config, Second);
   Check (Batched_Calls > 0, "batched benchmark did not run");
   Check
     (Flyology_Bench.Sample_Nanoseconds (Second, 1) >= 0.0,
      "raw sample is negative");

   Operation_Comparison (Config, Compared);
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
   Flyology_Bench.Reporters.Put_CSV_Header;
   Flyology_Bench.Reporters.Put_CSV ("volatile_increment", First);
   Flyology_Bench.Reporters.Put_JSON ("volatile_increment", First);
   Flyology_Bench.Reporters.Put_Comparison_Console
     ("one_increment", "two_increments", Compared);
   Flyology_Bench.Reporters.Put_Comparison_CSV_Header;
   Flyology_Bench.Reporters.Put_Comparison_CSV
     ("one_increment", "two_increments", Compared);
   Flyology_Bench.Reporters.Put_Comparison_JSON
     ("one_increment", "two_increments", Compared);
   Put_Multi_Console (Multi_Compared, Style => Flyology_Bench.Reporters.Plain);
   Flyology_Bench.Reporters.Put_Multi_Comparison_CSV_Header;
   Put_Multi_CSV (Multi_Compared);
   Put_Multi_JSON (Multi_Compared);
   Ada.Text_IO.Put_Line ("flyology_bench smoke: PASS");
end Flyology_Bench_Smoke;
