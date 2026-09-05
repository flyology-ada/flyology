--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

private package Flyology_Bench.Internal_Condition_Policy
with SPARK_Mode => On
is
   use type Interfaces.Unsigned_64;

   type Requirements is record
      Require_Nonreduced_Profile : Boolean;
      Require_Profile_Detection  : Boolean;
      Maximum_Thermal_State      : Thermal_State_Threshold;
      Require_Thermal_Detection  : Boolean;
   end record;

   type State is record
      Profile_Availability     : Condition_Availability;
      Profile                  : Performance_Profile;
      Low_Power_Availability   : Condition_Availability;
      Low_Power_Mode           : Low_Power_Mode_State;
      Process_Profile_Avail    : Condition_Availability;
      Process_Profile          : Process_Performance_Profile;
      Thermal_Availability     : Condition_Availability;
      Thermal_State            : Host_Thermal_State;
      Degradation_Availability : Condition_Availability;
      Degradation              : Performance_Degradation;
      Throttle_Availability    : Condition_Availability;
      Throttle_Time_Avail      : Condition_Availability;
   end record;

   type Counter_Observation is record
      Availability : Condition_Availability;
      Value        : Interfaces.Unsigned_64;
   end record;

   type Counter_Evidence is record
      Availability : Condition_Availability;
      Increased    : Boolean;
      Increase     : Interfaces.Unsigned_64;
      Discontinuous : Boolean;
   end record;

   --  A reset/decrease is loss of continuity, never a modular increase.
   function Compare_Counter
     (Before : Counter_Observation; After : Counter_Observation) return Counter_Evidence
   with
     Post =>
       (if Before.Availability /= Condition_Available
        then
          Compare_Counter'Result =
            (Availability => Condition_Unavailable,
             Increased => False,
             Increase => 0,
             Discontinuous => False)
        elsif After.Availability /= Condition_Available or else After.Value < Before.Value
        then
          Compare_Counter'Result =
            (Availability => Condition_Unavailable,
             Increased => False,
             Increase => 0,
             Discontinuous => True)
        else
          Compare_Counter'Result.Availability = Condition_Available
          and then Compare_Counter'Result.Increase = After.Value - Before.Value
          and then Compare_Counter'Result.Increased = (After.Value > Before.Value)
          and then not Compare_Counter'Result.Discontinuous);

   --  Unknown can precede the first successful detector read. Accumulation
   --  therefore initializes from the first known value, then retains the
   --  worst state observed at any later boundary.
   function Merge_Low_Power_Worst
     (Previous : Low_Power_Mode_State; Current : Low_Power_Mode_State) return Low_Power_Mode_State
   is
     (if Current = Low_Power_Mode_Unknown
      then Previous
      elsif Previous = Low_Power_Mode_Unknown
      then Current
      elsif Previous = Low_Power_Mode_Enabled or else Current = Low_Power_Mode_Enabled
      then Low_Power_Mode_Enabled
      else Low_Power_Mode_Disabled);

   function Merge_Degradation_Worst
     (Previous : Performance_Degradation; Current : Performance_Degradation)
      return Performance_Degradation
   is
     (if Current = Degradation_Unknown
      then Previous
      elsif Previous = Degradation_Unknown or else Current /= Not_Degraded
      then Current
      else Previous);

   function Unacceptable
     (Required         : Requirements;
      Current          : State;
      Baseline_Profile : Process_Performance_Profile;
      Throttle_Events  : Counter_Evidence;
      Throttle_Time    : Counter_Evidence) return Boolean
   is
     ((Required.Require_Profile_Detection
       and then Current.Profile_Availability /= Condition_Available)
      or else
        (Required.Require_Nonreduced_Profile
         and then
           (Current.Profile = Profile_Reduced
            or else Current.Low_Power_Mode = Low_Power_Mode_Enabled))
      or else
        (Required.Require_Thermal_Detection
         and then Current.Thermal_Availability /= Condition_Available
         and then Current.Throttle_Availability /= Condition_Available
         and then Current.Throttle_Time_Avail /= Condition_Available
         and then Current.Degradation_Availability /= Condition_Available)
      or else
        (Current.Thermal_Availability = Condition_Available
         and then Current.Thermal_State > Required.Maximum_Thermal_State)
      or else
        (Current.Degradation_Availability = Condition_Available
         and then Current.Degradation /= Not_Degraded)
      or else Throttle_Events.Increased
      or else Throttle_Time.Increased
      or else Throttle_Events.Discontinuous
      or else Throttle_Time.Discontinuous
      or else
        (Baseline_Profile /= Process_Profile_Unknown
         and then Current.Process_Profile_Avail = Condition_Available
         and then Current.Process_Profile /= Baseline_Profile));

   --  Both boundary snapshots belong to the measured window. A transient
   --  present at either edge rejects the whole window.
   function Window_Unacceptable
     (Opening_Unacceptable : Boolean; Closing_Unacceptable : Boolean) return Boolean
   is (Opening_Unacceptable or else Closing_Unacceptable);

   type Policy_Action is (Policy_Accept, Policy_Pause, Policy_Fail);

   function Action_For (Mode : Operating_Conditions_Mode; Rejected : Boolean) return Policy_Action
   is (if not Rejected
       then Policy_Accept
       elsif Mode in Disabled | Observe
       then Policy_Accept
       elsif Mode = Pause
       then Policy_Pause
       else Policy_Fail);

   function Timeout_Action (Fallback : Condition_Pause_Fallback) return Policy_Action
   is (if Fallback = Fallback_Observe then Policy_Accept else Policy_Fail);

end Flyology_Bench.Internal_Condition_Policy;
