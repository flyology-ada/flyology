--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Text_IO;
with Flyology_Bench.Internal_Condition_Test_Hooks;
with Flyology_Bench.Internal_Probes;

procedure Flyology_Bench.Internal_Condition_Integration_Smoke is
   package Hooks renames Flyology_Bench.Internal_Condition_Test_Hooks;
   use type Internal_Probes.Host_System;

   Calls : Natural := 0
   with Volatile;
   Work  : Natural := 0
   with Volatile;

   procedure Batch (Iterations : Iteration_Count) is
   begin
      Calls := Calls + Natural (Iterations);
      for Iteration in Iteration_Count range 1 .. Iterations loop
         pragma Unreferenced (Iteration);
         for Spin in 1 .. 64 loop
            pragma Unreferenced (Spin);
            Work := Work + 1;
         end loop;
      end loop;
   end Batch;

   procedure Benchmark is new Measure_Batched (Batch);
   procedure Pair_Benchmark is new Compare_Batched (Batch, Batch);

   type Test_Case is (First_Case, Second_Case);

   procedure Multi_Batch (Which : Test_Case; Iterations : Iteration_Count) is
      pragma Unreferenced (Which);
   begin
      Batch (Iterations);
   end Multi_Batch;

   procedure Multi_Benchmark is new Compare_Many (Test_Case, Multi_Batch);

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   function Policy
     (Response : Condition_Response; Fallback : Condition_Pause_Fallback := Fallback_Observe)
      return Operating_Conditions_Policy is
   begin
      case Response is
         when Observe =>
            return
              (Enabled                    => True,
               Response                   => Observe,
               Require_Nonreduced_Profile => True,
               Require_Profile_Detection  => True,
               Maximum_Thermal_State      => Thermal_State_Fair,
               Require_Thermal_Detection  => True,
               Window                     => 0.010);

         when Fail    =>
            return
              (Enabled                    => True,
               Response                   => Fail,
               Require_Nonreduced_Profile => True,
               Require_Profile_Detection  => True,
               Maximum_Thermal_State      => Thermal_State_Fair,
               Require_Thermal_Detection  => True,
               Window                     => 0.010);

         when Pause   =>
            return
              (Enabled                    => True,
               Response                   => Pause,
               Require_Nonreduced_Profile => True,
               Require_Profile_Detection  => True,
               Maximum_Thermal_State      => Thermal_State_Fair,
               Require_Thermal_Detection  => True,
               Window                     => 0.010,
               Stable_Time                => 0.001,
               Poll_Interval              => 0.001,
               Maximum_Pause_Time         => 0.100,
               Rewarm_Time                => 0.0,
               On_Pause_Timeout           => Fallback);
      end case;
   end Policy;

   function Config
     (Response     : Condition_Response;
      Fallback     : Condition_Pause_Fallback := Fallback_Observe;
      Interference : Boolean := False) return Configuration
   is (Default_Configuration
       with delta
         Warmup_Time          => 0.0,
         Measurement_Time     => 0.000_100,
         Samples              => 10,
         Minimum_Sample_Time  => 0.000_001,
         Maximum_Iterations   => 1,
         Subtract_Timer_Cost  => False,
         Bootstrap_Resamples  => 100,
         Metrics              => Time_Metrics,
         Interference         =>
           (if Interference
            then
              (Enabled                     => True,
               Response                    => Observe,
               Maximum_Foreign_CPU_Percent => 100.0,
               Window                      => 0.001,
               others                      => <>)
            else (others => <>)),
         Operating_Conditions => Policy (Response, Fallback));

begin
   Check (Hooks.Enabled, "condition integration smoke selected disabled hooks");

   if Internal_Probes.Operating_System = Internal_Probes.Darwin then
      --  Intermediate sub-second windows reuse the macOS coarse profile
      --  cache, while the terminal close obtains a fresh value. This keeps
      --  pmset off the hot collection cadence without leaving the final
      --  retained window unjudged.
      Hooks.Reset;
      declare
         Result : Measurement;
      begin
         Benchmark
           ((Config (Observe)
             with delta Operating_Conditions => (Policy (Observe) with delta Window => 0.000_001)),
            Result);
         Check (Hooks.Profile_Read_Count = 4, "intermediate windows bypassed the macOS profile cache");
      end;

      --  Each collection implementation has its own terminal-window call
      --  site. Keep all of them pinned to a fresh coarse profile read.
      Hooks.Reset;
      declare
         Result : Comparison;
      begin
         Pair_Benchmark
           ((Config (Observe)
             with delta Operating_Conditions => (Policy (Observe) with delta Window => 0.000_001)),
            Result);
         Check (Hooks.Profile_Read_Count = 4, "paired terminal window did not force the fourth profile read");
      end;

      for Schedule in Shootout_Schedule_Policy loop
         Hooks.Reset;
         declare
            Result                 : Multi_Comparison;
            Expected_Profile_Reads : constant Natural := (if Schedule = Balanced_Rounds then 4 else 5);
         begin
            Multi_Benchmark
              ((Config (Observe)
                with delta
                  Shootout_Scheduling  => Schedule,
                  Operating_Conditions => (Policy (Observe) with delta Window => 0.000_001)),
               Result);
            Check
              (Hooks.Profile_Read_Count = Expected_Profile_Reads,
               "multi-way terminal windows did not force their profile reads");
         end;
      end loop;

      Hooks.Reset;
      Hooks.Reject_Profile_Read (4);
      declare
         Failed    : Boolean := False;
         Discarded : Measurement;
      begin
         begin
            Benchmark (Config (Fail), Discarded);
         exception
            when Operating_Conditions_Unacceptable =>
               Failed := True;
         end;
         Check (Failed, "terminal forced profile rejection did not fail the run");
         Check (Hooks.Profile_Read_Count = 4, "terminal profile check was not the fourth forced read");
      end;

      --  The post-calibration boundary is also forced. A profile rejection
      --  there must recover and restart calibration instead of carrying a
      --  batch size chosen under rejected conditions into sampling.
      Hooks.Reset;
      Hooks.Reject_Profile_Read (3);
      declare
         Result : Measurement;
         Report : Environment_Report;
      begin
         Benchmark (Config (Pause), Result);
         Report := Environment (Result);
         Check
           (Report.Condition_Pauses = 1 and then Report.Recollected_Units = 0,
            "post-calibration profile recovery did not restart calibration");
         Check
           (Hooks.Profile_Read_Count >= 6, "post-calibration recovery did not obtain fresh profile values");
      end;

      --  A sustained live rejection requires several pause polls. Only entry
      --  to Pause refreshes pmset; later polls keep sampling live process
      --  state while reusing the coarse profile cache.
      Hooks.Reset;
      Hooks.Reject_From_Read (6);
      declare
         Result : Measurement;
         Report : Environment_Report;
      begin
         Benchmark
           ((Config (Pause)
             with delta Operating_Conditions => (Policy (Pause) with delta Maximum_Pause_Time => 0.005)),
            Result);
         Report := Environment (Result);
         Check
           (Report.Condition_Fallback_Used and then Hooks.Read_Count >= 7,
            "persistent live rejection did not exercise repeated pause polls");
         Check (Hooks.Profile_Read_Count = 5, "repeated pause polls bypassed the macOS coarse profile cache");
      end;
   end if;

   --  The same final transition under Pause discards and recollects the full
   --  ten-sample window. Enabling the interference observer exercises the
   --  combined decision path without relying on host load.
   declare
      Baseline_Result : Measurement;
      Baseline_Calls  : Natural;
   begin
      Hooks.Reset;
      Calls := 0;
      Benchmark (Config (Observe, Interference => True), Baseline_Result);
      Baseline_Calls := Calls;

      Hooks.Reset;
      Hooks.Reject_Read (6);
      Calls := 0;
      declare
         Result : Measurement;
         Report : Environment_Report;
      begin
         Benchmark (Config (Pause, Interference => True), Result);
         Report := Environment (Result);
         Check (Samples (Result) = 10, "condition pause changed the retained sample count");
         Check
           (Report.Condition_Pauses = 1
            and then Report.Affected_Units = 10
            and then Report.Recollected_Units = 10,
            "condition pause did not recollect the complete combined-watch window");
         Check
           (Calls >= Baseline_Calls + 10,
            "condition pause reported recollection without rerunning the window");
         Check
           (not Report.Condition_Budget_Expired and then not Report.Condition_Fallback_Used,
            "recovered condition pause incorrectly used its fallback");
         Check (Report.Final_Profile = Profile_Performance, "recollected run retained the rejected profile");
      end;
   end;

   --  Paired comparison treats a pair as one collection unit. Both retained
   --  measurements receive the same report after the complete affected
   --  window is run again.
   declare
      Baseline_Result : Comparison;
      Baseline_Calls  : Natural;
   begin
      Hooks.Reset;
      Calls := 0;
      Pair_Benchmark (Config (Observe), Baseline_Result);
      Baseline_Calls := Calls;

      Hooks.Reset;
      Hooks.Reject_Read (6);
      Calls := 0;
      declare
         Result           : Comparison;
         Reference_Result : Measurement;
         Contender_Result : Measurement;
         Reference_Report : Environment_Report;
         Contender_Report : Environment_Report;
      begin
         Pair_Benchmark (Config (Pause), Result);
         Reference_Result := Reference_Measurement (Result);
         Contender_Result := Contender_Measurement (Result);
         Reference_Report := Environment (Reference_Result);
         Contender_Report := Environment (Contender_Result);
         Check
           (Samples (Reference_Result) = 10
            and then Samples (Contender_Result) = 10
            and then Reference_First_Samples (Result) + Contender_First_Samples (Result) = 10,
            "paired recollection changed retained pair count or order totals");
         Check
           (Reference_Report.Condition_Pauses = 1
            and then Reference_Report.Affected_Units = 10
            and then Reference_Report.Recollected_Units = 10
            and then Contender_Report.Condition_Pauses = 1
            and then Contender_Report.Affected_Units = 10
            and then Contender_Report.Recollected_Units = 10,
            "paired recollection report was not copied to both measurements");
         Check
           (Calls >= Baseline_Calls + 20,
            "paired comparison reported recollection without rerunning every pair");
      end;
   end;

   --  Multi-way comparison shares one condition watch across cases. Exercise
   --  both scheduling branches because they maintain separate rollback code.
   for Schedule in Shootout_Schedule_Policy loop
      declare
         Test_Config     : constant Configuration :=
           (Config (Pause) with delta Shootout_Scheduling => Schedule);
         Observe_Config  : constant Configuration :=
           (Config (Observe) with delta Shootout_Scheduling => Schedule);
         Baseline_Result : Multi_Comparison;
         Baseline_Calls  : Natural;
      begin
         Hooks.Reset;
         Calls := 0;
         Multi_Benchmark (Observe_Config, Baseline_Result);
         Baseline_Calls := Calls;

         Hooks.Reset;
         Hooks.Reject_Read (6);
         Calls := 0;
         declare
            Result         : Multi_Comparison;
            First_Result   : Measurement;
            Second_Result  : Measurement;
            First_Report   : Environment_Report;
            Second_Report  : Environment_Report;
            Expected_Rerun : constant Natural := (if Schedule = Balanced_Rounds then 20 else 10);
         begin
            Multi_Benchmark (Test_Config, Result);
            First_Result := Case_Measurement (Result, 1);
            Second_Result := Case_Measurement (Result, 2);
            First_Report := Environment (First_Result);
            Second_Report := Environment (Second_Result);
            Check
              (Cases (Result) = 2
               and then Samples (First_Result) = 10
               and then Samples (Second_Result) = 10
               and then Shootout_Schedule (Result) = Schedule,
               "multi-way recollection changed retained cases, samples, or schedule");
            Check
              (First_Report.Condition_Pauses = 1
               and then First_Report.Affected_Units = 10
               and then First_Report.Recollected_Units = 10
               and then Second_Report.Condition_Pauses = 1
               and then Second_Report.Affected_Units = 10
               and then Second_Report.Recollected_Units = 10,
               "multi-way recollection report was not copied to every case");
            Check
              (Calls >= Baseline_Calls + Expected_Rerun,
               "multi-way comparison reported recollection without rerunning its window");
         end;
      end;
   end loop;

   --  A calibration rejection must restart calibration after recovery. Two
   --  rejected closing reads require two restarts before sampling can begin.
   Hooks.Reset;
   Hooks.Reject_Read (4);
   Hooks.Reject_Read (8);
   declare
      Result : Measurement;
      Report : Environment_Report;
   begin
      Benchmark (Config (Pause), Result);
      Report := Environment (Result);
      Check
        (Report.Condition_Pauses = 2 and then Report.Recollected_Units = 0,
         "calibration recovery was reported as sample recollection");
      Check (Hooks.Read_Count >= 14, "calibration did not restart after each condition recovery");
   end;

   --  Linux event and duration counters are cumulative history, not a live
   --  throttle-state signal. An event increase followed by a flat duration
   --  cannot prove cooling, even after Stable_Time, so Pause must consume its
   --  budget and apply the configured fallback.
   Hooks.Reset;
   Hooks.Begin_Throttle_Event (6);
   declare
      Result : Measurement;
      Report : Environment_Report;
   begin
      Benchmark
        ((Config (Pause)
          with delta
            Operating_Conditions =>
              (Policy (Pause)
               with delta Stable_Time => 0.001, Poll_Interval => 0.001, Maximum_Pause_Time => 0.004)),
         Result);
      Report := Environment (Result);
      Check
        (Report.Condition_Pauses = 1
         and then Report.Condition_Budget_Expired
         and then Report.Condition_Fallback_Used,
         "flat cumulative throttle duration was mistaken for live cooling");
      Check
        (Report.Affected_Units = 10 and then Report.Recollected_Units = 0,
         "unresolved throttle event did not retain the fallback window");
   end;

   --  Two pauses share one cumulative budget. The first recovers after using
   --  most of it; the second has less than one stable interval left and must
   --  use the Observe fallback while retaining its affected one-sample window.
   Hooks.Reset;
   Hooks.Reject_Read (6);
   Hooks.Reject_Read (12);
   Hooks.Delay_Read (7, 1);
   Hooks.Delay_Read (8, 1);
   Hooks.Delay_Read (13, 4);
   Hooks.Delay_Read (14, 4);
   declare
      Result : Measurement;
      Report : Environment_Report;
   begin
      Benchmark
        ((Config (Pause)
          with delta
            Operating_Conditions =>
              (Enabled                    => True,
               Response                   => Pause,
               Require_Nonreduced_Profile => True,
               Require_Profile_Detection  => True,
               Maximum_Thermal_State      => Thermal_State_Fair,
               Require_Thermal_Detection  => True,
               Window                     => 0.000_001,
               Stable_Time                => 0.002,
               Poll_Interval              => 0.001,
               Maximum_Pause_Time         => 0.010,
               Rewarm_Time                => 0.0,
               On_Pause_Timeout           => Fallback_Observe)),
         Result);
      Report := Environment (Result);
      Check
        (Report.Condition_Pauses = 2
         and then Report.Condition_Budget_Expired
         and then Report.Condition_Fallback_Used,
         "separate pauses did not consume one cumulative budget");
      Check
        (Report.Affected_Units = 2 and then Report.Recollected_Units = 1,
         "cumulative fallback did not distinguish recollected and retained windows");
   end;

   --  The same exhaustion under Fallback_Fail must not return a measurement.
   Hooks.Reset;
   Hooks.Reject_From_Read (6);
   declare
      Failed    : Boolean := False;
      Discarded : Measurement;
   begin
      begin
         Benchmark (Config (Pause, Fallback_Fail), Discarded);
      exception
         when Operating_Conditions_Unacceptable =>
            Failed := True;
      end;
      Check (Failed, "persistent condition ignored the Fail pause fallback");
   end;

   Ada.Text_IO.Put_Line ("flyology_bench condition integration smoke: PASS");
end Flyology_Bench.Internal_Condition_Integration_Smoke;
