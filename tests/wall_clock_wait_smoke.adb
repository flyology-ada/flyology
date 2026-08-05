with Ada.Calendar;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Text_IO;
with Flyology;
with Flyology.IO.Timers;

procedure Wall_Clock_Wait_Smoke is
   use type Ada.Calendar.Time;
   use type Ada.Real_Time.Time;
   use type Flyology.IO.Timers.Wall_Clock_Wait_Outcome;

   protected Results is
      procedure Finished (Passed : Boolean);
      entry Wait;
      function Passed return Boolean;
   private
      Count  : Natural := 0;
      All_OK : Boolean := True;
   end Results;

   protected Closed_Gate is
      entry Wait;
   private
      Is_Open : Boolean := False;
   end Closed_Gate;

   protected body Closed_Gate is
      entry Wait when Is_Open is
      begin
         null;
      end Wait;
   end Closed_Gate;

   protected body Results is
      procedure Finished (Passed : Boolean) is
      begin
         Count := Count + 1;
         All_OK := All_OK and Passed;
      end Finished;

      entry Wait when Count = 2 is
      begin
         null;
      end Wait;

      function Passed return Boolean is (All_OK);
   end Results;

   task Lightweight is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Lightweight;

   task Native is
      pragma Task_Info (Flyology.Native_Task);
   end Native;

   task body Lightweight is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Milliseconds (5);
      Calendar_Delay : constant Ada.Calendar.Time :=
        Ada.Calendar.Clock + 0.010;
      Calendar_Select : Ada.Calendar.Time;
      Target          : Ada.Calendar.Time;
      Result          : Flyology.IO.Timers.Wall_Clock_Wait_Result;
   begin
      Flyology.IO.Timers.Sleep_Until (Deadline);
      delay until Calendar_Delay;
      Calendar_Select := Ada.Calendar.Clock + 0.010;
      select
         Closed_Gate.Wait;
      or
         delay until Calendar_Select;
      end select;
      Target := Ada.Calendar.Clock + 0.020;
      Result := Flyology.IO.Timers.Wait_Until (Target);
      Results.Finished
        (Ada.Real_Time.Clock >= Deadline
         and then Ada.Calendar.Clock >= Calendar_Delay
         and then Ada.Calendar.Clock >= Calendar_Select
         and then Result.Outcome = Flyology.IO.Timers.Target_Reached
         and then Result.Observed_Time >= Target
         and then Result.Backward_Adjustment = 0.0);
   exception
      when Error : others =>
         Ada.Text_IO.Put_Line
           (Ada.Exceptions.Exception_Information (Error));
         Results.Finished (False);
   end Lightweight;

   task body Native is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Milliseconds (5);
      Target   : constant Ada.Calendar.Time := Ada.Calendar.Clock + 0.020;
      Result   : Flyology.IO.Timers.Wall_Clock_Wait_Result;
   begin
      Flyology.IO.Timers.Sleep_Until (Deadline);
      Result := Flyology.IO.Timers.Wait_Until
        (Target, Backstep_Tolerance => 0.010);
      Results.Finished
        (Ada.Real_Time.Clock >= Deadline
         and then Result.Outcome = Flyology.IO.Timers.Target_Reached
         and then Result.Observed_Time >= Target
         and then Result.Backward_Adjustment = 0.0);
   exception
      when Error : others =>
         Ada.Text_IO.Put_Line
           (Ada.Exceptions.Exception_Information (Error));
         Results.Finished (False);
   end Native;
begin
   declare
      Target : constant Ada.Calendar.Time := Ada.Calendar.Clock - 0.010;
      Result : constant Flyology.IO.Timers.Wall_Clock_Wait_Result :=
        Flyology.IO.Timers.Wait_Until (Target);
   begin
      if Result.Outcome /= Flyology.IO.Timers.Target_Reached
        or else Result.Observed_Time < Target
        or else Result.Backward_Adjustment /= 0.0
      then
         raise Program_Error with "past wall-clock target did not complete";
      end if;
   end;

   Results.Wait;
   if not Results.Passed then
      raise Program_Error with "wall-clock wait lane parity failed";
   end if;

end Wall_Clock_Wait_Smoke;
