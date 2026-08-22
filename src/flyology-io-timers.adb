with Flyology.Wall_Clock_Policy;
with Flyology.Wall_Clock_Waits;
with Flyology.Operations.Drivers;
#if FLYOLOGY_WALL_CLOCK_TEST_HOOKS then
with Flyology.Wall_Clock_Testing;
#end if;

package body Flyology.IO.Timers is
   use type Ada.Calendar.Time;
   use type Ada.Real_Time.Time;
   use type Ada.Real_Time.Time_Span;
   use type Flyology.Operations.Driver_Event;

   package Timer_Policy renames Flyology.Timer_Set_Policy;

   Maximum_Wait_Slice  : constant Duration := 86_400.0;
   Fallback_Wait_Slice : constant Duration := 1.0;
   Preferred_Sample_Span : constant Ada.Real_Time.Time_Span :=
     Ada.Real_Time.Milliseconds (1);
   Maximum_Sample_Span : constant Ada.Real_Time.Time_Span :=
     Ada.Real_Time.Seconds (1);
   Maximum_Sample_Attempts : constant Positive := 3;

   type Clock_Sample is record
      Wall            : Ada.Calendar.Time;
      Steady_Earliest : Ada.Real_Time.Time;
      Steady_Latest   : Ada.Real_Time.Time;
   end record;

   function Read_Clocks return Clock_Sample;
   function Read_Clocks return Clock_Sample is
      Before : Ada.Real_Time.Time;
      Wall   : Ada.Calendar.Time;
      After  : Ada.Real_Time.Time;
   begin
      for Attempt in 1 .. Maximum_Sample_Attempts loop
         Before := Ada.Real_Time.Clock;
         Wall := Ada.Calendar.Clock
#if FLYOLOGY_WALL_CLOCK_TEST_HOOKS then
           + Flyology.Wall_Clock_Testing.Offset
#end if;
           ;
         After := Ada.Real_Time.Clock;
#if FLYOLOGY_WALL_CLOCK_TEST_HOOKS then
         Flyology.Wall_Clock_Testing.Note_Sample_Attempt;
         After := After + Ada.Real_Time.To_Time_Span
           (Flyology.Wall_Clock_Testing.Sample_Bracket);
#end if;
         if After < Before then
            raise Flyology.IO.Device_Error with
              "monotonic clock moved backward while sampling wall clock";
         end if;
         exit when After - Before <= Preferred_Sample_Span
           or else Attempt = Maximum_Sample_Attempts;
      end loop;

      if After - Before > Maximum_Sample_Span then
         raise Flyology.IO.Device_Error with
           "wall-clock sample bracket exceeded one second";
      end if;

#if FLYOLOGY_WALL_CLOCK_TEST_HOOKS then
      Flyology.Wall_Clock_Testing.Note_Sample;
#end if;
      return
        (Wall            => Wall,
         Steady_Earliest => Before,
         Steady_Latest   => After);
   end Read_Clocks;

   function Minimum_Steady_Elapsed
     (Previous : Clock_Sample;
      Current  : Clock_Sample) return Duration
   is
   begin
      if Current.Steady_Latest < Previous.Steady_Earliest then
         raise Flyology.IO.Device_Error with
           "monotonic clock moved backward during wall-clock wait";
      elsif Current.Steady_Earliest <= Previous.Steady_Latest then
         return 0.0;
      else
         return Ada.Real_Time.To_Duration
           (Current.Steady_Earliest - Previous.Steady_Latest);
      end if;
   end Minimum_Steady_Elapsed;

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

   procedure Sleep_For
     (Interval  : Duration;
      Operation : in out Timer_Operation)
   is
   begin
      Flyology.Operations.Drivers.Start (Operation);
      Flyology.Operations.Drivers.Arm_Deadline (Operation, Interval);
   exception
      when others =>
         if Flyology.Operations.Is_Active (Operation) then
            Flyology.Operations.Drivers.Rollback_Start (Operation);
         end if;
         raise;
   end Sleep_For;

   function Sleep_For
     (Set      : not null access Flyology.Operations.Completion_Set'Class;
      Interval : Duration) return Timer_Operation
   is
   begin
      return Result : Timer_Operation (Set) do
         Sleep_For (Interval, Result);
      end return;
   end Sleep_For;

   procedure Sleep_Until
     (Deadline  : Ada.Real_Time.Time;
      Operation : in out Timer_Operation)
   is
      Now : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   begin
      Sleep_For
        ((if Deadline <= Now
          then 0.0
          else Ada.Real_Time.To_Duration (Deadline - Now)),
         Operation);
   end Sleep_Until;

   function Sleep_Until
     (Set      : not null access Flyology.Operations.Completion_Set'Class;
      Deadline : Ada.Real_Time.Time) return Timer_Operation
   is
   begin
      return Result : Timer_Operation (Set) do
         Sleep_Until (Deadline, Result);
      end return;
   end Sleep_Until;

   procedure Rearm
     (Interval  : Duration;
      Operation : in out Timer_Operation)
   is
   begin
      Sleep_For (Interval, Operation);
   end Rearm;

   overriding procedure Drive
     (Item  : in out Timer_Operation;
      Event : Flyology.Operations.Driver_Event)
   is
   begin
      Flyology.Operations.Drivers.Complete
        (Item,
         (if Event = Flyology.Operations.Deadline_Reached
          then Flyology.Operations.Succeeded
          else Flyology.Operations.Failed));
   end Drive;

   overriding procedure Request_Cancellation
     (Item : in out Timer_Operation)
   is
   begin
      Flyology.Operations.Drivers.Complete
        (Item, Flyology.Operations.Cancelled);
   end Request_Cancellation;

   procedure Finish (Operation : in out Timer_Operation) is
      Result : constant Flyology.Operations.Terminal_Outcome :=
        Flyology.Operations.Outcome (Operation);
   begin
      Flyology.Operations.Consume (Operation);
      case Result is
         when Flyology.Operations.Succeeded =>
            null;
         when Flyology.Operations.Cancelled =>
            raise Flyology.Operations.Operation_Cancelled;
         when Flyology.Operations.Failed =>
            raise Flyology.IO.Device_Error with "timer operation failed";
      end case;
   end Finish;

   procedure Arm
     (Timers   : in out Timer_Set;
      Id       : Timer_Id;
      Deadline : Ada.Real_Time.Time)
   is
   begin
      Timer_Policy.Arm (Timers.State, Id, Deadline);
   end Arm;

   procedure Replace
     (Timers    : in out Timer_Set;
      Deadlines : Deadline_Array)
   is
   begin
      Timer_Policy.Clear (Timers.State);
      for Id in Deadlines'Range loop
         Timer_Policy.Arm (Timers.State, Id, Deadlines (Id));
      end loop;
   end Replace;

   procedure Cancel
     (Timers : in out Timer_Set;
      Id     : Timer_Id)
   is
   begin
      Timer_Policy.Cancel (Timers.State, Id);
   end Cancel;

   function Is_Armed
     (Timers : Timer_Set;
      Id     : Timer_Id) return Boolean
   is
     (Timer_Policy.Is_Armed (Timers.State, Id));

   function Armed_Count (Timers : Timer_Set) return Natural is
     (Timer_Policy.Armed_Count (Timers.State));

   procedure Publish
     (Due       : Timer_Policy.Due_Batch;
      Activated : out Activation_Batch)
   is
   begin
      Activated.Count := Due.Count;
      Activated.Ids := (others => Timer_Id'First);
      for Position in 1 .. Due.Count loop
         Activated.Ids (Position) := Due.Ids (Position);
      end loop;
   end Publish;

   function Saturating_Deadline
     (Started : Ada.Real_Time.Time;
      Timeout : Duration) return Ada.Real_Time.Time
   is
      Span : constant Ada.Real_Time.Time_Span :=
        Ada.Real_Time.To_Time_Span (Timeout);
   begin
      if Span >= Ada.Real_Time.Time_Last - Started then
         return Ada.Real_Time.Time_Last;
      else
         return Started + Span;
      end if;
   end Saturating_Deadline;

   procedure Wait_Next
     (Timers    : in out Timer_Set;
      Activated : out Activation_Batch)
   is
      Due      : Timer_Policy.Due_Batch (Timers.Capacity);
      Observed : Ada.Real_Time.Time;
   begin
      loop
         Observed := Ada.Real_Time.Clock;
         Timer_Policy.Collect_Due (Timers.State, Observed, Due);
         if Due.Count > 0 then
            Publish (Due, Activated);
            return;
         end if;

         Sleep_Until (Timer_Policy.Earliest_Deadline (Timers.State));
      end loop;
   end Wait_Next;

   procedure Wait_Next
     (Timers    : in out Timer_Set;
      Activated : out Activation_Batch;
      Timeout   : Duration;
      Outcome   : out Timer_Wait_Outcome)
   is
      Started    : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Timeout_At : constant Ada.Real_Time.Time :=
        Saturating_Deadline (Started, Timeout);
      Due        : Timer_Policy.Due_Batch (Timers.Capacity);
      Observed   : Ada.Real_Time.Time;
      Wake_At    : Ada.Real_Time.Time;
   begin
      loop
         Observed := Ada.Real_Time.Clock;
         Timer_Policy.Collect_Due (Timers.State, Observed, Due);
         if Due.Count > 0 then
            Publish (Due, Activated);
            Outcome := Timers_Activated;
            return;
         elsif Observed >= Timeout_At then
            Activated.Count := 0;
            Activated.Ids := (others => Timer_Id'First);
            Outcome := Wait_Timed_Out;
            return;
         end if;

         Wake_At := Timer_Policy.Earliest_Deadline (Timers.State);
         if Timeout_At < Wake_At then
            Wake_At := Timeout_At;
         end if;
         Sleep_Until (Wake_At);
      end loop;
   end Wait_Next;

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
         Steady_Elapsed : constant Duration :=
           Minimum_Steady_Elapsed (Previous, Current);
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
                 (if Flyology.Wall_Clock_Waits.Cancels_On_Clock_Set (Source)
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
                          Minimum_Steady_Elapsed (Previous, Current)
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
                             Minimum_Steady_Elapsed (Previous, Current)
                             - (Current.Wall - Previous.Wall));
                  end case;
               end if;
            end;
         end loop;
      end;
   end Wait_Until;

end Flyology.IO.Timers;
