with Ada.Real_Time;
with Ada.Synchronous_Task_Control;
with Flyology;

procedure Suspension_Object_Smoke is
   package RT renames Ada.Real_Time;
   package STC renames Ada.Synchronous_Task_Control;

   use type RT.Time;

   protected type Signal is
      procedure Set;
      entry Wait;
   private
      Open : Boolean := False;
   end Signal;

   protected body Signal is
      procedure Set is
      begin
         Open := True;
      end Set;

      entry Wait when Open is
      begin
         null;
      end Wait;
   end Signal;

   procedure Await (Item : in out Signal; Message : String) is
   begin
      select
         Item.Wait;
      or
         delay 2.0;
         raise Program_Error with Message;
      end select;
   end Await;

   procedure Check_Pre_Set is
      Gate : STC.Suspension_Object;
      Done : Signal;
   begin
      STC.Set_True (Gate);
      declare
         task Waiter
           with CPU => 1 is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Waiter;

         task body Waiter is
         begin
            STC.Suspend_Until_True (Gate);
            Done.Set;
         end Waiter;
      begin
         Await (Done, "pre-set suspension object did not pass immediately");
      end;
   end Check_Pre_Set;

   procedure Check_Mixed_Lanes is
      Lightweight_Gate : STC.Suspension_Object;
      Native_Gate      : STC.Suspension_Object;
      Setter_Start     : Signal;
      Light_Started    : Signal;
      Native_Started   : Signal;
      Light_Done       : Signal;
      Native_Done      : Signal;

      task Light_Waiter
        with CPU => 1 is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Light_Waiter;

      task Native_Waiter is
         pragma Task_Info (Flyology.Native_Task);
      end Native_Waiter;

      task Light_Setter
        with CPU => 1 is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Light_Setter;

      task body Light_Waiter is
      begin
         Light_Started.Set;
         STC.Suspend_Until_True (Lightweight_Gate);
         Light_Done.Set;
      end Light_Waiter;

      task body Native_Waiter is
      begin
         Native_Started.Set;
         STC.Suspend_Until_True (Native_Gate);
         Native_Done.Set;
      end Native_Waiter;

      task body Light_Setter is
      begin
         Setter_Start.Wait;
         STC.Set_True (Native_Gate);
      end Light_Setter;
   begin
      Await (Light_Started, "lightweight waiter did not start");
      Await (Native_Started, "native waiter did not start");
      delay 0.01;
      STC.Set_True (Lightweight_Gate);
      Setter_Start.Set;
      Await (Light_Done, "native setter did not wake lightweight waiter");
      Await (Native_Done, "lightweight setter did not wake native waiter");
   end Check_Mixed_Lanes;

   procedure Check_Replacement_And_Second_Waiter is
      Shared_Gate     : STC.Suspension_Object;
      Blocker_Gate    : STC.Suspension_Object;
      First_Started   : Signal;
      Blocker_Started : Signal;
      Blocker_Running : Signal;
      Start_Second    : Signal;
      Second_Started  : Signal;
      Start_Third     : Signal;
      Third_Checked   : Signal;
      First_Done      : Signal;
      Second_Done     : Signal;
      Stop_Blocker    : Boolean := False
      with Atomic;
      Third_Raised    : Boolean := False
      with Atomic;

      task First
        with CPU => 1 is
         pragma Priority (5);
         pragma Task_Info (Flyology.Lightweight_Task);
      end First;

      task Blocker
        with CPU => 1 is
         pragma Priority (25);
         pragma Task_Info (Flyology.Lightweight_Task);
      end Blocker;

      task Second is
         pragma Task_Info (Flyology.Native_Task);
      end Second;

      task Third is
         pragma Task_Info (Flyology.Native_Task);
      end Third;

      task body First is
      begin
         First_Started.Set;
         STC.Suspend_Until_True (Shared_Gate);
         First_Done.Set;
      end First;

      task body Blocker is
      begin
         Blocker_Started.Set;
         STC.Suspend_Until_True (Blocker_Gate);
         Blocker_Running.Set;
         while not Stop_Blocker loop
            null;
         end loop;
      end Blocker;

      task body Second is
      begin
         Start_Second.Wait;
         Second_Started.Set;
         STC.Suspend_Until_True (Shared_Gate);
         Second_Done.Set;
      end Second;

      task body Third is
      begin
         Start_Third.Wait;
         begin
            STC.Suspend_Until_True (Shared_Gate);
         exception
            when Program_Error =>
               Third_Raised := True;
         end;
         Third_Checked.Set;
      end Third;
   begin
      Await (First_Started, "first replacement waiter did not start");
      Await (Blocker_Started, "replacement blocker did not start");
      delay 0.01;
      STC.Set_True (Blocker_Gate);
      Await (Blocker_Running, "replacement blocker did not run");

      STC.Set_True (Shared_Gate);
      Start_Second.Set;
      Await (Second_Started, "replacement waiter did not start");
      delay 0.01;
      Start_Third.Set;
      Await (Third_Checked, "second-waiter check did not finish");
      if not Third_Raised then
         raise Program_Error with "a second waiter did not raise Program_Error";
      end if;

      Stop_Blocker := True;
      Await (First_Done, "released waiter confused its replacement identity");
      STC.Set_True (Shared_Gate);
      Await (Second_Done, "replacement waiter was not released");
   end Check_Replacement_And_Second_Waiter;

   procedure Check_Parked_Abort is
      Gate    : STC.Suspension_Object;
      Started : Signal;
      task Waiter
        with CPU => 1 is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Waiter;

      task body Waiter is
      begin
         Started.Set;
         STC.Suspend_Until_True (Gate);
      end Waiter;
   begin
      Await (Started, "abort waiter did not start");
      delay 0.01;
      abort Waiter;
      declare
         Deadline : constant RT.Time := RT.Clock + RT.Seconds (2);
      begin
         while not Waiter'Terminated loop
            if RT.Clock >= Deadline then
               raise Program_Error with "aborted suspension-object waiter did not terminate";
            end if;
            delay 0.001;
         end loop;
      end;
   end Check_Parked_Abort;
begin
   Check_Pre_Set;
   Check_Mixed_Lanes;
   Check_Replacement_And_Second_Waiter;
   Check_Parked_Abort;
end Suspension_Object_Smoke;
