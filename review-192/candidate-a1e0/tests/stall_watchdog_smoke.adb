with Ada.Real_Time;
with Flyology;
with Flyology.Observability.Stall_Watchdogs;

procedure Stall_Watchdog_Smoke is
   package RT renames Ada.Real_Time;
   package Watchdogs renames Flyology.Observability.Stall_Watchdogs;

   use type RT.Time;
   use type Flyology.Observability.Counter;
   use type Watchdogs.Group_Condition;

   protected Control is
      procedure Spinner_Started;
      procedure Spinner_Finished;
      procedure Waiter_Started;
      procedure Seeder_Finished;
      procedure Open_Gate;
      entry Wait_For_Starts;
      entry Wait_For_Spinner;
      entry Wait_For_Seeder;
      entry Gate;
   private
      Spinner_Is_Started  : Boolean := False;
      Spinner_Is_Finished : Boolean := False;
      Waiter_Is_Started   : Boolean := False;
      Seeder_Is_Finished  : Boolean := False;
      Gate_Is_Open        : Boolean := False;
   end Control;

   protected body Control is
      procedure Spinner_Started is
      begin
         Spinner_Is_Started := True;
      end Spinner_Started;

      procedure Spinner_Finished is
      begin
         Spinner_Is_Finished := True;
      end Spinner_Finished;

      procedure Waiter_Started is
      begin
         Waiter_Is_Started := True;
      end Waiter_Started;

      procedure Seeder_Finished is
      begin
         Seeder_Is_Finished := True;
      end Seeder_Finished;

      procedure Open_Gate is
      begin
         Gate_Is_Open := True;
      end Open_Gate;

      entry Wait_For_Starts when Spinner_Is_Started and Waiter_Is_Started is
      begin
         null;
      end Wait_For_Starts;

      entry Wait_For_Spinner when Spinner_Is_Finished is
      begin
         null;
      end Wait_For_Spinner;

      entry Wait_For_Seeder when Seeder_Is_Finished is
      begin
         null;
      end Wait_For_Seeder;

      entry Gate when Gate_Is_Open is
      begin
         null;
      end Gate;
   end Control;

   Busy_Watchdog    : Watchdogs.Watchdog;
   Waiting_Watchdog : Watchdogs.Watchdog;
   Idle_Watchdog    : Watchdogs.Watchdog;
   Config           : constant Watchdogs.Watchdog_Config :=
     (Group => 0, Sample_Interval => 0.010, Stall_Threshold => 0.060);
begin
   Watchdogs.Start (Busy_Watchdog, Config);
   Watchdogs.Start (Waiting_Watchdog, (Config with delta Group => 1));
   Watchdogs.Start (Idle_Watchdog, (Config with delta Group => 2));

   declare
      task Spinner is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Spinner;

      task Waiter
        with CPU => 1 is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Waiter;

      task Seeder
        with CPU => 2 is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Seeder;

      task body Spinner is
         Finish : constant RT.Time := RT.Clock + RT.Milliseconds (350);
      begin
         Control.Spinner_Started;
         while RT.Clock < Finish loop
            null;
         end loop;
         Control.Spinner_Finished;
      end Spinner;

      task body Waiter is
      begin
         Control.Waiter_Started;
         Control.Gate;
      end Waiter;

      task body Seeder is
      begin
         Control.Seeder_Finished;
      end Seeder;
   begin
      Control.Wait_For_Starts;
      Control.Wait_For_Seeder;

      declare
         Deadline : constant RT.Time := RT.Clock + RT.Seconds (2);
      begin
         while Watchdogs.Latest_Report (Busy_Watchdog).Stall_Episodes = 0 and then RT.Clock < Deadline loop
            delay 0.010;
         end loop;
      end;

      if Watchdogs.Latest_Report (Busy_Watchdog).Stall_Episodes = 0 then
         raise Program_Error with "monopolized event loop was not detected";
      end if;

      delay 0.100;
      if Watchdogs.Latest_Report (Waiting_Watchdog).Condition /= Watchdogs.Waiting
        or else Watchdogs.Latest_Report (Waiting_Watchdog).Stall_Episodes /= 0
      then
         raise Program_Error with "parked group was reported as stalled";
      end if;
      if Watchdogs.Latest_Report (Idle_Watchdog).Condition /= Watchdogs.Idle
        or else Watchdogs.Latest_Report (Idle_Watchdog).Stall_Episodes /= 0
      then
         raise Program_Error with "empty group was reported as stalled";
      end if;

      Control.Wait_For_Spinner;
      Control.Open_Gate;
   end;

   Watchdogs.Stop (Busy_Watchdog);
   Watchdogs.Stop (Waiting_Watchdog);
   Watchdogs.Stop (Idle_Watchdog);
end Stall_Watchdog_Smoke;
