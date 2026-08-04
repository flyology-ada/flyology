with Ada.Calendar;
with Ada.Exceptions;
with Ada.Text_IO;
with Flyology.IO.Timers;

procedure Flyology.Wall_Clock_Testing.Smoke is
   use type Ada.Calendar.Time;
   use type Flyology.IO.Timers.Wall_Clock_Wait_Outcome;

   protected type Result_State is
      procedure Started;
      procedure Finished (Passed : Boolean);
      entry Wait_Until_Started;
      entry Wait_Until_Finished;
      function Passed return Boolean;
   private
      Has_Started  : Boolean := False;
      Has_Finished : Boolean := False;
      All_OK       : Boolean := True;
   end Result_State;

   protected body Result_State is
      procedure Started is
      begin
         Has_Started := True;
      end Started;

      procedure Finished (Passed : Boolean) is
      begin
         All_OK := All_OK and Passed;
         Has_Finished := True;
      end Finished;

      entry Wait_Until_Started when Has_Started is
      begin
         null;
      end Wait_Until_Started;

      entry Wait_Until_Finished when Has_Finished is
      begin
         null;
      end Wait_Until_Finished;

      function Passed return Boolean is (All_OK);
   end Result_State;

   procedure Check_Backstep (Lightweight : Boolean) is
      Results : Result_State;

      task Waiter is
         pragma Task_Info
           (if Lightweight
            then Flyology.Lightweight_Task
            else Flyology.Native_Task);
      end Waiter;

      task body Waiter is
         Target : constant Ada.Calendar.Time := Ada.Calendar.Clock + 0.050;
         Result : Flyology.IO.Timers.Wall_Clock_Wait_Result;
      begin
         Results.Started;
         Result := Flyology.IO.Timers.Wait_Until (Target);
         Results.Finished
           (Result.Outcome = Flyology.IO.Timers.Clock_Moved_Backward
            and then Result.Backward_Adjustment >= 0.5);
      exception
         when Error : others =>
            Ada.Text_IO.Put_Line
              (Ada.Exceptions.Exception_Information (Error));
            Results.Finished (False);
      end Waiter;
   begin
      Results.Wait_Until_Started;
      delay 0.010;
      Set_Offset (-1.0);
      Results.Wait_Until_Finished;
      Set_Offset (0.0);
      if not Results.Passed then
         raise Program_Error with "backward clock change was not reported";
      end if;
   end Check_Backstep;
begin
   Check_Backstep (Lightweight => True);
   Check_Backstep (Lightweight => False);
end Flyology.Wall_Clock_Testing.Smoke;
