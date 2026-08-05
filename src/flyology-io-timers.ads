with Ada.Calendar;
with Ada.Real_Time;
private with Flyology.Timer_Set_Policy;

--  Exposes lane-neutral timer waits through standard Ada delay semantics.
--
--  Example:
--
--     Flyology.IO.Timers.Sleep_For (0.010);
package Flyology.IO.Timers is

   --  Stable caller-selected identity for one slot in a Timer_Set.
   subtype Timer_Id is Positive;

   --  Caller-indexed monotonic deadlines used to replace a complete timer
   --  set. Array indexes become the timer ids reported after activation.
   type Deadline_Array is array (Timer_Id range <>) of Ada.Real_Time.Time;

   --  Bounded list of timer ids activated by one Wait_Next call.
   type Timer_Id_Array is array (Positive range <>) of Timer_Id;

   --  Every timer activated by one monotonic-clock sample. Only Ids
   --  (1 .. Count) are defined; callers must not depend on their order.
   --  @field Capacity Maximum number of ids in this batch
   --  @field Count Number of defined entries in Ids
   --  @field Ids Activated timer identities
   type Activation_Batch (Capacity : Positive) is record
      Count : Natural := 0;
      Ids   : Timer_Id_Array (1 .. Capacity) := (others => Timer_Id'First);
   end record;

   --  Terminal reason for a bounded Timer_Set wait.
   --  @enum Timers_Activated Activated contains every timer due at the
   --     operation's terminal monotonic-clock sample
   --  @enum Wait_Timed_Out No timer was due by the timeout deadline
   type Timer_Wait_Outcome is (Timers_Activated, Wait_Timed_Out);

   --  Bounded, caller-owned collection of monotonic timers. The object is not
   --  task safe: one task must serialize Arm, Replace, Cancel, and Wait_Next.
   --  Each arm is one-shot and Wait_Next disarms it when reported. The object
   --  allocates no storage after declaration and registers only its earliest
   --  pending deadline with the calling task's normal timer path.
   --  @field Capacity Maximum number of caller-selected timer ids
   type Timer_Set (Capacity : Positive) is limited private;

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

   --  Arm or reschedule one slot. A deadline at or before the next clock
   --  sample is returned by the next Wait_Next without an additional sleep.
   --  Re-arming an already armed id replaces its pending deadline.
   --  @param Timers Timer collection to update
   --  @param Id Caller-selected slot in 1 .. Timers.Capacity
   --  @param Deadline Absolute monotonic deadline
   procedure Arm
     (Timers   : in out Timer_Set;
      Id       : Timer_Id;
      Deadline : Ada.Real_Time.Time)
   with Pre => Id <= Timers.Capacity;

   --  Replace the complete collection with the supplied deadline array.
   --  Existing arms are cancelled first. Deadlines must use a one-based range
   --  no longer than Timers.Capacity; each array index becomes its timer id.
   --  An empty array leaves the collection empty.
   --  @param Timers Timer collection to replace
   --  @param Deadlines New one-shot monotonic deadlines
   procedure Replace
     (Timers    : in out Timer_Set;
      Deadlines : Deadline_Array)
   with Pre =>
     Deadlines'First = 1 and then Deadlines'Length <= Timers.Capacity;

   --  Idempotently disarm one slot.
   --  @param Timers Timer collection to update
   --  @param Id Caller-selected slot in 1 .. Timers.Capacity
   procedure Cancel
     (Timers : in out Timer_Set;
      Id     : Timer_Id)
   with Pre => Id <= Timers.Capacity;

   --  Report whether one slot is currently armed.
   --  @param Timers Timer collection to inspect
   --  @param Id Caller-selected slot in 1 .. Timers.Capacity
   --  @return True until cancellation, replacement, or activation delivery
   function Is_Armed
     (Timers : Timer_Set;
      Id     : Timer_Id) return Boolean
   with Pre => Id <= Timers.Capacity;

   --  Return the number of currently armed timers.
   --  @param Timers Timer collection to inspect
   --  @return Armed slot count
   function Armed_Count (Timers : Timer_Set) return Natural;

   --  Wait for and consume the next nonempty activation batch. All timers due
   --  at one monotonic-clock sample are returned and disarmed together. A
   --  timer that passes after that sample remains armed, so the next call
   --  returns it before sleeping; processing one batch therefore cannot lose
   --  later expirations. Activated.Capacity must equal Timers.Capacity.
   --  A lightweight caller suspends only its fiber; a native caller blocks
   --  only its pthread. The wait and clock pause during system sleep.
   --  @param Timers Nonempty timer collection to wait on and update
   --  @param Activated Complete set of ids due at the operation's clock sample
   procedure Wait_Next
     (Timers    : in out Timer_Set;
      Activated : out Activation_Batch)
   with Pre =>
     Armed_Count (Timers) > 0
     and then Activated.Capacity = Timers.Capacity,
        Post => Activated.Count in 1 .. Activated.Capacity;

   --  Wait for the next activation batch for at most Timeout active monotonic
   --  seconds. A zero timeout performs one clock sample without sleeping.
   --  Timers due at the terminal sample take precedence over timeout and are
   --  returned normally. On Wait_Timed_Out, Activated.Count is zero and every
   --  timer remains armed for a later call. The timeout pauses during system
   --  sleep, matching the timer deadlines and both task lanes.
   --  @param Timers Nonempty timer collection to wait on and update
   --  @param Activated Complete due set, or an empty batch on timeout
   --  @param Timeout Maximum active monotonic wait in seconds
   --  @return Whether timers activated or the bounded wait expired
   function Wait_Next
     (Timers    : in out Timer_Set;
      Activated : out Activation_Batch;
      Timeout   : Duration) return Timer_Wait_Outcome
   with Pre =>
     Armed_Count (Timers) > 0
     and then Activated.Capacity = Timers.Capacity
     and then Timeout >= 0.0,
        Post =>
          (if Wait_Next'Result = Timers_Activated then
              Activated.Count in 1 .. Activated.Capacity
           else Activated.Count = 0);

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

private
   type Timer_Set (Capacity : Positive) is limited record
      State : Flyology.Timer_Set_Policy.Timer_State (Capacity);
   end record;

end Flyology.IO.Timers;
