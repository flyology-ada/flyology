--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Text_IO;
with Flyology_Bench.Internal_Condition_Policy;
with Flyology_Bench.Internal_Conditions;
with Flyology_Bench.Internal_Window_Policy;

procedure Flyology_Bench.Internal_Condition_Policy_Smoke is
   package Policy renames Flyology_Bench.Internal_Condition_Policy;
   package Window_Policy renames Flyology_Bench.Internal_Window_Policy;
   use type Policy.Counter_Evidence;
   use type Policy.Policy_Action;

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   Required : constant Policy.Requirements :=
     (Require_Nonreduced_Profile => True,
      Require_Profile_Detection  => True,
      Maximum_Thermal_State      => Thermal_State_Fair,
      Require_Thermal_Detection  => True);
   Good     : constant Policy.State :=
     (Profile_Availability     => Condition_Available,
      Profile                  => Profile_Performance,
      Low_Power_Availability   => Condition_Available,
      Low_Power_Mode           => Low_Power_Mode_Disabled,
      Process_Profile_Avail    => Condition_Available,
      Process_Profile          => Process_Profile_Default,
      Thermal_Availability     => Condition_Available,
      Thermal_State            => Thermal_State_Nominal,
      Degradation_Availability => Condition_Available,
      Degradation              => Not_Degraded,
      Throttle_Availability    => Condition_Available,
      Throttle_Time_Avail      => Condition_Available);
   Stable   : constant Policy.Counter_Evidence :=
     (Availability => Condition_Available, Increased => False, Increase => 0, Discontinuous => False);
begin
   Check
     (Window_Policy.Required_Window (0.010, 0.002) = 0.010,
      "condition window shortened an interference window");
   Check
     (Window_Policy.Required_Window (0.002, 0.010) = 0.010,
      "interference window shortened a condition window");
   Check
     (Window_Policy.Required_Window (0.0, 0.010) = 0.010
      and then Window_Policy.Required_Window (0.010, 0.0) = 0.010,
      "a disabled watch changed the required window");
   Check
     (not Policy.Unacceptable (Required, Good, Process_Profile_Default, Stable, Stable),
      "accepted normalized conditions were rejected");
   Check
     (Policy.Unacceptable
        (Required,
         (Good with delta Profile_Availability => Condition_Unavailable),
         Process_Profile_Default,
         Stable,
         Stable),
      "required unknown profile was accepted");
   Check
     (Policy.Unacceptable
        (Required, (Good with delta Profile => Profile_Reduced), Process_Profile_Default, Stable, Stable),
      "reduced profile was accepted");
   Check
     (Policy.Unacceptable
        (Required,
         (Good with delta Low_Power_Mode => Low_Power_Mode_Enabled),
         Process_Profile_Default,
         Stable,
         Stable),
      "enabled low-power mode was accepted");
   Check
     (Policy.Unacceptable
        (Required,
         (Good with delta Thermal_State => Thermal_State_Serious),
         Process_Profile_Default,
         Stable,
         Stable),
      "thermal pressure over the threshold was accepted");
   Check
     (Policy.Unacceptable
        (Required,
         (Good with delta Degradation => High_Operating_Temperature),
         Process_Profile_Default,
         Stable,
         Stable),
      "reported performance degradation was accepted");
   Check
     (Policy.Window_Unacceptable
        (Policy.Unacceptable
           (Required,
            (Good with delta Thermal_State => Thermal_State_Serious),
            Process_Profile_Default,
            Stable,
            Stable),
         Policy.Unacceptable (Required, Good, Process_Profile_Default, Stable, Stable)),
      "bad opening condition followed by a clean close was accepted");
   Check
     (Policy.Window_Unacceptable
        (Policy.Unacceptable
           (Required,
            (Good with delta Profile_Availability => Condition_Unavailable),
            Process_Profile_Default,
            Stable,
            Stable),
         Policy.Unacceptable (Required, Good, Process_Profile_Default, Stable, Stable)),
      "unavailable opening detector followed by an available close was accepted");
   Check
     (Policy.Unacceptable (Required, Good, Process_Profile_Sustained, Stable, Stable),
      "process-profile change was accepted");
   Check
     (Policy.Unacceptable
        (Required,
         Good,
         Process_Profile_Default,
         (Availability => Condition_Available, Increased => True, Increase => 1, Discontinuous => False),
         Stable),
      "thermal throttle increment was accepted");
   Check
     (Policy.Unacceptable
        (Required,
         Good,
         Process_Profile_Default,
         Stable,
         (Availability => Condition_Available, Increased => True, Increase => 1, Discontinuous => False)),
      "thermal throttle duration was accepted");
   Check
     (Policy.Compare_Counter
        ((Availability => Condition_Available, Value => 7), (Availability => Condition_Available, Value => 3))
      = (Availability => Condition_Unavailable, Increased => False, Increase => 0, Discontinuous => True),
      "counter reset was interpreted as an increase");
   Check
     (Policy.Compare_Counter
        ((Availability => Condition_Available, Value => 3), (Availability => Condition_Available, Value => 7))
      = (Availability => Condition_Available, Increased => True, Increase => 4, Discontinuous => False),
      "counter increase was not retained");
   Check
     (Policy.Unacceptable
        (Required,
         Good,
         Process_Profile_Default,
         (Availability => Condition_Unavailable, Increased => False, Increase => 0, Discontinuous => True),
         Stable),
      "counter discontinuity was accepted");
   Check
     (Policy.Merge_Low_Power_Worst (Low_Power_Mode_Unknown, Low_Power_Mode_Disabled)
      = Low_Power_Mode_Disabled,
      "first available low-power state did not initialize the worst state");
   Check
     (Policy.Merge_Low_Power_Worst (Low_Power_Mode_Enabled, Low_Power_Mode_Disabled) = Low_Power_Mode_Enabled,
      "later clean low-power state erased an earlier enabled state");
   Check
     (Policy.Merge_Degradation_Worst (Degradation_Unknown, Not_Degraded) = Not_Degraded,
      "first available degradation state did not initialize the worst state");
   Check
     (Policy.Merge_Degradation_Worst (High_Operating_Temperature, Not_Degraded) = High_Operating_Temperature,
      "later clean degradation state erased an earlier degradation");
   Check
     (Policy.Action_For (Observe, True) = Policy.Policy_Accept
      and then Policy.Action_For (Pause, True) = Policy.Policy_Pause
      and then Policy.Action_For (Fail, True) = Policy.Policy_Fail,
      "condition response ordering changed");
   Check
     (Policy.Timeout_Action (Fallback_Observe) = Policy.Policy_Accept
      and then Policy.Timeout_Action (Fallback_Fail) = Policy.Policy_Fail,
      "pause fallback action changed");
   declare
      Continuity          : Internal_Conditions.Throttle_Continuity;
      Event_Discontinuous : Boolean := False;
      Time_Discontinuous  : Boolean := False;
   begin
      Internal_Conditions.Observe_Throttle_Source
        (Continuity, 1, 0, True, 7, True, 10, Event_Discontinuous, Time_Discontinuous);
      Internal_Conditions.Observe_Throttle_Source
        (Continuity, 2, 1, True, 3, True, 5, Event_Discontinuous, Time_Discontinuous);
      Internal_Conditions.Complete_Throttle_Observation
        (Continuity, 2, Event_Discontinuous, Time_Discontinuous);
      Check (not Event_Discontinuous and then not Time_Discontinuous, "initial throttle sample failed");

      Internal_Conditions.Observe_Throttle_Source
        (Continuity, 1, 0, True, 2, True, 10, Event_Discontinuous, Time_Discontinuous);
      Internal_Conditions.Observe_Throttle_Source
        (Continuity, 2, 1, True, 12, True, 5, Event_Discontinuous, Time_Discontinuous);
      Internal_Conditions.Complete_Throttle_Observation
        (Continuity, 2, Event_Discontinuous, Time_Discontinuous);
      Check (Event_Discontinuous, "one throttle-domain reset was hidden by another domain's increase");

      Event_Discontinuous := False;
      Time_Discontinuous := False;
      Internal_Conditions.Observe_Throttle_Source
        (Continuity, 1, 0, True, 3, True, 11, Event_Discontinuous, Time_Discontinuous);
      Internal_Conditions.Observe_Throttle_Source
        (Continuity, 2, 1, True, 13, True, 6, Event_Discontinuous, Time_Discontinuous);
      Internal_Conditions.Complete_Throttle_Observation
        (Continuity, 2, Event_Discontinuous, Time_Discontinuous);
      Check
        (not Event_Discontinuous and then not Time_Discontinuous, "monotonic throttle domains were rejected");

      Internal_Conditions.Observe_Throttle_Source
        (Continuity, 1, 0, True, 4, True, 12, Event_Discontinuous, Time_Discontinuous);
      Internal_Conditions.Observe_Throttle_Source
        (Continuity, 2, 1, True, 14, False, 0, Event_Discontinuous, Time_Discontinuous);
      Internal_Conditions.Complete_Throttle_Observation
        (Continuity, 2, Event_Discontinuous, Time_Discontinuous);
      Check (Time_Discontinuous, "throttle-time availability loss was accepted");

      Event_Discontinuous := False;
      Time_Discontinuous := False;
      Internal_Conditions.Observe_Throttle_Source
        (Continuity, 1, 0, True, 5, True, 13, Event_Discontinuous, Time_Discontinuous);
      Internal_Conditions.Complete_Throttle_Observation
        (Continuity, 1, Event_Discontinuous, Time_Discontinuous);
      Check (Event_Discontinuous and then Time_Discontinuous, "throttle-source topology change was accepted");
      Check
        (Internal_Conditions.Throttle_Continuity'Size <= 40 * 1_024 * 8,
         "throttle continuity state exceeded the compact bound");
   end;

   Ada.Text_IO.Put_Line ("flyology_bench condition policy smoke: PASS");
end Flyology_Bench.Internal_Condition_Policy_Smoke;
