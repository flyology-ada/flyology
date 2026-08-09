--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Environment_Variables;
with Ada.Text_IO;
with Flyology_Bench;
with Flyology_Bench.Recording;
with Flyology_Bench.Recording.Reporters;
with Interfaces;

procedure Recording_Smoke is
   use type Flyology_Bench.Metric_Set;
   use type Flyology_Bench.Metric_Availability;
   use type Interfaces.Unsigned_64;
   package Recording renames Flyology_Bench.Recording;
   package Reporters renames Flyology_Bench.Recording.Reporters;
   use type Recording.Sample_Outcome;

   Recorder : Recording.Recorder
     (Maximum_Benchmarks => 2,
      Retained_Samples   => 64);
   Fast : Recording.Benchmark;
   Slow : Recording.Benchmark;
   Fast_Result : Recording.Recorded_Measurement;
   Slow_Result : Recording.Recorded_Measurement;
   Compared : Recording.Recorded_Comparison;
   No_Wall_Compared : Recording.Recorded_Comparison;
   Partial_Compared : Recording.Recorded_Comparison;

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;
begin
   Recording.Register
     (Recorder, "fast" & Character'Val (9) & "request", Fast);
   Recording.Register (Recorder, "slow request", Slow);
   Recording.Start
     (Recorder,
      (--  Hardware axes exercise persistent per-thread recorder groups on
       --  Linux and retain explicit unavailable statuses elsewhere.
       Metrics => Flyology_Bench.Process_Resource_Metrics
         or Flyology_Bench.Linux_Hardware_Metrics,
       others  => <>));

   --  A rejected second start must not replace the active configuration or
   --  lose its native performance-counter session.
   begin
      Recording.Start
        (Recorder,
         (Metrics =>
            (Flyology_Bench.Process_RSS => True, others => False),
          others => <>));
      raise Program_Error with "second recorder start was accepted";
   exception
      when Recording.Recording_Already_Started =>
         null;
   end;

   declare
      task type Worker (Identity : Positive);
      task body Worker is
      begin
         for Index in 1 .. 20 loop
            declare
               Sample : Recording.Span;
               Which  : constant Recording.Benchmark :=
                 (if Identity mod 2 = 0 then Fast else Slow);
            begin
               Recording.Begin_Sample (Recorder, Which, Sample);
               if Identity mod 2 = 0 then
                  delay 0.000_2;
               else
                  delay 0.000_8;
               end if;
               Recording.Finish
                 (Sample,
                  (if Index = 20 then Recording.Failure
                   else Recording.Success));
            end;
         end loop;
      end Worker;

      One   : Worker (1);
      Two   : Worker (2);
      Three : Worker (3);
      Four  : Worker (4);
   begin
      null;
   end;

   Recording.Stop (Recorder);
   Recording.Snapshot (Recorder, Fast, Fast_Result);
   Recording.Snapshot (Recorder, Slow, Slow_Result);

   Check (Recording.Observed (Fast_Result) = 40, "fast observed count");
   Check (Recording.Observed (Slow_Result) = 40, "slow observed count");
   Check (Recording.Retained (Fast_Result) = 40, "fast retained count");
   Check (Recording.In_Flight (Fast_Result) = 0, "finished spans remain active");
   Check
     (Recording.Metric_Samples (Fast_Result, Flyology_Bench.Wall_Time) = 40,
      "wall samples missing");
   Check
     (Recording.Outcomes (Fast_Result, Recording.Failure) = 2,
      "failure outcomes missing");
   declare
      Seen     : array (Positive range 1 .. 40) of Boolean := (others => False);
      Failures : Natural := 0;
   begin
      for Index in 1 .. Recording.Retained (Fast_Result) loop
         declare
            Observation : constant Natural :=
              Recording.Observation_Id (Fast_Result, Index);
         begin
            Check
              (Observation in Seen'Range and then not Seen (Observation),
               "retained observation identity is not unique");
            Seen (Observation) := True;
            if Recording.Outcome_At (Fast_Result, Index) = Recording.Failure then
               Failures := Failures + 1;
            end if;
            Check
              (Recording.Sample_Metric_Status
                 (Fast_Result, Index, Flyology_Bench.Wall_Time)
                 = Flyology_Bench.Metric_Collected,
               "aligned wall status missing");
            Check
              (Recording.Sample_Metric_Value
                 (Fast_Result, Index, Flyology_Bench.Wall_Time) > 0.0,
               "aligned wall value missing");
         end;
      end loop;
      Check (Failures = 2, "retained outcomes lost their span identity");
   end;
   if Ada.Environment_Variables.Exists ("FLYOLOGY_BENCH_REQUIRE_PERF")
     and then Ada.Environment_Variables.Value
       ("FLYOLOGY_BENCH_REQUIRE_PERF") = "1"
   then
      Check
        (Recording.Metric_Samples
           (Fast_Result, Flyology_Bench.CPU_Cycles) > 0,
         "recorder persistent CPU cycles are unavailable");
      Check
        (Recording.Metric_Samples
           (Fast_Result, Flyology_Bench.Instructions) > 0,
         "recorder persistent instructions are unavailable");
   end if;
   Check
     (Recording.Metric_Statistics
        (Slow_Result, Flyology_Bench.Wall_Time).Median
      > Recording.Metric_Statistics
        (Fast_Result, Flyology_Bench.Wall_Time).Median,
      "recorded distributions are not distinct");

   Recording.Compare_Independent (Fast_Result, Slow_Result, Compared);
   Check
     (Recording.Relative_Change_Percent (Compared) > 0.0,
      "independent comparison direction");

   --  Exercise bounded retention, abandoned spans, and the rule that work
   --  already in flight may finish after the recorder stops accepting work.
   declare
      Bounded : Recording.Recorder
        (Maximum_Benchmarks => 1,
         Retained_Samples   => 10);
      Item    : Recording.Benchmark;
      Result  : Recording.Recorded_Measurement;
   begin
      Recording.Register (Bounded, "bounded", Item);
      Recording.Start
        (Bounded,
         (Metrics   => (Flyology_Bench.Wall_Time => True, others => False),
          Retention => Recording.First_N,
          others    => <>));
      for Index in 1 .. 15 loop
         declare
            Sample : Recording.Span;
         begin
            Recording.Begin_Sample (Bounded, Item, Sample);
            Recording.Finish (Sample);
         end;
      end loop;
      declare
         Unfinished : Recording.Span;
      begin
         Recording.Begin_Sample (Bounded, Item, Unfinished);
      end;
      declare
         Late : Recording.Span;
      begin
         Recording.Begin_Sample (Bounded, Item, Late);
         Recording.Stop (Bounded);
         Recording.Finish (Late);
      end;
      Recording.Snapshot (Bounded, Item, Result);
      Check (Recording.Observed (Result) = 16, "bounded observed count");
      Check (Recording.Retained (Result) = 10, "bounded retained count");
      Check (Recording.Dropped (Result) = 6, "bounded dropped count");
      Check (Recording.Abandoned (Result) = 1, "abandoned span count");
      Check (Recording.In_Flight (Result) = 0, "late span remains active");
   end;

   --  A migrated span must remain in its observation row while the aggregate
   --  axis status reports that only a subset is comparable.
   declare
      Partial : Recording.Recorder
        (Maximum_Benchmarks => 1,
         Retained_Samples   => 10);
      Item   : Recording.Benchmark;
      Result : Recording.Recorded_Measurement;
   begin
      Recording.Register (Partial, "partial thread scope", Item);
      Recording.Start
        (Partial,
         (Metrics =>
            (Flyology_Bench.Wall_Time      => True,
             Flyology_Bench.Thread_CPU_Time => True,
             others => False),
          others => <>));
      declare
         Sample : Recording.Span;
      begin
         Recording.Begin_Sample (Partial, Item, Sample);
         Recording.Finish (Sample);
      end;
      declare
         Shared : Recording.Span;
         protected Gate is
            procedure Release;
            entry Wait;
         private
            Ready : Boolean := False;
         end Gate;
         protected body Gate is
            procedure Release is
            begin
               Ready := True;
            end Release;
            entry Wait when Ready is
            begin
               null;
            end Wait;
         end Gate;
         task Starter;
         task Finisher;
         task body Starter is
         begin
            Recording.Begin_Sample (Partial, Item, Shared);
            Gate.Release;
         end Starter;
         task body Finisher is
         begin
            Gate.Wait;
            Recording.Finish (Shared);
         end Finisher;
      begin
         null;
      end;
      Recording.Stop (Partial);
      Recording.Snapshot (Partial, Item, Result);
      Check
        (Recording.Metric_Status (Result, Flyology_Bench.Thread_CPU_Time)
           = Flyology_Bench.Metric_Partially_Collected,
         "partial thread metric was reported as complete");
      Check
        (Recording.Metric_Samples (Result, Flyology_Bench.Thread_CPU_Time) = 1,
         "partial thread valid count");
      Check
        (Recording.Unavailable_Metric_Samples
           (Result, Flyology_Bench.Thread_CPU_Time) = 1,
         "partial thread unavailable count");
      Check
        (Recording.Scope_Changed_Samples
           (Result, Flyology_Bench.Thread_CPU_Time) = 1,
         "partial thread scope-change count");
      Recording.Compare_Independent (Result, Result, Partial_Compared);
      Check
        (not Recording.Compare_Metric
           (Partial_Compared, Flyology_Bench.Thread_CPU_Time).Available,
         "partial metric entered an independent comparison");
   end;

   --  Independent comparison may be useful for a resource axis without wall
   --  time. Top-level latency fields must remain explicitly unavailable.
   declare
      Resources : Recording.Recorder
        (Maximum_Benchmarks => 2,
         Retained_Samples   => 16);
      type Benchmark_Pair is array (Positive range 1 .. 2) of
        Recording.Benchmark;
      Reference, Contender : Recording.Benchmark;
      Reference_Result, Contender_Result : Recording.Recorded_Measurement;
   begin
      Recording.Register (Resources, "CPU reference", Reference);
      Recording.Register (Resources, "CPU contender", Contender);
      Recording.Start
        (Resources,
         (Metrics =>
            (Flyology_Bench.Process_CPU_Time => True, others => False),
          others => <>));
      for Index in 1 .. 10 loop
         for Item of Benchmark_Pair'(Reference, Contender) loop
            declare
               Sample : Recording.Span;
            begin
               Recording.Begin_Sample (Resources, Item, Sample);
               delay 0.000_1;
               Recording.Finish (Sample);
            end;
         end loop;
      end loop;
      Recording.Stop (Resources);
      Recording.Snapshot (Resources, Reference, Reference_Result);
      Recording.Snapshot (Resources, Contender, Contender_Result);
      Recording.Compare_Independent
        (Reference_Result, Contender_Result, No_Wall_Compared);
      Check
        (not Recording.Wall_Comparison_Available (No_Wall_Compared),
         "CPU-only comparison fabricated wall data");
      Check
        (Recording.Compare_Metric
           (No_Wall_Compared, Flyology_Bench.Process_CPU_Time).Available,
         "CPU-only metric comparison is unavailable");
      begin
         declare
            Unexpected : constant Long_Float :=
              Recording.Speedup (No_Wall_Compared);
         begin
            raise Program_Error with
              "missing wall comparison returned" & Long_Float'Image (Unexpected);
         end;
      exception
         when Constraint_Error =>
            null;
      end;
   end;

   --  Concurrent recorders own separate PMU sessions, and sequentially
   --  created workers must not inherit stale per-thread counter descriptors.
   declare
      First_Recorder : Recording.Recorder
        (Maximum_Benchmarks => 1, Retained_Samples => 16);
      Second_Recorder : Recording.Recorder
        (Maximum_Benchmarks => 1, Retained_Samples => 16);
      First_Item, Second_Item : Recording.Benchmark;
      First_Result, Second_Result : Recording.Recorded_Measurement;
      Accumulator : Interfaces.Unsigned_64 := 1 with Volatile;
      task type Worker;
      task body Worker is
         First_Sample, Second_Sample : Recording.Span;
      begin
         Recording.Begin_Sample (First_Recorder, First_Item, First_Sample);
         for Index in 1 .. 20_000 loop
            Accumulator := Interfaces.Rotate_Left
              (Accumulator xor Interfaces.Unsigned_64 (Index), 3);
         end loop;
         Recording.Finish (First_Sample);
         Recording.Begin_Sample (Second_Recorder, Second_Item, Second_Sample);
         for Index in 1 .. 20_000 loop
            Accumulator := Interfaces.Rotate_Left
              (Accumulator xor Interfaces.Unsigned_64 (Index), 5);
         end loop;
         Recording.Finish (Second_Sample);
      end Worker;
   begin
      Recording.Register (First_Recorder, "first PMU session", First_Item);
      Recording.Register (Second_Recorder, "second PMU session", Second_Item);
      Recording.Start
        (First_Recorder,
         (Metrics => Flyology_Bench.Time_Metrics
            or Flyology_Bench.Linux_Hardware_Metrics,
          others => <>));
      Recording.Start
        (Second_Recorder,
         (Metrics => Flyology_Bench.Time_Metrics
            or Flyology_Bench.Linux_Hardware_Metrics,
          others => <>));
      for Index in 1 .. 12 loop
         declare
            Current : Worker;
         begin
            null;
         end;
      end loop;
      Recording.Stop (First_Recorder);
      Recording.Stop (Second_Recorder);
      Recording.Snapshot (First_Recorder, First_Item, First_Result);
      Recording.Snapshot (Second_Recorder, Second_Item, Second_Result);
      if Ada.Environment_Variables.Exists ("FLYOLOGY_BENCH_REQUIRE_PERF")
        and then Ada.Environment_Variables.Value
          ("FLYOLOGY_BENCH_REQUIRE_PERF") = "1"
      then
         Check
           (Recording.Metric_Status
              (First_Result, Flyology_Bench.CPU_Cycles)
              = Flyology_Bench.Metric_Collected,
            "first concurrent PMU session lost worker samples");
         Check
           (Recording.Metric_Status
              (Second_Result, Flyology_Bench.CPU_Cycles)
              = Flyology_Bench.Metric_Collected,
            "second concurrent PMU session lost worker samples");
      end if;
   end;

   Reporters.Put_Console (Fast_Result, Style => Reporters.Plain);
   Ada.Text_IO.Put_Line ("-- recording machine output begin --");
   Reporters.Put_CSV_Header;
   Reporters.Put_CSV (Fast_Result);
   Reporters.Put_Samples_CSV_Header;
   Reporters.Put_Samples_CSV (Fast_Result);
   Reporters.Put_JSON (Fast_Result);
   Reporters.Put_Comparison_CSV_Header;
   Reporters.Put_Comparison_CSV (Compared);
   Reporters.Put_Comparison_JSON (Compared);
   Reporters.Put_Comparison_JSON (No_Wall_Compared);
   Reporters.Put_Comparison_JSON (Partial_Compared);
   Ada.Text_IO.Put_Line ("-- recording machine output end --");
end Recording_Smoke;
