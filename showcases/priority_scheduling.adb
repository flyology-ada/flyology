with Ada.Synchronous_Task_Control;
with Ada.Text_IO;
with Gnatevl;
with Gnatevl.Observability;
with Interfaces;

procedure Priority_Scheduling is
   package STC renames Ada.Synchronous_Task_Control;
   package Observation renames Gnatevl.Observability;

   use type Interfaces.Unsigned_64;

   Low_A_Gate   : STC.Suspension_Object;
   Low_B_Gate   : STC.Suspension_Object;
   High_Gate    : STC.Suspension_Object;
   Blocker_Gate : STC.Suspension_Object;
   Stop_Blocker : Boolean := False with Atomic;

   protected Results is
      procedure Blocker_Running;
      entry Await_Blocker;
      procedure Ran (Name : Character);
      entry Await_All;
      function Trace return String;
   private
      Running : Boolean := False;
      Count   : Natural := 0;
      Order   : String (1 .. 3) := "---";
   end Results;

   protected body Results is
      procedure Blocker_Running is
      begin
         Running := True;
      end Blocker_Running;

      entry Await_Blocker when Running is
      begin
         null;
      end Await_Blocker;

      procedure Ran (Name : Character) is
      begin
         Count := Count + 1;
         Order (Count) := Name;
      end Ran;

      entry Await_All when Count = 3 is
      begin
         null;
      end Await_All;

      function Trace return String is (Order);
   end Results;

   task Low_A with CPU => 1 is
      pragma Priority (5);
      pragma Task_Info (Gnatevl.Event_Loop_Task);
   end Low_A;

   task Low_B with CPU => 1 is
      pragma Priority (5);
      pragma Task_Info (Gnatevl.Event_Loop_Task);
   end Low_B;

   task High with CPU => 1 is
      pragma Priority (20);
      pragma Task_Info (Gnatevl.Event_Loop_Task);
   end High;

   task Blocker with CPU => 1 is
      pragma Priority (25);
      pragma Task_Info (Gnatevl.Event_Loop_Task);
   end Blocker;

   task body Low_A is
   begin
      STC.Suspend_Until_True (Low_A_Gate);
      Results.Ran ('A');
   end Low_A;

   task body Low_B is
   begin
      STC.Suspend_Until_True (Low_B_Gate);
      Results.Ran ('B');
   end Low_B;

   task body High is
   begin
      STC.Suspend_Until_True (High_Gate);
      Results.Ran ('H');
   end High;

   task body Blocker is
   begin
      STC.Suspend_Until_True (Blocker_Gate);
      Results.Blocker_Running;
      while not Stop_Blocker loop
         null;
      end loop;
   end Blocker;

   Snapshot : Observation.Group_Snapshot;
begin
   loop
      exit when Observation.Snapshot (1, Snapshot)
        and then Snapshot.Waiting = 4;
      delay 0.001;
   end loop;

   STC.Set_True (Blocker_Gate);
   Results.Await_Blocker;
   STC.Set_True (Low_A_Gate);
   STC.Set_True (Low_B_Gate);
   STC.Set_True (High_Gate);

   loop
      exit when Observation.Snapshot (1, Snapshot)
        and then Snapshot.Ready = 3;
      delay 0.001;
   end loop;
   Stop_Blocker := True;
   Results.Await_All;

   Ada.Text_IO.Put_Line
     ("evented group 1 dispatch trace: " & Results.Trace);
   Ada.Text_IO.Put_Line
     ("expected: H first (priority 20), then A/B FIFO (priority 5)");
   Ada.Text_IO.Put_Line
     ("one group is cooperative; priorities select only at safe points");

   if Results.Trace /= "HAB" then
      raise Program_Error with "unexpected priority dispatch trace";
   end if;
end Priority_Scheduling;
