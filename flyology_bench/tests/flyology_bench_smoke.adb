--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Text_IO;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Real_Time;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Flyology_Bench;
with Flyology_Bench.Baselines;
with Flyology_Bench.Host_Lock;
with Flyology_Bench.Metadata;
with Flyology_Bench.Reporters;
with GNAT.OS_Lib;
with Interfaces;

procedure Flyology_Bench_Smoke is
   use type Flyology_Bench.Iteration_Count;
   use type Flyology_Bench.Progress_Phase;
   use type Flyology_Bench.Shootout_Schedule_Policy;
   use type Flyology_Bench.Comparison_Batch_Policy;
   use type Flyology_Bench.Metric_Set;
   use type Flyology_Bench.Metric_Availability;
   use type Flyology_Bench.Metric_Scope;
   use type Flyology_Bench.Interference_Source;
   use type Flyology_Bench.Placement_Outcome;
   use type Flyology_Bench.Host_Lock_Outcome;
   use type Flyology_Bench.Host_Lock.Acquisition;
   use type Interfaces.Unsigned_64;

   Counter : Interfaces.Unsigned_64 := 0 with Volatile;

   procedure Scheduler_Probe
     (Snapshot : out Flyology_Bench.Flyology_Scheduler_Snapshot) is
   begin
      Snapshot :=
        (Available  => True,
         Dispatches => Counter,
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
      Confidence_Level_Percent => 90.0,
      Bootstrap_Resamples => 200,
      Random_Seed         => 42,
      Metrics             =>
        Flyology_Bench.Process_Resource_Metrics or
          Flyology_Bench.Linux_Hardware_Metrics or
          Flyology_Bench.Flyology_Scheduler_Metrics,
      Scheduler_Probe     => Scheduler_Probe'Unrestricted_Access,
      CPU_Quiescence      => (others => <>),
      Interference        => (others => <>),
      Placement           => (others => <>),
      Host_Lock           => (others => <>),
      Collect_Process_Telemetry => False,
      Progress            => null,
      Progress_Name       => <>);
   First  : Flyology_Bench.Measurement;
   Maximum_Resample_Result : Flyology_Bench.Measurement;
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

   --  Foreign load has to come from another process. A burner task inside
   --  this process would be counted as our own CPU time and subtracted out,
   --  which is exactly what the attribution is supposed to do. The loop is
   --  finite so a crashed test cannot leave the machine spinning.
   function Spawn_Foreign_Load return GNAT.OS_Lib.Process_Id is
      Arguments : constant GNAT.OS_Lib.Argument_List :=
        (1 => new String'("-c"),
         2 => new String'
           ("i=0; while [ $i -lt 200000000 ]; do i=$((i+1)); done"));
      Burner : constant GNAT.OS_Lib.Process_Id :=
        GNAT.OS_Lib.Non_Blocking_Spawn ("/bin/sh", Arguments);
   begin
      --  Let the shell reach its loop, so the very first observation window
      --  already sees load rather than process startup.
      delay 0.050;
      return Burner;
   end Spawn_Foreign_Load;

   --  Whether Linux reports more than one thread sibling for a CPU. A list
   --  such as "0,8" or "0-1" names several; a bare "0" names one.
   function Sibling_List_Names_Several (CPU : Natural) return Boolean is
      Path : constant String :=
        "/sys/devices/system/cpu/cpu"
        & Ada.Strings.Fixed.Trim (Natural'Image (CPU), Ada.Strings.Both)
        & "/topology/thread_siblings_list";
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      declare
         Line : constant String := Ada.Text_IO.Get_Line (File);
      begin
         Ada.Text_IO.Close (File);
         for Item of Line loop
            if Item = ',' or else Item = '-' then
               return True;
            end if;
         end loop;
         return False;
      end;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return False;
   end Sibling_List_Names_Several;

   --  A CPU-consuming thread of this very process. Placement binds only the
   --  calling thread, so this one is free to occupy a watched CPU, where its
   --  time cannot be told apart from foreign load.
   Stop_Sibling_Load : Boolean := False with Volatile;

   task type Sibling_Load;

   task body Sibling_Load is
      Spin : Natural := 0 with Volatile;
   begin
      while not Stop_Sibling_Load loop
         if Spin = Natural'Last then
            Spin := 0;
         else
            Spin := Spin + 1;
         end if;
      end loop;
   end Sibling_Load;

   procedure Stop_Foreign_Load (Burner : GNAT.OS_Lib.Process_Id) is
      use type GNAT.OS_Lib.Process_Id;
   begin
      if Burner /= GNAT.OS_Lib.Invalid_Pid then
         GNAT.OS_Lib.Kill (Burner, Hard_Kill => True);
      end if;
   end Stop_Foreign_Load;
begin
   Check
     (Flyology_Bench.Default_Configuration.Confidence_Level_Percent = 95.0
      and then Flyology_Bench.Default_Configuration.Bootstrap_Resamples
        = 2_000,
      "default statistical settings changed");
   declare
      Too_Low : Long_Float := 49.9 with Volatile;
      Too_Many : Positive := 10_001 with Volatile;
   begin
      begin
         declare
            Rejected : constant Flyology_Bench.Confidence_Percentage :=
              Flyology_Bench.Confidence_Percentage (Too_Low);
            pragma Unreferenced (Rejected);
         begin
            raise Program_Error with "confidence bound was not enforced";
         end;
      exception
         when Constraint_Error => null;
      end;
      begin
         declare
            Rejected : constant Flyology_Bench.Bootstrap_Resample_Count :=
              Flyology_Bench.Bootstrap_Resample_Count (Too_Many);
            pragma Unreferenced (Rejected);
         begin
            raise Program_Error with "resample bound was not enforced";
         end;
      exception
         when Constraint_Error => null;
      end;
   end;
   declare
      Before   : constant Natural := Counter;
      Rejected : Boolean := False;
      Discarded : Flyology_Bench.Measurement;
   begin
      begin
         Operation_Benchmark
           ((Config with delta
              Samples => 1_000,
              Bootstrap_Resamples => 10_000,
              Metrics => [others => True]),
            Discarded);
      exception
         when Constraint_Error => Rejected := True;
      end;
      Check (Rejected, "oversized bootstrap workload was accepted");
      Check (Counter = Before,
             "bootstrap workload was rejected after benchmark execution");
   end;
   Operation_Benchmark
     ((Config with delta
        Warmup_Time => 0.0,
        Measurement_Time => 0.001,
        Samples => 10,
        Metrics => Flyology_Bench.Time_Metrics,
        Scheduler_Probe => null,
        Bootstrap_Resamples => 10_000),
      Maximum_Resample_Result);
   Check
     (Flyology_Bench.Bootstrap_Resamples (Maximum_Resample_Result) = 10_000,
      "maximum bootstrap resample count was not retained");
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
     (Flyology_Bench.Confidence_Level_Percent (First) = 90.0
      and then Flyology_Bench.Bootstrap_Resamples (First) = 200,
      "measurement did not retain its statistical settings");
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
     (Flyology_Bench.Confidence_Level_Percent (Compared) = 90.0
      and then Flyology_Bench.Bootstrap_Resamples (Compared) = 200,
      "comparison did not retain its statistical settings");
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
          (Saved, First, Fingerprint => "smoke-host",
           Confidence_Level_Percent => 80.0,
           Bootstrap_Resamples => 150);
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

   --  The host CPU claim convention. flock is per open file description, so
   --  two claims inside one process conflict exactly as two processes would.
   declare
      use Ada.Strings.Unbounded;

      Lock_Path : constant String := ".flyology_bench_test_host_cpu.lock";
      Machine_Claim : Flyology_Bench.Host_Lock.Claim;
      Rival_Claim   : Flyology_Bench.Host_Lock.Claim;
      Outcome  : Flyology_Bench.Host_Lock.Acquisition;
      Identity : Flyology_Bench.Host_Lock.Holder;
   begin
      Flyology_Bench.Host_Lock.Try_Acquire
        (Machine_Claim, Outcome, Path => Lock_Path, Tool => "smoke tool");
      Check
        (Outcome = Flyology_Bench.Host_Lock.Acquired,
         "host CPU claim was not taken on a free path");
      Check
        (Flyology_Bench.Host_Lock.Held (Machine_Claim),
         "host CPU claim does not report itself held");

      Flyology_Bench.Host_Lock.Try_Acquire
        (Rival_Claim, Outcome, Path => Lock_Path);
      Check
        (Outcome = Flyology_Bench.Host_Lock.Busy,
         "a second machine-wide claim did not conflict");

      Identity := Flyology_Bench.Host_Lock.Read_Holder (Lock_Path);
      Check (Identity.Available, "claim file carried no readable content");
      Check
        (To_String (Identity.Convention_Id)
           = Flyology_Bench.Host_Lock.Convention,
         "claim file lost its convention identifier");
      Check
        (To_String (Identity.Tool) = "smoke tool",
         "claim file lost the holding tool identity");
      Check
        (To_String (Identity.Claim) = "all",
         "a machine-wide claim did not record itself as all");
      Check
        (Length (Identity.Working_Directory) > 0,
         "claim file recorded no working directory");
      Check
        (Length (Identity.Process_Id) > 0,
         "claim file recorded no process identifier");

      Flyology_Bench.Host_Lock.Release (Machine_Claim);
      Flyology_Bench.Host_Lock.Try_Acquire
        (Rival_Claim, Outcome, Path => Lock_Path);
      Check
        (Outcome = Flyology_Bench.Host_Lock.Acquired,
         "released claim did not become available");
      Flyology_Bench.Host_Lock.Release (Rival_Claim);
      Ada.Directories.Delete_File (Lock_Path);
   end;

   --  Disjoint CPU claims run concurrently; overlapping ones do not, and a
   --  machine-wide claim excludes both.
   declare
      Lock_Path : constant String := ".flyology_bench_test_cores.lock";
      Pair    : Flyology_Bench.Host_Lock.Claim;
      Single  : Flyology_Bench.Host_Lock.Claim;
      Overlap : Flyology_Bench.Host_Lock.Claim;
      Machine : Flyology_Bench.Host_Lock.Claim;
      Outcome : Flyology_Bench.Host_Lock.Acquisition;
   begin
      Flyology_Bench.Host_Lock.Try_Acquire
        (Pair, Outcome, CPUs => (0, 1), Path => Lock_Path);
      Check
        (Outcome = Flyology_Bench.Host_Lock.Acquired,
         "a CPU claim was not taken on a free path");
      Flyology_Bench.Host_Lock.Try_Acquire
        (Single, Outcome, CPUs => (1 => 2), Path => Lock_Path);
      Check
        (Outcome = Flyology_Bench.Host_Lock.Acquired,
         "a disjoint CPU claim was refused");
      Flyology_Bench.Host_Lock.Try_Acquire
        (Overlap, Outcome, CPUs => (1 => 1), Path => Lock_Path);
      Check
        (Outcome = Flyology_Bench.Host_Lock.Busy,
         "an overlapping CPU claim was allowed");
      Flyology_Bench.Host_Lock.Try_Acquire
        (Machine, Outcome, Path => Lock_Path);
      Check
        (Outcome = Flyology_Bench.Host_Lock.Busy,
         "a machine-wide claim ignored held CPU claims");
      Flyology_Bench.Host_Lock.Release (Pair);
      Flyology_Bench.Host_Lock.Release (Single);
      Ada.Directories.Delete_File (Lock_Path);
      Ada.Directories.Delete_File (".flyology_bench_test_cores.0.lock");
      Ada.Directories.Delete_File (".flyology_bench_test_cores.1.lock");
      Ada.Directories.Delete_File (".flyology_bench_test_cores.2.lock");
   end;

   --  Observing interference must never change what is collected.
   declare
      Observed : Flyology_Bench.Measurement;
      Report   : Flyology_Bench.Environment_Report;
   begin
      Operation_Benchmark
        ((Config with delta
           Interference =>
             (Enabled                     => True,
              Response                    => Flyology_Bench.Observe,
              Maximum_Foreign_CPU_Percent => 100.0,
              Window                      => 0.002,
              others                      => <>)),
         Observed);
      Report := Flyology_Bench.Environment (Observed);
      Check (Report.Watched, "interference watch produced no usable window");
      Check (Report.Windows > 0, "interference watch closed no window");
      Check
        (Report.Attribution = Flyology_Bench.Host_Wide,
         "unplaced run claimed core-scoped attribution");
      Check
        (Report.Contaminated_Samples = 0,
         "a 100 percent foreign limit still reported contamination");
      Check
        (Report.Retaken_Samples = 0 and then Report.Pauses = 0,
         "Observe discarded or suspended collection");
      Check
        (Flyology_Bench.Samples (Observed) = Config.Samples,
         "observing interference changed the sample count");
      Check
        (Flyology_Bench.Sample_Foreign_CPU_Percent (Observed, 1) >= 0.0,
         "per-sample foreign share was not retained");
   end;

   --  A limit of zero plus real foreign load makes every window contaminated,
   --  which exercises the retake path and its budget.
   declare
      Retaken : Flyology_Bench.Measurement;
      Report  : Flyology_Bench.Environment_Report;
      Burner  : constant GNAT.OS_Lib.Process_Id := Spawn_Foreign_Load;
   begin
      Operation_Benchmark
        ((Config with delta
           Interference =>
             (Enabled                     => True,
              Response                    => Flyology_Bench.Retake,
              Maximum_Foreign_CPU_Percent => 0.0,
              Window                      => 0.002,
              Maximum_Retakes             => 4)),
         Retaken);
      Report := Flyology_Bench.Environment (Retaken);
      Check (Report.Retaken_Samples > 0, "Retake discarded nothing");
      Check
        (Report.Retaken_Samples <= 4,
         "Retake exceeded its configured budget");
      Check
        (Flyology_Bench.Samples (Retaken) = Config.Samples,
         "retaking samples changed the sample count");
      Check
        (not Report.Budget_Exhausted
         or else Report.Contaminated_Samples > 0,
         "samples kept after budget exhaustion were not marked");
      Check
        (Report.Contaminated_Samples <= Report.Observed_Samples,
         "more samples were contaminated than were observed");
      Stop_Foreign_Load (Burner);
   end;

   --  Pausing must wait, re-warm, and still finish the run.
   declare
      Paused : Flyology_Bench.Measurement;
      Report : Flyology_Bench.Environment_Report;
      Burner : constant GNAT.OS_Lib.Process_Id := Spawn_Foreign_Load;
   begin
      Operation_Benchmark
        ((Config with delta
           Interference =>
             (Enabled                     => True,
              Response                    => Flyology_Bench.Pause,
              Maximum_Foreign_CPU_Percent => 0.0,
              Window                      => 0.002,
              Maximum_Retakes             => 2,
              Settle_Time                 => 0.010,
              Maximum_Pause_Time          => 0.060,
              Rewarm_Time                 => 0.002)),
         Paused);
      Report := Flyology_Bench.Environment (Paused);
      Check (Report.Pauses > 0, "Pause never suspended collection");
      Check
        (Report.Paused_Nanoseconds > 0.0,
         "a pause recorded no elapsed time");
      Check
        (Report.Retaken_Samples > 0,
         "a pause did not collect its window again");
      Check
        (Flyology_Bench.Samples (Paused) = Config.Samples,
         "pausing changed the sample count");
      Stop_Foreign_Load (Burner);
   end;

   --  Placement is advisory on Darwin and strict on Linux. Only a strict
   --  binding may upgrade attribution to the placed CPUs.
   declare
      Placed : Flyology_Bench.Measurement;
      Report : Flyology_Bench.Environment_Report;
   begin
      Operation_Benchmark
        ((Config with delta
           Placement =>
             (Enabled          => True,
              CPU              => 0,
              Include_Siblings => True,
              Require_Strict   => False),
           Interference =>
             (Enabled                     => True,
              Response                    => Flyology_Bench.Observe,
              Maximum_Foreign_CPU_Percent => 100.0,
              Window                      => 0.002,
              others                      => <>)),
         Placed);
      Report := Flyology_Bench.Environment (Placed);
      --  Apple Silicon implements no thread affinity at all, so a rejected
      --  request is an ordinary outcome rather than a test failure.
      Check
        (Report.Placement /= Flyology_Bench.Placement_Not_Requested,
         "an enabled placement policy was not attempted");
      if Report.Placement = Flyology_Bench.Placement_Strict then
         Check
           (Report.Attribution = Flyology_Bench.Core_Scoped,
            "strict placement did not scope attribution to its CPUs");
         Check
           (Report.Watched_CPUs >= 1,
            "core-scoped attribution watched no CPU");
         --  Attribution, placement, and the watched set are all decided
         --  before sampling starts, so they say nothing about whether the
         --  estimator works. Core-scoped windows subtract thread CPU time
         --  rather than process CPU time, and that probe has no other
         --  assertion covering it.
         Check
           (Report.Watched and then Report.Windows > 0,
            "core-scoped attribution closed no observation window");
         --  The watched set must grow to cover the placed CPU's SMT
         --  siblings. Deriving the expectation from the host's own topology
         --  keeps this meaningful on an SMT machine and vacuous elsewhere,
         --  instead of asserting a count this particular host happens to
         --  have.
         if Sibling_List_Names_Several (0) then
            Check
              (Report.Watched_CPUs >= 2,
               "SMT siblings of the placed CPU were not watched");
         end if;
      else
         Check
           (Report.Attribution = Flyology_Bench.Host_Wide,
            "attribution was scoped to CPUs that were never claimed");
      end if;
   end;

   --  Core-scoped attribution holds only while this process runs one
   --  CPU-consuming thread. When another of its threads shares the watched
   --  CPUs, the run must drop to host-wide rather than report its own runtime
   --  as interference.
   declare
      Diluted : Flyology_Bench.Measurement;
      Report  : Flyology_Bench.Environment_Report;
      Worker  : Sibling_Load;
      pragma Unreferenced (Worker);
   begin
      begin
         Operation_Benchmark
           ((Config with delta
              Placement =>
                (Enabled          => True,
                 CPU              => 0,
                 Include_Siblings => True,
                 Require_Strict   => False),
              Interference =>
                (Enabled                     => True,
                 Response                    => Flyology_Bench.Observe,
                 Maximum_Foreign_CPU_Percent => 10.0,
                 Window                      => 0.002,
                 others                      => <>)),
            Diluted);
      exception
         when others =>
            Stop_Sibling_Load := True;
            raise;
      end;
      Stop_Sibling_Load := True;
      Report := Flyology_Bench.Environment (Diluted);
      if Report.Placement = Flyology_Bench.Placement_Strict then
         Check
           (Report.Attribution_Diluted,
            "a sibling thread on the watched CPUs was not detected");
         Check
           (Report.Attribution = Flyology_Bench.Host_Wide,
            "diluted attribution did not fall back to host-wide");
         Check
           (Report.Watched_CPUs = 0,
            "host-wide attribution still reports watched CPUs");
      else
         Check
           (not Report.Attribution_Diluted,
            "attribution was diluted without ever being core-scoped");
      end if;
   end;

   --  Require_Strict turns a platform that cannot bind a thread into an
   --  error instead of a silent downgrade to host-wide observation.
   declare
      Discarded : Flyology_Bench.Measurement;
      Strict    : Flyology_Bench.Measurement;
      Refused   : Boolean := False;
   begin
      begin
         Operation_Benchmark
           ((Config with delta
              Placement =>
                (Enabled          => True,
                 CPU              => 0,
                 Include_Siblings => True,
                 Require_Strict   => True)),
            Discarded);
         Strict := Discarded;
      exception
         when Flyology_Bench.Placement_Unavailable =>
            Refused := True;
      end;
      Check
        (Refused
         or else Flyology_Bench.Environment (Strict).Placement
           = Flyology_Bench.Placement_Strict,
         "Require_Strict neither bound the thread nor refused the run");
   end;

   --  A run holds its claim for its whole duration, and a claim it cannot
   --  take is reported rather than silently ignored.
   declare
      Lock_Path : constant String := ".flyology_bench_test_run.lock";
      Claimed   : Flyology_Bench.Measurement;
      Blocked   : Flyology_Bench.Measurement;
      Rival     : Flyology_Bench.Host_Lock.Claim;
      Outcome   : Flyology_Bench.Host_Lock.Acquisition;
      Refused   : Boolean := False;
   begin
      Operation_Benchmark
        ((Config with delta
           Host_Lock =>
             (Enabled               => True,
              Path                  =>
                Ada.Strings.Unbounded.To_Unbounded_String (Lock_Path),
              Timeout               => 1.0,
              Poll_Interval         => 0.010,
              Require_Machine_Scope => False)),
         Claimed);
      Check
        (Flyology_Bench.Environment (Claimed).Host_Lock
           in Flyology_Bench.Lock_Held
             .. Flyology_Bench.Lock_Namespace_Scoped,
         "a run on a free path did not take its host CPU claim");

      Flyology_Bench.Host_Lock.Try_Acquire
        (Rival, Outcome, Path => Lock_Path, Tool => "rival");
      Check
        (Outcome = Flyology_Bench.Host_Lock.Acquired,
         "the run did not release its claim when it finished");
      Operation_Benchmark
        ((Config with delta
           Host_Lock =>
             (Enabled               => True,
              Path                  =>
                Ada.Strings.Unbounded.To_Unbounded_String (Lock_Path),
              Timeout               => 0.050,
              Poll_Interval         => 0.010,
              Require_Machine_Scope => False)),
         Blocked);
      Check
        (Flyology_Bench.Environment (Blocked).Host_Lock
           = Flyology_Bench.Lock_Busy,
         "a contended claim was not reported as busy");

      begin
         Operation_Benchmark
           ((Config with delta
              Host_Lock =>
                (Enabled               => True,
                 Path                  =>
                   Ada.Strings.Unbounded.To_Unbounded_String (Lock_Path),
                 Timeout               => 0.050,
                 Poll_Interval         => 0.010,
                 Require_Machine_Scope => True)),
            Blocked);
      exception
         when Flyology_Bench.Host_Lock_Unavailable =>
            Refused := True;
      end;
      Check
        (Refused,
         "a required machine-wide claim proceeded without one");
      Flyology_Bench.Host_Lock.Release (Rival);
      Ada.Directories.Delete_File (Lock_Path);
   end;

   Flyology_Bench.Reporters.Put_Console ("volatile_increment", First);
   Flyology_Bench.Reporters.Put_Comparison_Console
     ("one_increment", "two_increments", Compared);
   Put_Multi_Console (Multi_Compared, Style => Flyology_Bench.Reporters.Plain);

   --  The machine-readable reporters are grouped between markers so a runner
   --  can extract exactly their output and check the published schemas.
   Ada.Text_IO.Put_Line (Machine_Output_Begin);
   Flyology_Bench.Reporters.Put_CSV_Header;
   Flyology_Bench.Reporters.Put_CSV ("volatile_increment", First);
   Flyology_Bench.Reporters.Put_CSV
     ("maximum_resamples", Maximum_Resample_Result);
   Flyology_Bench.Reporters.Put_Metrics_CSV_Header;
   Flyology_Bench.Reporters.Put_Metrics_CSV ("volatile_increment", First);
   Flyology_Bench.Reporters.Put_JSON ("volatile_increment", First);
   Flyology_Bench.Reporters.Put_JSON
     ("maximum_resamples", Maximum_Resample_Result);
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
