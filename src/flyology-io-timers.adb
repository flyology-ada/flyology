with Flyology.Wall_Clock_Policy;
with Flyology.Wall_Clock_Waits;
#if FLYOLOGY_WALL_CLOCK_TEST_HOOKS then
with Flyology.Wall_Clock_Testing;
#end if;

package body Flyology.IO.Timers is
   use type Ada.Calendar.Time;
   use type Ada.Real_Time.Time;
   use type Ada.Real_Time.Time_Span;

   Maximum_Wait_Slice  : constant Duration := 86_400.0;
   Fallback_Wait_Slice : constant Duration := 1.0;

   type Clock_Sample is record
      Wall   : Ada.Calendar.Time;
      Steady : Ada.Real_Time.Time;
   end record;

   function Read_Clocks return Clock_Sample;
   function Read_Clocks return Clock_Sample is
      Before : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Wall   : constant Ada.Calendar.Time :=
        Ada.Calendar.Clock
#if FLYOLOGY_WALL_CLOCK_TEST_HOOKS then
        + Flyology.Wall_Clock_Testing.Offset
#end if;
        ;
      After  : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   begin
      return
        (Wall   => Wall,
         Steady => Before + (After - Before) / 2);
   end Read_Clocks;

   procedure Sleep_For (Interval : Duration) is
   begin
      if Interval > 0.0 then
         delay Interval;
      else
         delay 0.0;
      end if;
   end Sleep_For;

   procedure Sleep_Until (Deadline : Ada.Real_Time.Time) is
   begin
      delay until Deadline;
   end Sleep_Until;

   function Wait_Until
     (Target             : Ada.Calendar.Time;
      Backstep_Tolerance : Duration := Default_Backstep_Tolerance)
      return Wall_Clock_Wait_Result
   is
      Source  : Flyology.Wall_Clock_Waits.Source;
      Initial : constant Clock_Sample := Read_Clocks;

      function Classify
        (Previous : Clock_Sample;
         Current  : Clock_Sample)
        return Flyology.Wall_Clock_Policy.Wait_Action;

      function Classify
        (Previous : Clock_Sample;
         Current  : Clock_Sample)
        return Flyology.Wall_Clock_Policy.Wait_Action
      is
         Wall_Elapsed : constant Duration := Current.Wall - Previous.Wall;
         Steady_Elapsed : constant Duration := Ada.Real_Time.To_Duration
           (Current.Steady - Previous.Steady);
      begin
         return
           Flyology.Wall_Clock_Policy.Classify
             (Target_Reached => Current.Wall >= Target,
              Wall_Elapsed   => Wall_Elapsed,
              Steady_Elapsed => Steady_Elapsed,
              Tolerance      => Backstep_Tolerance);
      end Classify;
   begin
      if Initial.Wall >= Target then
         delay 0.0;
         return
           (Outcome             => Target_Reached,
            Observed_Time       => Initial.Wall,
            Backward_Adjustment => 0.0);
      end if;

      Flyology.Wall_Clock_Waits.Open (Source);
      declare
         Previous : Clock_Sample := Read_Clocks;
      begin
         if Previous.Wall >= Target then
            delay 0.0;
            return
              (Outcome             => Target_Reached,
               Observed_Time       => Previous.Wall,
               Backward_Adjustment => 0.0);
         end if;

         loop
            declare
               Maximum_Slice : constant Duration :=
                 (if Flyology.Wall_Clock_Waits.Detects_Clock_Changes (Source)
                  then Maximum_Wait_Slice
                  else Fallback_Wait_Slice);
               Clock_Changed : constant Boolean :=
                 Flyology.Wall_Clock_Waits.Arm
                   (Source, Target, Maximum_Slice);
               Current       : Clock_Sample;
            begin
               --  Close the interval between the protected baseline and the
               --  native arm. Linux cannot cancel a timer for a clock change
               --  that happened before timerfd_settime installed it.
               Current := Read_Clocks;
               case Classify (Previous, Current) is
                  when Flyology.Wall_Clock_Policy.Keep_Waiting =>
                     Previous := Current;
                  when Flyology.Wall_Clock_Policy.Reached =>
                     return
                       (Outcome             => Target_Reached,
                        Observed_Time       => Current.Wall,
                        Backward_Adjustment => 0.0);
                  when Flyology.Wall_Clock_Policy.Backstep =>
                     return
                       (Outcome             => Clock_Moved_Backward,
                        Observed_Time       => Current.Wall,
                        Backward_Adjustment =>
                          Ada.Real_Time.To_Duration
                            (Current.Steady - Previous.Steady)
                          - (Current.Wall - Previous.Wall));
               end case;

               if not Clock_Changed then
                  if not Flyology.IO.Wait
                    (Flyology.Wall_Clock_Waits.Descriptor (Source),
                     Flyology.IO.For_Read)
                  then
                     raise Flyology.IO.Device_Error with
                       "wall-clock wait ended without an event";
                  end if;
                  Flyology.Wall_Clock_Waits.Consume (Source);

                  Current := Read_Clocks;
                  case Classify (Previous, Current) is
                     when Flyology.Wall_Clock_Policy.Keep_Waiting =>
                        Previous := Current;
                     when Flyology.Wall_Clock_Policy.Reached =>
                        return
                          (Outcome             => Target_Reached,
                           Observed_Time       => Current.Wall,
                           Backward_Adjustment => 0.0);
                     when Flyology.Wall_Clock_Policy.Backstep =>
                        return
                          (Outcome             => Clock_Moved_Backward,
                           Observed_Time       => Current.Wall,
                           Backward_Adjustment =>
                             Ada.Real_Time.To_Duration
                               (Current.Steady - Previous.Steady)
                             - (Current.Wall - Previous.Wall));
                  end case;
               end if;
            end;
         end loop;
      end;
   end Wait_Until;

end Flyology.IO.Timers;
