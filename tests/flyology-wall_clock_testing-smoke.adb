with Ada.Calendar;
with Ada.Exceptions;
with Ada.Text_IO;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.IO.Timers;
with Flyology.Wall_Clock_Waits;

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
   begin
      Set_Offset (0.0);
      Reset_Samples;
      declare
         Results : Result_State;

         task Waiter is
            pragma Task_Info
              (if Lightweight
               then Flyology.Lightweight_Task
               else Flyology.Native_Task);
         end Waiter;

         task body Waiter is
            Target : constant Ada.Calendar.Time := Ada.Calendar.Clock + 60.0;
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
         Wait_For_Baseline;
         Set_Offset (-1.0);
         Results.Wait_Until_Finished;
         Set_Offset (0.0);
         if not Results.Passed then
            raise Program_Error with "backward clock change was not reported";
         end if;
      end;
   end Check_Backstep;

   procedure Check_Relative_Rearm is
   begin
      if not Uses_Native_Relative_Timer then
         return;
      end if;

      declare
         Source  : Flyology.Wall_Clock_Waits.Source;
         Target  : constant Ada.Calendar.Time :=
           Ada.Calendar.Time_Of (2030, 1, 1, 0.0);
         Changed : Boolean;
      begin
         Flyology.Wall_Clock_Waits.Open (Source);

         Set_Native_Remaining (5.0);
         Changed := Flyology.Wall_Clock_Waits.Arm
           (Source, Target, Maximum_Slice => 3.0);
         if Changed or else Last_Native_Arm /= 3.0 then
            raise Program_Error with "relative wall timer did not bound arm";
         end if;

         Set_Native_Remaining (2.0);
         Changed := Flyology.Wall_Clock_Waits.Arm
           (Source, Target, Maximum_Slice => 10.0);
         if Changed or else Last_Native_Arm /= 2.0 then
            raise Program_Error with "relative wall timer did not move forward";
         end if;

         Set_Native_Remaining (8.0);
         Changed := Flyology.Wall_Clock_Waits.Arm
           (Source, Target, Maximum_Slice => 10.0);
         if Changed or else Last_Native_Arm /= 8.0 then
            raise Program_Error with "relative wall timer did not rearm backstep";
         end if;
      end;
      Reset_Native_Remaining;
   exception
      when others =>
         Reset_Native_Remaining;
         raise;
   end Check_Relative_Rearm;

   procedure Check_Wide_Sample_Bracket is
      Target : constant Ada.Calendar.Time := Ada.Calendar.Clock + 0.020;
      Result : Flyology.IO.Timers.Wall_Clock_Wait_Result;
   begin
      Set_Offset (0.0);
      Reset_Samples (Pause_For_Offset => False);
      Set_Sample_Bracket (0.250);
      Result := Flyology.IO.Timers.Wait_Until
        (Target, Backstep_Tolerance => 0.001);
      if Result.Outcome /= Flyology.IO.Timers.Target_Reached then
         raise Program_Error with
           "wide clock bracket manufactured a wall-clock backstep";
      elsif Sample_Attempts < 3 then
         raise Program_Error with "wide clock bracket did not retry";
      end if;
      Reset_Sample_Bracket;
   exception
      when others =>
         Reset_Sample_Bracket;
         raise;
   end Check_Wide_Sample_Bracket;

   procedure Check_IO_Retry_Clock is
      Left, Right : Flyology.IO.Sockets.Socket_Type;
      Ready       : Boolean;
   begin
      Flyology.IO.Sockets.Create_Socket_Pair (Left, Right);
      Configure_IO_Retry
        (Steady_Advance  => 0.005,
         Wall_Adjustment => -120.0);
      Ready := Flyology.IO.Wait
        (Flyology.IO.Sockets.Native_Descriptor (Left),
         Flyology.IO.For_Read,
         Timeout => 0.010);
      if Ready or else IO_Retry_Count /= 1 or else Offset /= -120.0 then
         raise Program_Error with
           "native EINTR retry state: ready=" & Boolean'Image (Ready)
           & " retries=" & Natural'Image (IO_Retry_Count)
           & " wall=" & Duration'Image (Offset);
      end if;
      Reset_IO_Retry;
      Set_Offset (0.0);
      Flyology.IO.Sockets.Close_Socket (Left);
      Flyology.IO.Sockets.Close_Socket (Right);
   exception
      when others =>
         Reset_IO_Retry;
         Set_Offset (0.0);
         Flyology.IO.Sockets.Close_Socket (Left);
         Flyology.IO.Sockets.Close_Socket (Right);
         raise;
   end Check_IO_Retry_Clock;

   procedure Check_Consume_EINTR is
   begin
      if not Uses_Native_Relative_Timer then
         return;
      end if;

      declare
         Source  : Flyology.Wall_Clock_Waits.Source;
         Target  : constant Ada.Calendar.Time :=
           Ada.Calendar.Time_Of (2030, 1, 1, 0.0);
         Changed : Boolean;
      begin
         Flyology.Wall_Clock_Waits.Open (Source);
         Set_Native_Remaining (0.0);
         Set_Native_Consume_EINTR (2);
         Changed := Flyology.Wall_Clock_Waits.Arm
           (Source, Target, Maximum_Slice => 1.0);
         if Changed
           or else not Flyology.IO.Wait
             (Flyology.Wall_Clock_Waits.Descriptor (Source),
              Flyology.IO.For_Read,
              Timeout => 1.0)
         then
            raise Program_Error with "wall event did not become ready";
         end if;
         Flyology.Wall_Clock_Waits.Consume (Source);
         if Native_Consume_EINTR_Remaining /= 0 then
            raise Program_Error with "wall event did not retry EINTR";
         end if;
      end;
      Set_Native_Consume_EINTR (0);
      Reset_Native_Remaining;
   exception
      when others =>
         Set_Native_Consume_EINTR (0);
         Reset_Native_Remaining;
         raise;
   end Check_Consume_EINTR;
begin
   Check_Relative_Rearm;
   Check_Consume_EINTR;
   Check_Wide_Sample_Bracket;
   Check_IO_Retry_Clock;
   Check_Backstep (Lightweight => True);
   Check_Backstep (Lightweight => False);
end Flyology.Wall_Clock_Testing.Smoke;
