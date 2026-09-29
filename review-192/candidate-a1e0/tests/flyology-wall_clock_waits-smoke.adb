with Ada.Calendar;
with Flyology.IO.Timers;

procedure Flyology.Wall_Clock_Waits.Smoke is
   Source        : Flyology.Wall_Clock_Waits.Source;
   Clock_Changed : Boolean;
begin
   Flyology.Wall_Clock_Waits.Open (Source);

   --  This target is farther from the present than Duration can represent on
   --  nanosecond Duration targets. Arming must use the split civil timestamp
   --  and a bounded native probe rather than subtracting the whole interval.
   Clock_Changed :=
     Flyology.Wall_Clock_Waits.Arm (Source, Ada.Calendar.Time_Of (2399, 12, 31, 0.0), Maximum_Slice => 0.010);
   pragma Unreferenced (Clock_Changed);
   Flyology.IO.Timers.Sleep_For (0.0);
end Flyology.Wall_Clock_Waits.Smoke;
