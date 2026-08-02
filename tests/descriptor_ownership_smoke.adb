with Ada.Real_Time;
with Ada.Streams;
with GNAT.Sockets;
with Flyology;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with Flyology.Observability;
with Interfaces;
with Interfaces.C;

procedure Descriptor_Ownership_Smoke is
   package Connections renames Flyology.IO.Connections;
   package Sockets renames GNAT.Sockets;

   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Streams.Stream_Element_Array;
   use type Ada.Real_Time.Time;
   use type Flyology.Execution_Model;
   use type Flyology.Observability.Counter;
   use type Interfaces.C.int;
   use type Sockets.Socket_Type;

   procedure Assert_No_Event_Waits is
      Sample : Flyology.Observability.Group_Snapshot;
   begin
      pragma Assert (Flyology.Observability.Snapshot (0, Sample));
      pragma Assert (Sample.Descriptor_Waits = 0);
      pragma Assert (Sample.Interrupt_Waits = 0);
   end Assert_No_Event_Waits;

   procedure Await_Event_Waits (Count : Natural) is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
      Sample : Flyology.Observability.Group_Snapshot;
   begin
      loop
         pragma Assert (Flyology.Observability.Snapshot (0, Sample));
         exit when Sample.Descriptor_Waits =
           Flyology.Observability.Counter (Count);
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "descriptor wait did not reach poller";
         end if;
         delay 0.001;
      end loop;
   end Await_Event_Waits;

   procedure Run_Close_Reuse (Model : Flyology.Execution_Model) is
      Manager : aliased Connections.Server (Capacity => 1);
      Owned   : Connections.Connection;
      Server, Peer : Sockets.Socket_Type;
      Old_FD : Flyology.IO.Descriptor;

      protected Progress is
         procedure Entering;
         procedure Finished (Cancelled : Boolean);
         entry Wait_Entering;
         entry Wait_Finished;
         function Passed return Boolean;
      private
         Has_Entered : Boolean := False;
         Has_Finished : Boolean := False;
         OK : Boolean := False;
      end Progress;

      protected body Progress is
         procedure Entering is
         begin
            Has_Entered := True;
         end Entering;
         procedure Finished (Cancelled : Boolean) is
         begin
            OK := Cancelled;
            Has_Finished := True;
         end Finished;
         entry Wait_Entering when Has_Entered is begin null; end Wait_Entering;
         entry Wait_Finished when Has_Finished is begin null; end Wait_Finished;
         function Passed return Boolean is (OK);
      end Progress;
   begin
      Sockets.Create_Socket_Pair (Server, Peer);
      Old_FD := Flyology.IO.Sockets.Native_Descriptor (Server);
      Connections.Take (Manager, Server, Owned);
      pragma Assert (Server = Sockets.No_Socket);

      declare
         task Reader is
            pragma Task_Info (Model);
         end Reader;

         task body Reader is
            Data : Ada.Streams.Stream_Element_Array (1 .. 1);
            Cancelled : Boolean := False;
         begin
            Progress.Entering;
            begin
               Owned.Receive_Exactly (Data);
            exception
               when Connections.Operation_Cancelled =>
                  Cancelled := True;
            end;
            Progress.Finished (Cancelled);
         exception
            when others =>
               Progress.Finished (False);
         end Reader;
      begin
         Progress.Wait_Entering;
         if Model = Flyology.Lightweight_Task then
            Await_Event_Waits (1);
         else
            --  The native lane cannot be inspected through group snapshots;
            --  give its newly activated pthread time to enter poll(2).
            delay 0.050;
         end if;
         Owned.Close;
         Progress.Wait_Finished;
      end;

      pragma Assert (Progress.Passed);
      pragma Assert (Manager.Active = 0);

      --  The lowest descriptor is reused immediately. Close could only have
      --  returned after the old generation removed its poller registration.
      declare
         New_Server, New_Peer : Sockets.Socket_Type;
         Sent, Last : Ada.Streams.Stream_Element_Offset;
         Outgoing : constant Ada.Streams.Stream_Element_Array (1 .. 1) :=
           (1 => 73);
         Incoming : Ada.Streams.Stream_Element_Array (1 .. 1);
         Reuse_OK : Boolean := False with Atomic;
      begin
         Sockets.Create_Socket_Pair (New_Server, New_Peer);
         pragma Assert
           (Flyology.IO.Sockets.Native_Descriptor (New_Server) = Old_FD);
         declare
            task Reused_Reader is
               pragma Task_Info (Model);
            end Reused_Reader;
            task body Reused_Reader is
            begin
               if Flyology.IO.Wait (Old_FD, Flyology.IO.For_Read, 0.5) then
                  Sockets.Receive_Socket (New_Server, Incoming, Last);
                  Reuse_OK :=
                    Last = Incoming'Last and then Incoming = Outgoing;
               end if;
            exception
               when others =>
                  Reuse_OK := False;
            end Reused_Reader;
         begin
            if Model = Flyology.Lightweight_Task then
               Await_Event_Waits (1);
            else
               delay 0.050;
            end if;
            Sockets.Send_Socket (New_Peer, Outgoing, Sent);
            pragma Assert (Sent = Outgoing'Last);
         end;
         pragma Assert (Reuse_OK);
         Sockets.Close_Socket (New_Server);
         Sockets.Close_Socket (New_Peer);
      end;
      Sockets.Close_Socket (Peer);
      if Model = Flyology.Lightweight_Task then
         Assert_No_Event_Waits;
      end if;
   end Run_Close_Reuse;

   procedure Run_Cancellation_Close_Race
     (Model : Flyology.Execution_Model)
   is
      Manager : aliased Connections.Server (Capacity => 1);
      Token   : aliased Connections.Cancellation_Token;
      Owned   : Connections.Connection;
      Server, Peer : Sockets.Socket_Type;

      protected Progress is
         procedure Entering;
         procedure Finished (Cancelled : Boolean);
         entry Wait_Entering;
         entry Wait_Finished;
         function Passed return Boolean;
      private
         Entered, Done, OK : Boolean := False;
      end Progress;

      protected body Progress is
         procedure Entering is begin Entered := True; end Entering;
         procedure Finished (Cancelled : Boolean) is
         begin
            OK := Cancelled;
            Done := True;
         end Finished;
         entry Wait_Entering when Entered is begin null; end Wait_Entering;
         entry Wait_Finished when Done is begin null; end Wait_Finished;
         function Passed return Boolean is (OK);
      end Progress;
   begin
      Sockets.Create_Socket_Pair (Server, Peer);
      Connections.Take (Manager, Server, Owned);
      declare
         task Reader is
            pragma Task_Info (Model);
         end Reader;
         task Requester is
            entry Go;
         end Requester;

         task body Reader is
            Data : Ada.Streams.Stream_Element_Array (1 .. 1);
            Cancelled : Boolean := False;
         begin
            Progress.Entering;
            begin
               Owned.Receive_Exactly (Data, Token => Token'Access);
            exception
               when Connections.Operation_Cancelled =>
                  Cancelled := True;
            end;
            Progress.Finished (Cancelled);
         exception
            when others =>
               Progress.Finished (False);
         end Reader;

         task body Requester is
         begin
            accept Go;
            Token.Request;
         end Requester;
      begin
         Progress.Wait_Entering;
         if Model = Flyology.Lightweight_Task then
            Await_Event_Waits (1);
         else
            delay 0.050;
         end if;
         Requester.Go;
         Owned.Close;
         Progress.Wait_Finished;
      end;
      pragma Assert (Progress.Passed);
      pragma Assert (Manager.Active = 0);
      Sockets.Close_Socket (Peer);
      if Model = Flyology.Lightweight_Task then
         Assert_No_Event_Waits;
      end if;
   end Run_Cancellation_Close_Race;

   procedure Run_Exclusive_Waiters is
      Manager : aliased Connections.Server (Capacity => 1);
      Owned   : Connections.Connection;
      Server, Peer : Sockets.Socket_Type;

      protected Progress is
         procedure Finished (Index : Positive; Value : Ada.Streams.Stream_Element);
         entry Wait;
         function Passed return Boolean;
      private
         Count : Natural := 0;
         Seen_First, Seen_Second : Boolean := False;
      end Progress;

      protected body Progress is
         procedure Finished
           (Index : Positive; Value : Ada.Streams.Stream_Element)
         is
         begin
            if Index = 1 then
               Seen_First := Value in 1 | 2;
            else
               Seen_Second := Value in 1 | 2;
            end if;
            Count := Count + 1;
         end Finished;
         entry Wait when Count = 2 is begin null; end Wait;
         function Passed return Boolean is (Seen_First and Seen_Second);
      end Progress;
   begin
      Sockets.Create_Socket_Pair (Server, Peer);
      Connections.Take (Manager, Server, Owned);
      declare
         task type Reader (Index : Positive) is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Reader;
         task body Reader is
            Data : Ada.Streams.Stream_Element_Array (1 .. 1);
         begin
            Owned.Receive_Exactly (Data);
            Progress.Finished (Index, Data (Data'First));
         end Reader;
         First : Reader (1);
         Second : Reader (2);
         pragma Unreferenced (First, Second);
      begin
         Await_Event_Waits (1);
         declare
            Data : constant Ada.Streams.Stream_Element_Array (1 .. 2) :=
              (1, 2);
            Last : Ada.Streams.Stream_Element_Offset;
         begin
            Sockets.Send_Socket (Peer, Data, Last);
            pragma Assert (Last = Data'Last);
         end;
         Progress.Wait;
      end;
      pragma Assert (Progress.Passed);
      Owned.Close;
      Sockets.Close_Socket (Peer);
      Assert_No_Event_Waits;
   end Run_Exclusive_Waiters;

   procedure Run_Timeout_Close_Reuse is
      Server, Peer : Sockets.Socket_Type;
      Old_FD : Flyology.IO.Descriptor;
      Timed_Out : Boolean := False with Atomic;
   begin
      Sockets.Create_Socket_Pair (Server, Peer);
      Old_FD := Flyology.IO.Sockets.Native_Descriptor (Server);
      declare
         task Waiter is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Waiter;
         task body Waiter is
         begin
            Timed_Out := not Flyology.IO.Wait
              (Old_FD, Flyology.IO.For_Read, Timeout => 0.020);
         end Waiter;
      begin
         null;
      end;
      pragma Assert (Timed_Out);
      Assert_No_Event_Waits;
      Sockets.Close_Socket (Server);
      Sockets.Close_Socket (Peer);

      declare
         New_Server, New_Peer : Sockets.Socket_Type;
         Ready : Boolean := False with Atomic;
         Data : constant Ada.Streams.Stream_Element_Array (1 .. 1) :=
           (1 => 42);
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Sockets.Create_Socket_Pair (New_Server, New_Peer);
         pragma Assert
           (Flyology.IO.Sockets.Native_Descriptor (New_Server) = Old_FD);
         declare
            task Reused_Waiter is
               pragma Task_Info (Flyology.Lightweight_Task);
            end Reused_Waiter;
            task body Reused_Waiter is
            begin
               Ready := Flyology.IO.Wait
                 (Old_FD, Flyology.IO.For_Read, Timeout => 0.5);
            end Reused_Waiter;
         begin
            Await_Event_Waits (1);
            Sockets.Send_Socket (New_Peer, Data, Last);
         end;
         pragma Assert (Ready);
         Sockets.Close_Socket (New_Server);
         Sockets.Close_Socket (New_Peer);
      end;
      Assert_No_Event_Waits;
   end Run_Timeout_Close_Reuse;

   procedure Run_Timeout_Readiness_Races
     (Model : Flyology.Execution_Model)
   is
   begin
      for Iteration in 1 .. 12 loop
         declare
            Manager : aliased Connections.Server (Capacity => 1);
            Owned   : Connections.Connection;
            Server, Peer : Sockets.Socket_Type;
            Finished : Boolean := False;
         begin
            Sockets.Create_Socket_Pair (Server, Peer);
            Connections.Take (Manager, Server, Owned);
            declare
               task Reader is
                  pragma Task_Info (Model);
               end Reader;
               task Writer;

               task body Reader is
                  Data : Ada.Streams.Stream_Element_Array (1 .. 1);
               begin
                  begin
                     Owned.Receive_Exactly (Data, Timeout => 0.004);
                  exception
                     when Flyology.IO.Timeout_Error =>
                        null;
                  end;
                  Finished := True;
               end Reader;

               task body Writer is
                  Data : constant Ada.Streams.Stream_Element_Array
                    (1 .. 1) := (1 => 9);
                  Last : Ada.Streams.Stream_Element_Offset;
               begin
                  delay (if Iteration mod 2 = 0 then 0.002 else 0.006);
                  Sockets.Send_Socket (Peer, Data, Last);
               exception
                  when Sockets.Socket_Error =>
                     null;
               end Writer;
               pragma Unreferenced (Reader, Writer);
            begin
               null;
            end;
            pragma Assert (Finished);
            Owned.Close;
            Sockets.Close_Socket (Peer);
         end;
      end loop;
      if Model = Flyology.Lightweight_Task then
         Assert_No_Event_Waits;
      end if;
   end Run_Timeout_Readiness_Races;

begin
   Sockets.Initialize;
   Run_Close_Reuse (Flyology.Lightweight_Task);
   Run_Close_Reuse (Flyology.Native_Task);
   Run_Cancellation_Close_Race (Flyology.Lightweight_Task);
   Run_Cancellation_Close_Race (Flyology.Native_Task);
   Run_Exclusive_Waiters;
   Run_Timeout_Close_Reuse;
   Run_Timeout_Readiness_Races (Flyology.Lightweight_Task);
   Run_Timeout_Readiness_Races (Flyology.Native_Task);
   Sockets.Finalize;
end Descriptor_Ownership_Smoke;
