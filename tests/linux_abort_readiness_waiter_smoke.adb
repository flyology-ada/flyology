with Ada.Real_Time;
with Ada.Streams;
with Fault_Control;
with Flyology;
with Flyology.IO;
with Flyology.IO.Sockets;

procedure Linux_Abort_Readiness_Waiter_Smoke is
   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;

   Backlog_Count : constant Positive := 64;
   Iterations    : constant Positive := 8;

   procedure Run_One is
      package Sockets renames Flyology.IO.Sockets;

      type Socket_Array is array (Positive range <>) of Sockets.Socket_Type;

      Victims      : Socket_Array (1 .. Backlog_Count);
      Victim_Peers : Socket_Array (1 .. Backlog_Count);
      Target       : Sockets.Socket_Type;
      Target_Peer  : Sockets.Socket_Type;
      Second       : Sockets.Socket_Type;
      Second_Peer  : Sockets.Socket_Type;

      protected Observation is
         procedure Note_First_Return;
         procedure Note_Second_Return;
         procedure Stop_Runner;
         function First_Returned return Boolean;
         function Second_Returned return Boolean;
         function Runner_Stopped return Boolean;
      private
         First_Done  : Boolean := False;
         Second_Done : Boolean := False;
         Stop        : Boolean := False;
      end Observation;

      protected body Observation is
         procedure Note_First_Return is
         begin
            First_Done := True;
         end Note_First_Return;

         procedure Note_Second_Return is
         begin
            Second_Done := True;
         end Note_Second_Return;

         procedure Stop_Runner is
         begin
            Stop := True;
         end Stop_Runner;

         function First_Returned return Boolean
         is (First_Done);

         function Second_Returned return Boolean
         is (Second_Done);

         function Runner_Stopped return Boolean
         is (Stop);
      end Observation;

      task type Backlog_Waiter (Descriptor : Flyology.IO.Descriptor) is
         pragma Task_Info (Flyology.Lightweight_Task);
         pragma Priority (10);
      end Backlog_Waiter;

      task body Backlog_Waiter is
      begin
         if Flyology.IO.Wait
              (Descriptor, Flyology.IO.For_Read, Flyology.IO.Infinite)
         then
            null;
         end if;
      end Backlog_Waiter;

      type Backlog_Waiter_Access is access Backlog_Waiter;
      type Backlog_Waiter_Array is
        array (Positive range <>) of Backlog_Waiter_Access;
      Waiters : Backlog_Waiter_Array (1 .. Backlog_Count) := [others => null];

      task type Target_Waiter
        (First_Descriptor  : Flyology.IO.Descriptor;
         Second_Descriptor : Flyology.IO.Descriptor)
      is
         pragma Task_Info (Flyology.Lightweight_Task);
         pragma Priority (25);
      end Target_Waiter;

      task body Target_Waiter is
      begin
         if Flyology.IO.Wait
              (First_Descriptor, Flyology.IO.For_Read, Flyology.IO.Infinite)
         then
            Observation.Note_First_Return;
            if Flyology.IO.Wait
                 (Second_Descriptor,
                  Flyology.IO.For_Read,
                  Flyology.IO.Infinite)
            then
               Observation.Note_Second_Return;
            end if;
         end if;
      end Target_Waiter;

      type Target_Waiter_Access is access Target_Waiter;
      Target_Task : Target_Waiter_Access := null;

      task Runner is
         pragma Task_Info (Flyology.Lightweight_Task);
         pragma Priority (1);
      end Runner;

      task body Runner is
      begin
         while not Observation.Runner_Stopped loop
            delay 0.0;
         end loop;
      end Runner;

      procedure Await
        (Condition : not null access function return Boolean; Failure : String)
      is
         Limit : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.Seconds (3);
      begin
         while not Condition.all loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with Failure;
            end if;
            delay 0.001;
         end loop;
      end Await;

      function All_Registered return Boolean
      is (Fault_Control.Calls (Fault_Control.Poller_Watch)
          >= Backlog_Count + 1);

      function Translation_Parked return Boolean
      is (Fault_Control.Poller_Translation_Parked);

      function Budget_Parked return Boolean
      is (Fault_Control.Descriptor_Cancel_Budget_Parked);

      function Target_Terminated return Boolean
      is (Target_Task /= null and then Target_Task'Terminated);

      function Backlog_Terminated return Boolean is
      begin
         for Item of Waiters loop
            if Item /= null and then not Item'Terminated then
               return False;
            end if;
         end loop;
         return True;
      end Backlog_Terminated;

      procedure Cleanup is
      begin
         Fault_Control.Release_Poller_Translation;
         Fault_Control.Release_Descriptor_Cancel_Budget;
         Observation.Stop_Runner;
         if Target_Task /= null and then not Target_Task'Terminated then
            abort Target_Task.all;
         end if;
         for Item of Waiters loop
            if Item /= null and then not Item'Terminated then
               abort Item.all;
            end if;
         end loop;
         for Index in Victims'Range loop
            if Sockets.Is_Open (Victims (Index)) then
               Sockets.Close_Socket (Victims (Index));
            end if;
            if Sockets.Is_Open (Victim_Peers (Index)) then
               Sockets.Close_Socket (Victim_Peers (Index));
            end if;
         end loop;
         if Sockets.Is_Open (Target) then
            Sockets.Close_Socket (Target);
         end if;
         if Sockets.Is_Open (Target_Peer) then
            Sockets.Close_Socket (Target_Peer);
         end if;
         if Sockets.Is_Open (Second) then
            Sockets.Close_Socket (Second);
         end if;
         if Sockets.Is_Open (Second_Peer) then
            Sockets.Close_Socket (Second_Peer);
         end if;
         Fault_Control.Reset;
      end Cleanup;

      Payload : constant Ada.Streams.Stream_Element_Array := [1 => 73];
      Last    : Ada.Streams.Stream_Element_Offset;
   begin
      for Index in Victims'Range loop
         Sockets.Create_Socket_Pair (Victims (Index), Victim_Peers (Index));
      end loop;
      Sockets.Create_Socket_Pair (Target, Target_Peer);
      Sockets.Create_Socket_Pair (Second, Second_Peer);
      Fault_Control.Reset;
      Fault_Control.Arm (Fault_Control.Poller_Translation_Pause);
      Fault_Control.Arm (Fault_Control.Descriptor_Cancel_Budget_Pause);

      for Index in Waiters'Range loop
         Waiters (Index) :=
           new Backlog_Waiter (Sockets.Native_Descriptor (Victims (Index)));
      end loop;
      Target_Task :=
        new Target_Waiter
              (Sockets.Native_Descriptor (Target),
               Sockets.Native_Descriptor (Second));

      Await
        (All_Registered'Access,
         "65 descriptor waiters did not reach the poller");
      Sockets.Send_Socket (Target_Peer, Payload, Last);
      if Last /= Payload'Last then
         raise Program_Error with "readiness signal was short";
      end if;
      Await
        (Translation_Parked'Access,
         "event loop did not reach poller translation");

      --  Queue the selected, high-priority target last so the first bounded
      --  drain consumes exactly the 64 unrelated cancellations.
      for Item of Waiters loop
         abort Item.all;
      end loop;
      abort Target_Task.all;
      if Fault_Control.Descriptor_Cancel_Queued_Count /= Backlog_Count + 1 then
         raise Program_Error
           with "foreign wakes did not queue all 65 descriptor cancellations";
      end if;

      Fault_Control.Release_Poller_Translation;
      Await
        (Budget_Parked'Access,
         "event loop did not stop after the 64-item cancellation budget");
      if Fault_Control.Descriptor_Cancel_Processed_Count /= Backlog_Count then
         raise Program_Error
           with
             "bounded cancellation drain did not process exactly 64 waiters";
      end if;
      Fault_Control.Release_Descriptor_Cancel_Budget;

      Await
        (Target_Terminated'Access,
         "65th cancellation target did not terminate");
      Await
        (Backlog_Terminated'Access, "cancellation backlog did not terminate");
      Observation.Stop_Runner;

      if Fault_Control.Poller_Cancel_During_Translation_Count /= 0 then
         raise Program_Error
           with
             "foreign Wake mutated the poller during event-loop translation";
      elsif Fault_Control.Descriptor_Cancel_Processed_Count
        /= Backlog_Count + 1
      then
         raise Program_Error
           with "event loop did not consume the 65th queued cancellation";
      elsif Observation.First_Returned then
         raise Program_Error
           with "selected readiness resumed a cancellation-owned waiter";
      elsif Observation.Second_Returned then
         raise Program_Error
           with "stale cancellation reached a replacement wait generation";
      end if;
      Cleanup;
   exception
      when others =>
         Cleanup;
         raise;
   end Run_One;

begin
   if not Fault_Control.Enabled then
      raise Program_Error
        with "abort/readiness test requires FLYOLOGY_TEST_FAULTS=1 runtime";
   end if;
   for Iteration in 1 .. Iterations loop
      Run_One;
   end loop;
end Linux_Abort_Readiness_Waiter_Smoke;
