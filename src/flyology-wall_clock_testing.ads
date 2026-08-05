--  Test-only wall-clock observation control. Production timer sampling does
--  not reference this unit when FLYOLOGY_WALL_CLOCK_TEST_HOOKS is false.
private package Flyology.Wall_Clock_Testing is
   procedure Set_Offset (Value : Duration);
   function Offset return Duration;
   --  Coordinate a synthetic backstep after Wait_Until captures its baseline.
   procedure Reset_Samples;
   procedure Note_Sample;
   procedure Wait_For_Baseline;
end Flyology.Wall_Clock_Testing;
