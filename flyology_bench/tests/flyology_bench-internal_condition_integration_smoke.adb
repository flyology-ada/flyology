--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Text_IO;
with Flyology_Bench.Internal_Condition_Test_Hooks;

procedure Flyology_Bench.Internal_Condition_Integration_Smoke is
   package Hooks renames Flyology_Bench.Internal_Condition_Test_Hooks;

   Calls : Natural := 0
   with Volatile;

   procedure Batch (Iterations : Iteration_Count) is
   begin
      Calls := Calls + Natural (Iterations);
   end Batch;

   procedure Benchmark is new Measure_Batched (Batch);

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   function Policy
     (Response : Condition_Response;
      Fallback : Condition_Pause_Fallback := Fallback_Observe)
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
               Maximum_Pause_Time         => 0.010,
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
   Check
     (Hooks.Enabled, "condition integration smoke selected disabled hooks");

   --  On macOS, only the forced profile read at the closing boundary can see
   --  this sub-second transition. Fail must act on it before finalization.
   Hooks.Reset;
   Hooks.Reject_Profile_Read (3);
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
      Check (Failed, "final forced profile rejection did not fail the run");
      Check
        (Hooks.Profile_Read_Count = 3,
         "final profile check was not the third forced read");
   end;

   --  The same final transition under Pause discards and recollects the full
   --  ten-sample window. Enabling the interference observer exercises the
   --  combined decision path without relying on host load.
   Hooks.Reset;
   Hooks.Reject_Profile_Read (3);
   declare
      Result : Measurement;
      Report : Environment_Report;
   begin
      Benchmark (Config (Pause, Interference => True), Result);
      Report := Environment (Result);
      Check
        (Samples (Result) = 10,
         "profile pause changed the retained sample count");
      Check
        (Report.Condition_Pauses = 1
         and then Report.Affected_Units = 10
         and then Report.Recollected_Units = 10,
         "profile pause did not recollect the complete combined-watch window");
      Check
        (not Report.Condition_Budget_Expired
         and then not Report.Condition_Fallback_Used,
         "recovered profile pause incorrectly used its fallback");
      Check
        (Report.Final_Profile = Profile_Performance,
         "recollected run retained the reduced profile");
   end;

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
      Check
        (Hooks.Read_Count >= 14,
         "calibration did not restart after each condition recovery");
   end;

   --  Two pauses share one cumulative budget. The first recovers after using
   --  most of it; the second has less than one stable interval left and must
   --  use the Observe fallback while retaining its affected one-sample window.
   Hooks.Reset;
   Hooks.Reject_Read (6);
   Hooks.Reject_Read (12);
   Hooks.Delay_Read (7, 1);
   Hooks.Delay_Read (8, 1);
   Hooks.Delay_Read (13, 1);
   Hooks.Delay_Read (14, 1);
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
               Maximum_Pause_Time         => 0.005,
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
