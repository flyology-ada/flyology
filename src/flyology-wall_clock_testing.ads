--  Test-only wall-clock observation control. Production timer sampling does
--  not reference this unit when FLYOLOGY_WALL_CLOCK_TEST_HOOKS is false.
private package Flyology.Wall_Clock_Testing is
   procedure Set_Offset (Value : Duration);
   function Offset return Duration;
   --  Coordinate a synthetic backstep after Wait_Until captures its baseline.
   procedure Reset_Samples (Pause_For_Offset : Boolean := True);
   procedure Note_Sample;
   procedure Wait_For_Baseline;
   --  Widen every steady-clock bracket without descheduling the test task.
   procedure Set_Sample_Bracket (Value : Duration)
     with Pre => Value >= 0.0;
   procedure Reset_Sample_Bracket;
   procedure Note_Sample_Attempt;
   function Sample_Bracket return Duration;
   function Sample_Attempts return Natural;
   --  Force one native poll retry while advancing only the steady test clock
   --  and the independent synthetic wall clock.
   procedure Configure_IO_Retry
     (Steady_Advance  : Duration;
      Wall_Adjustment : Duration)
     with Pre => Steady_Advance >= 0.0;
   procedure Reset_IO_Retry;
   function IO_Retry_Count return Natural;
   --  Control and inspect the native target-relative timer arm. These seams
   --  are linked only when FLYOLOGY_WALL_CLOCK_TEST_HOOKS is true.
   procedure Set_Native_Remaining (Value : Duration)
     with Pre => Value >= 0.0;
   procedure Reset_Native_Remaining;
   function Last_Native_Arm return Duration;
   function Uses_Native_Relative_Timer return Boolean;
   procedure Set_Native_Consume_EINTR (Count : Natural);
   function Native_Consume_EINTR_Remaining return Natural;
end Flyology.Wall_Clock_Testing;
