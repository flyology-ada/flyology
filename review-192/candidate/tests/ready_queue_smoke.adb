with Ada.Dynamic_Priorities;
with Flyology;

procedure Ready_Queue_Smoke is
   Worker_Count      : constant := 3;
   Worker_Priority   : constant := 5;
   Promoted_Priority : constant := 20;
   Blocker_Priority  : constant := 25;
   type Result_Array is array (Positive range 1 .. Worker_Count) of Positive;
   Stop_Blocker      : Boolean := False
   with Atomic;

   protected State is
      procedure Arrive (Ticket : out Positive);
      entry Await_All_Arrivals;
      entry Await_Blocker_Start;
      procedure Start_Blocker;
      procedure Blocker_Is_Running;
      entry Await_Blocker_Running;
      entry Await_Release;
      procedure Release;
      procedure Record_Run (Id, Ticket : Positive);
      entry Await_Completion;
      function First_Id return Positive;
      function Second_Ticket return Positive;
      function Third_Ticket return Positive;
   private
      Arrivals        : Natural := 0;
      Blocker_Started : Boolean := False;
      Blocker_Running : Boolean := False;
      Released        : Boolean := False;
      Completed       : Natural := 0;
      Run_Ids         : Result_Array := (others => 1);
      Run_Tickets     : Result_Array := (others => 1);
   end State;

   protected body State is
      procedure Arrive (Ticket : out Positive) is
      begin
         Arrivals := Arrivals + 1;
         Ticket := Arrivals;
      end Arrive;

      entry Await_All_Arrivals when Arrivals = Worker_Count is
      begin
         null;
      end Await_All_Arrivals;

      entry Await_Blocker_Start when Blocker_Started is
      begin
         null;
      end Await_Blocker_Start;

      procedure Start_Blocker is
      begin
         Blocker_Started := True;
      end Start_Blocker;

      procedure Blocker_Is_Running is
      begin
         Blocker_Running := True;
      end Blocker_Is_Running;

      entry Await_Blocker_Running when Blocker_Running is
      begin
         null;
      end Await_Blocker_Running;

      entry Await_Release when Released is
      begin
         null;
      end Await_Release;

      procedure Release is
      begin
         Released := True;
      end Release;

      procedure Record_Run (Id, Ticket : Positive) is
      begin
         Completed := Completed + 1;
         Run_Ids (Completed) := Id;
         Run_Tickets (Completed) := Ticket;
      end Record_Run;

      entry Await_Completion when Completed = Worker_Count is
      begin
         null;
      end Await_Completion;

      function First_Id return Positive
      is (Run_Ids (1));

      function Second_Ticket return Positive
      is (Run_Tickets (2));

      function Third_Ticket return Positive
      is (Run_Tickets (3));
   end State;

   task type Worker (Id : Positive) is
      pragma Priority (Worker_Priority);
      pragma Task_Info (Flyology.Lightweight_Task);
   end Worker;

   task Blocker is
      pragma Priority (Blocker_Priority);
      pragma Task_Info (Flyology.Lightweight_Task);
   end Blocker;

   task body Blocker is
   begin
      State.Await_Blocker_Start;
      State.Blocker_Is_Running;
      while not Stop_Blocker loop
         null;
      end loop;
   end Blocker;

   task body Worker is
      Ticket : Positive;
   begin
      State.Arrive (Ticket);
      State.Await_Release;
      State.Record_Run (Id, Ticket);
   end Worker;

   First    : Worker (1);
   Second   : Worker (2);
   Promoted : Worker (3);
   pragma Unreferenced (First, Second, Blocker);
begin
   State.Await_All_Arrivals;
   State.Start_Blocker;
   State.Await_Blocker_Running;
   State.Release;
   Ada.Dynamic_Priorities.Set_Priority (Promoted_Priority, Promoted'Identity);
   Stop_Blocker := True;
   delay 0.0;
   State.Await_Completion;

   --  Promotion removes a ready fiber from its old bucket and inserts it at
   --  the tail of the higher-priority bucket. The remaining bucket must keep
   --  the FIFO order in which its two waiters became ready.
   pragma Assert (State.First_Id = 3);
   pragma Assert (State.Second_Ticket < State.Third_Ticket);

end Ready_Queue_Smoke;
