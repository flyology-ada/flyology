with Ada.Calendar;
with Ada.Real_Time;

--  Exposes lane-neutral timer waits through standard Ada delay semantics.
--
--  Example:
--
--     Flyology.IO.Timers.Sleep_For (0.010);
package Flyology.IO.Timers is

   --  Default amount by which wall-clock progress may lag monotonic progress
   --  without being reported as a backward adjustment.
   Default_Backstep_Tolerance : constant Duration := 0.001;

   --  Terminal reason for a wall-clock wait.
   --  @enum Target_Reached The wall clock was observed at or beyond the target
   --  @enum Clock_Moved_Backward The wall clock lost more time than tolerated
   type Wall_Clock_Wait_Outcome is
     (Target_Reached, Clock_Moved_Backward);

   --  Result of a wall-clock wait.
   --  @field Outcome Why the wait returned
   --  @field Observed_Time Wall-clock sample used for the terminal decision
   --  @field Backward_Adjustment Estimated lost wall-clock progress in
   --     seconds; zero when Outcome is Target_Reached
   type Wall_Clock_Wait_Result is record
      Outcome             : Wall_Clock_Wait_Outcome;
      Observed_Time       : Ada.Calendar.Time;
      Backward_Adjustment : Duration;
   end record;

   --  Wait for Interval seconds. A nonpositive interval is one `delay 0.0`
   --  yield. A lightweight task suspends on its event loop; a native task uses
   --  the runtime's native delay wait and blocks that task's thread. The
   --  monotonic clock and both wait paths pause during system sleep.
   --  @param Interval Relative delay in seconds
   procedure Sleep_For (Interval : Duration);
   --  Wait until the monotonic real-time Deadline. A past deadline returns at
   --  the next scheduling point. Lane blocking and system-sleep behavior match
   --  Sleep_For.
   --  @param Deadline Absolute Ada.Real_Time deadline
   procedure Sleep_Until (Deadline : Ada.Real_Time.Time);

   --  Wait until the adjustable wall clock reaches Target. A forward clock
   --  change may complete the wait early. A backward change larger than
   --  Backstep_Tolerance returns Clock_Moved_Backward so that the caller can
   --  revalidate its schedule; smaller changes are treated as jitter and the
   --  wait is rearmed. The comparison uses monotonic elapsed time and
   --  therefore detects a backstep even when successive wall-clock samples
   --  still increase. Steady reads bracket each wall read; broad brackets are
   --  retried, brackets wider than one second are rejected, and classification
   --  uses the least elapsed time allowed by the accepted brackets. Linux uses
   --  cancel-on-clock-set readiness. Darwin pairs clock-set notification with
   --  a relative monotonic timer and samples the wall clock in at-most-one-
   --  second active-time slices that continue after resume, bounding a missed
   --  notification's active-time detection latency apart from normal task-
   --  scheduling delay.
   --  A lightweight task suspends on its event loop; a native task blocks only
   --  its pthread. The steady clock and waits pause during system sleep, and
   --  the operation does not wake a suspended computer.
   --  @param Target Absolute Ada.Calendar wall-clock target
   --  @param Backstep_Tolerance Permitted lost wall-clock progress in seconds
   --  @return Terminal outcome, observation, and estimated backward adjustment
   --  @exception Flyology.IO.Device_Error Clock sampling, timer setup, or
   --     waiting fails
   function Wait_Until
     (Target             : Ada.Calendar.Time;
      Backstep_Tolerance : Duration := Default_Backstep_Tolerance)
      return Wall_Clock_Wait_Result
   with Pre => Backstep_Tolerance >= 0.0;

end Flyology.IO.Timers;
