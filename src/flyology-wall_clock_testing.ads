--  Test-only wall-clock observation control. Production timer sampling does
--  not reference this unit when FLYOLOGY_WALL_CLOCK_TEST_HOOKS is false.
private package Flyology.Wall_Clock_Testing is
   procedure Set_Offset (Value : Duration);
   function Offset return Duration;
   --  Coordinate a synthetic backstep after Wait_Until captures its baseline.
   procedure Reset_Samples;
   procedure Note_Sample;
   procedure Wait_For_Baseline;
   --  Control and inspect the native target-relative timer arm. These seams
   --  are linked only when FLYOLOGY_WALL_CLOCK_TEST_HOOKS is true.
   procedure Set_Native_Remaining (Value : Duration)
     with Pre => Value >= 0.0;
   procedure Reset_Native_Remaining;
   function Last_Native_Arm return Duration;
   function Uses_Native_Relative_Timer return Boolean;
end Flyology.Wall_Clock_Testing;
