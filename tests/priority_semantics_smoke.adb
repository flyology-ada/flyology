with Ada.Dynamic_Priorities;
with Ada.Real_Time;
with Ada.Synchronous_Task_Control;
with Gnatevl;
with Gnatevl.Execution_Groups;
with Gnatevl.Observability;
with Interfaces;

procedure Priority_Semantics_Smoke is
   package Priorities renames Ada.Dynamic_Priorities;
   package RT renames Ada.Real_Time;
   package STC renames Ada.Synchronous_Task_Control;
   package Groups renames Gnatevl.Execution_Groups;
   package Observation renames Gnatevl.Observability;

   use type Interfaces.Unsigned_64;
   use type RT.Time;

   procedure Await_Group_State
     (Group       : Groups.Group_Id;
      Min_Ready   : Observation.Counter;
      Min_Waiting : Observation.Counter;
      Min_Running : Observation.Counter)
   is
      Deadline : constant RT.Time := RT.Clock + RT.Seconds (2);
      Snapshot : Observation.Group_Snapshot;
   begin
      loop
         if Observation.Snapshot (Group, Snapshot)
           and then Snapshot.Ready >= Min_Ready
           and then Snapshot.Waiting >= Min_Waiting
           and then Snapshot.Running >= Min_Running
         then
            return;
         end if;
         if RT.Clock >= Deadline then
            raise Program_Error with
              "timed out awaiting event-group priority state";
         end if;
         delay 0.001;
      end loop;
   end Await_Group_State;

   procedure Check_Waiting_Priority_Change is
      A_Gate        : STC.Suspension_Object;
      B_Gate        : STC.Suspension_Object;
      Blocker_Gate  : STC.Suspension_Object;
      Stop_Blocker  : Boolean := False with Atomic;

      protected Result is
         procedure Blocker_Running;
         entry Await_Blocker;
         procedure Record_Run (Id : Positive);
         entry Await_Done;
         function Passed return Boolean;
      private
         Blocker_Is_Running : Boolean := False;
         Count              : Natural := 0;
         First              : Positive := 1;
      end Result;

      protected body Result is
         procedure Blocker_Running is
         begin
            Blocker_Is_Running := True;
         end Blocker_Running;

         entry Await_Blocker when Blocker_Is_Running is
         begin
            null;
         end Await_Blocker;

         procedure Record_Run (Id : Positive) is
         begin
            Count := Count + 1;
            if Count = 1 then
               First := Id;
            end if;
         end Record_Run;

         entry Await_Done when Count = 2 is
         begin
            null;
         end Await_Done;

         function Passed return Boolean is (First = 1);
      end Result;

      task A with CPU => 1 is
         pragma Priority (5);
         pragma Task_Info (Gnatevl.Event_Loop_Task);
      end A;

      task B with CPU => 1 is
         pragma Priority (10);
         pragma Task_Info (Gnatevl.Event_Loop_Task);
      end B;

      task Blocker with CPU => 1 is
         pragma Priority (25);
         pragma Task_Info (Gnatevl.Event_Loop_Task);
      end Blocker;

      task body A is
      begin
         STC.Suspend_Until_True (A_Gate);
         Result.Record_Run (1);
      end A;

      task body B is
      begin
         STC.Suspend_Until_True (B_Gate);
         Result.Record_Run (2);
      end B;

      task body Blocker is
      begin
         STC.Suspend_Until_True (Blocker_Gate);
         Result.Blocker_Running;
         while not Stop_Blocker loop
            null;
         end loop;
      end Blocker;
   begin
      Await_Group_State (1, 0, 3, 0);
      STC.Set_True (Blocker_Gate);
      Result.Await_Blocker;

      --  A is parked when its active priority changes. Wake B first so the
      --  result proves A was enqueued at its new priority, not merely first.
      Priorities.Set_Priority (20, A'Identity);
      STC.Set_True (B_Gate);
      STC.Set_True (A_Gate);
      Await_Group_State (1, 2, 0, 1);
      Stop_Blocker := True;
      Result.Await_Done;
      if not Result.Passed then
         raise Program_Error with
           "priority change while waiting did not affect wake ordering";
      end if;
   end Check_Waiting_Priority_Change;

   procedure Check_Running_Priority_Change is
      Controller_Gate : STC.Suspension_Object;
      Competitor_Gate : STC.Suspension_Object;

      type Run_Order is array (Positive range 1 .. 3) of Positive;

      protected Result is
         procedure Record_Run (Id : Positive);
         entry Await_Done;
         function Passed return Boolean;
      private
         Count : Natural := 0;
         Order : Run_Order := (others => 1);
      end Result;

      protected body Result is
         procedure Record_Run (Id : Positive) is
         begin
            Count := Count + 1;
            Order (Count) := Id;
         end Record_Run;

         entry Await_Done when Count = 3 is
         begin
            null;
         end Await_Done;

         function Passed return Boolean is
           (Order = [1, 2, 1]);
      end Result;

      task Controller with CPU => 1 is
         pragma Priority (20);
         pragma Task_Info (Gnatevl.Event_Loop_Task);
      end Controller;

      task Competitor with CPU => 1 is
         pragma Priority (10);
         pragma Task_Info (Gnatevl.Event_Loop_Task);
      end Competitor;

      task body Controller is
      begin
         STC.Suspend_Until_True (Controller_Gate);
         Result.Record_Run (1);
         STC.Set_True (Competitor_Gate);
         --  Ada.Dynamic_Priorities supplies the required task dispatching
         --  point. The scheduler update itself must not invent preemption in
         --  the middle of arbitrary evented code.
         Priorities.Set_Priority (5);
         Result.Record_Run (1);
      end Controller;

      task body Competitor is
      begin
         STC.Suspend_Until_True (Competitor_Gate);
         Result.Record_Run (2);
      end Competitor;
   begin
      Await_Group_State (1, 0, 2, 0);
      STC.Set_True (Controller_Gate);
      Result.Await_Done;
      if not Result.Passed then
         raise Program_Error with
           "self priority lowering did not dispatch the higher ready task";
      end if;
   end Check_Running_Priority_Change;

   procedure Check_Rendezvous_Inheritance is
      Blocker_Gate : STC.Suspension_Object;
      Caller_Gate  : STC.Suspension_Object;
      Medium_Gate  : STC.Suspension_Object;
      Peer_Gate    : STC.Suspension_Object;
      Caller_Done  : STC.Suspension_Object;
      Stop_Blocker : Boolean := False with Atomic;

      protected Result is
         procedure Blocker_Running;
         entry Await_Blocker;
         procedure Record_Accept;
         procedure Record_Medium;
         procedure Record_After_Loss;
         procedure Record_Peer;
         entry Await_Done;
         function Passed return Boolean;
      private
         Blocker_Is_Running : Boolean := False;
         Accept_Count       : Natural := 0;
         Accept_First       : Boolean := False;
         Loss_Count         : Natural := 0;
         Loss_First         : Boolean := False;
      end Result;

      protected body Result is
         procedure Blocker_Running is
         begin
            Blocker_Is_Running := True;
         end Blocker_Running;

         entry Await_Blocker when Blocker_Is_Running is
         begin
            null;
         end Await_Blocker;

         procedure Record_Accept is
         begin
            Accept_Count := Accept_Count + 1;
            Accept_First := Accept_Count = 1;
         end Record_Accept;

         procedure Record_Medium is
         begin
            Accept_Count := Accept_Count + 1;
         end Record_Medium;

         procedure Record_After_Loss is
         begin
            Loss_Count := Loss_Count + 1;
            Loss_First := Loss_Count = 1;
         end Record_After_Loss;

         procedure Record_Peer is
         begin
            Loss_Count := Loss_Count + 1;
         end Record_Peer;

         entry Await_Done when Accept_Count = 2 and Loss_Count = 2 is
         begin
            null;
         end Await_Done;

         function Passed return Boolean is (Accept_First and Loss_First);
      end Result;

      task Server with CPU => 3 is
         pragma Priority (5);
         pragma Task_Info (Gnatevl.Event_Loop_Task);
         entry Work;
      end Server;

      task Caller with CPU => 3 is
         pragma Priority (20);
         pragma Task_Info (Gnatevl.Event_Loop_Task);
      end Caller;

      task Medium with CPU => 3 is
         pragma Priority (10);
         pragma Task_Info (Gnatevl.Event_Loop_Task);
      end Medium;

      task Peer with CPU => 3 is
         pragma Priority (5);
         pragma Task_Info (Gnatevl.Event_Loop_Task);
      end Peer;

      task Blocker with CPU => 3 is
         pragma Priority (25);
         pragma Task_Info (Gnatevl.Event_Loop_Task);
      end Blocker;

      task body Server is
      begin
         accept Work do
            --  The caller's active priority must be inherited before the
            --  medium task already in the ready queue can run.
            Result.Record_Accept;
            STC.Set_True (Peer_Gate);
         end Work;

         --  Completion lowers the inherited priority. RM D.2.2(9) requires
         --  the server at the head of its base-priority queue at this next
         --  dispatching point, ahead of Peer which was readied first.
         delay 0.0;
         Result.Record_After_Loss;
      end Server;

      task body Caller is
      begin
         STC.Suspend_Until_True (Caller_Gate);
         Server.Work;
         STC.Suspend_Until_True (Caller_Done);
      end Caller;

      task body Medium is
      begin
         STC.Suspend_Until_True (Medium_Gate);
         Result.Record_Medium;
      end Medium;

      task body Peer is
      begin
         STC.Suspend_Until_True (Peer_Gate);
         Result.Record_Peer;
      end Peer;

      task body Blocker is
      begin
         STC.Suspend_Until_True (Blocker_Gate);
         Result.Blocker_Running;
         while not Stop_Blocker loop
            null;
         end loop;
      end Blocker;
   begin
      Await_Group_State (3, 0, 5, 0);
      STC.Set_True (Blocker_Gate);
      Result.Await_Blocker;
      STC.Set_True (Medium_Gate);
      STC.Set_True (Caller_Gate);
      Await_Group_State (3, 2, 2, 1);
      Stop_Blocker := True;
      Result.Await_Done;
      STC.Set_True (Caller_Done);
      if not Result.Passed then
         raise Program_Error with
           "rendezvous inheritance or loss ordering was not preserved";
      end if;
   end Check_Rendezvous_Inheritance;

   procedure Check_Migration_Priority is
      Blocker_Gate : STC.Suspension_Object;
      Local_Gate   : STC.Suspension_Object;
      Migrant_Gate : STC.Suspension_Object;
      Stop_Blocker : Boolean := False with Atomic;

      protected Result is
         procedure Blocker_Running;
         entry Await_Blocker;
         procedure Record_Run (Id : Positive);
         entry Await_Done;
         function Passed return Boolean;
      private
         Blocker_Is_Running : Boolean := False;
         Count              : Natural := 0;
         First              : Positive := 1;
      end Result;

      protected body Result is
         procedure Blocker_Running is
         begin
            Blocker_Is_Running := True;
         end Blocker_Running;

         entry Await_Blocker when Blocker_Is_Running is
         begin
            null;
         end Await_Blocker;

         procedure Record_Run (Id : Positive) is
         begin
            Count := Count + 1;
            if Count = 1 then
               First := Id;
            end if;
         end Record_Run;

         entry Await_Done when Count = 2 is
         begin
            null;
         end Await_Done;

         function Passed return Boolean is (First = 1);
      end Result;

      task Migrant with CPU => 1 is
         pragma Priority (20);
         pragma Task_Info (Gnatevl.Event_Loop_Task);
      end Migrant;

      task Local with CPU => 2 is
         pragma Priority (10);
         pragma Task_Info (Gnatevl.Event_Loop_Task);
      end Local;

      task Blocker with CPU => 2 is
         pragma Priority (25);
         pragma Task_Info (Gnatevl.Event_Loop_Task);
      end Blocker;

      task body Migrant is
      begin
         STC.Suspend_Until_True (Migrant_Gate);
         Groups.Migrate (2);
         Result.Record_Run (1);
      end Migrant;

      task body Local is
      begin
         STC.Suspend_Until_True (Local_Gate);
         Result.Record_Run (2);
      end Local;

      task body Blocker is
      begin
         STC.Suspend_Until_True (Blocker_Gate);
         Result.Blocker_Running;
         while not Stop_Blocker loop
            null;
         end loop;
      end Blocker;
   begin
      Await_Group_State (1, 0, 1, 0);
      Await_Group_State (2, 0, 2, 0);
      STC.Set_True (Blocker_Gate);
      Result.Await_Blocker;
      STC.Set_True (Migrant_Gate);
      Await_Group_State (2, 1, 1, 1);
      STC.Set_True (Local_Gate);
      Await_Group_State (2, 2, 0, 1);
      Stop_Blocker := True;
      Result.Await_Done;
      if not Result.Passed then
         raise Program_Error with
           "migration did not preserve evented task priority";
      end if;
   end Check_Migration_Priority;

begin
   Check_Waiting_Priority_Change;
   Check_Running_Priority_Change;
   Check_Rendezvous_Inheritance;
   Check_Migration_Priority;
end Priority_Semantics_Smoke;
