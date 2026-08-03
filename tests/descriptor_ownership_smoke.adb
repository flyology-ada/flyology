with Ada.Real_Time;
with Ada.Streams;
with GNAT.Sockets;
with Flyology;
with Flyology.Execution_Groups;
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

   procedure Await_Event_Waits
     (Count : Natural;
      Group : Flyology.Execution_Groups.Group_Id := 0)
   is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
      Sample : Flyology.Observability.Group_Snapshot;
   begin
      loop
         if Flyology.Observability.Snapshot (Group, Sample) then
            exit when Sample.Descriptor_Waits =
              Flyology.Observability.Counter (Count);
         end if;
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

   type Adoption_Path is (Take_Path, Accept_Path);

   procedure Run_Close_In_Progress_Re_Adoption
     (Model : Flyology.Execution_Model;
      Path  : Adoption_Path)
   is
      package Groups renames Flyology.Execution_Groups;

      Original_Manager : aliased Connections.Server (Capacity => 1);
      Candidate_Manager : aliased Connections.Server (Capacity => 1);
      Owned : Connections.Connection;
      Original, Original_Peer : Sockets.Socket_Type;
      Candidate, Candidate_Peer : Sockets.Socket_Type;
      Listener : Sockets.Socket_Type := Sockets.No_Socket;

      type Atomic_Boolean is new Boolean with Atomic;
      Spinning          : aliased Atomic_Boolean := False;
      Stop_Spinning     : Atomic_Boolean := False;
      Reader_Done       : aliased Atomic_Boolean := False;
      Reader_Cancelled  : Atomic_Boolean := False;
      Close_Done        : aliased Atomic_Boolean := False;
      Close_OK          : Atomic_Boolean := False;
      Attempt_Done      : aliased Atomic_Boolean := False;
      Attempt_Rejected  : Atomic_Boolean := False;

      protected Spinner_Control is
         procedure Open;
         entry Wait;
      private
         Opened : Boolean := False;
      end Spinner_Control;

      protected body Spinner_Control is
         procedure Open is
         begin
            Opened := True;
         end Open;

         entry Wait when Opened is
         begin
            null;
         end Wait;
      end Spinner_Control;

      procedure Wait_Until (Flag : not null access Atomic_Boolean) is
         Deadline : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
      begin
         while not Flag.all loop
            if Ada.Real_Time.Clock >= Deadline then
               raise Program_Error with "concurrent close test stalled";
            end if;
            delay 0.001;
         end loop;
      end Wait_Until;
   begin
      Sockets.Create_Socket_Pair (Original, Original_Peer);
      if Path = Take_Path then
         Sockets.Create_Socket_Pair (Candidate, Candidate_Peer);
      else
         Candidate := Sockets.No_Socket;
         Sockets.Create_Socket (Listener);
         Sockets.Bind_Socket
           (Listener,
            (Family => Sockets.Family_Inet,
             Addr   => Sockets.Loopback_Inet_Addr,
             Port   => Sockets.Any_Port));
         Sockets.Listen_Socket (Listener);
         Sockets.Create_Socket (Candidate_Peer);
         Sockets.Connect_Socket
           (Candidate_Peer, Sockets.Get_Socket_Name (Listener));
      end if;
      Connections.Take (Original_Manager, Original, Owned);

      declare
         task Reader is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Reader;

         task Spinner is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Spinner;

         task Closer is
            entry Start;
         end Closer;

         task Attempt is
            pragma Task_Info (Model);
            entry Start (Socket : in out Sockets.Socket_Type);
         end Attempt;

         task body Reader is
            Data : Ada.Streams.Stream_Element_Array (1 .. 1);
         begin
            Groups.Migrate (1);
            begin
               Owned.Receive_Exactly (Data);
            exception
               when Connections.Operation_Cancelled =>
                  Reader_Cancelled := True;
            end;
            Reader_Done := True;
         exception
            when others =>
               Reader_Done := True;
         end Reader;

         task body Spinner is
         begin
            Groups.Migrate (1);
            Spinner_Control.Wait;
            Spinning := True;
            while not Stop_Spinning loop
               null;
            end loop;
         end Spinner;

         task body Closer is
         begin
            accept Start;
            begin
               Connections.Close (Owned);
               Close_OK := True;
            exception
               when others =>
                  null;
            end;
            Close_Done := True;
         end Closer;

         task body Attempt is
         begin
            if Model = Flyology.Lightweight_Task then
               Groups.Migrate (2);
            end if;
            accept Start (Socket : in out Sockets.Socket_Type) do
               begin
                  if Path = Take_Path then
                     Connections.Take (Candidate_Manager, Socket, Owned);
                  else
                     declare
                        Peer_Address : Sockets.Sock_Addr_Type;
                     begin
                        Connections.Accept_Connection
                          (Candidate_Manager,
                           Listener,
                           Owned,
                           Peer_Address);
                     end;
                  end if;
               exception
                  when Program_Error =>
                     Attempt_Rejected := True;
                  when others =>
                     null;
               end;
            end Start;
            Attempt_Done := True;
         exception
            when others =>
               Attempt_Done := True;
         end Attempt;
      begin
         Await_Event_Waits (1, 1);
         Spinner_Control.Open;
         Wait_Until (Spinning'Access);

         Closer.Start;
         declare
            Deadline : constant Ada.Real_Time.Time :=
              Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
         begin
            while Connections.Is_Open (Owned) loop
               if Ada.Real_Time.Clock >= Deadline then
                  raise Program_Error with "close did not enter closing state";
               end if;
               delay 0.001;
            end loop;
         end;

         --  Reader cannot release its lease while Spinner monopolizes group 1,
         --  so Is_Open = False above denotes Closing, not a completed close.
         Attempt.Start (Candidate);
         Wait_Until (Attempt_Done'Access);
         Stop_Spinning := True;
         Wait_Until (Reader_Done'Access);
         Wait_Until (Close_Done'Access);
      end;

      pragma Assert (Attempt_Rejected);
      pragma Assert
        ((Path = Take_Path and then Candidate /= Sockets.No_Socket)
         or else (Path = Accept_Path
                  and then Candidate = Sockets.No_Socket));
      pragma Assert (Candidate_Manager.Active = 0);
      pragma Assert (Reader_Cancelled);
      pragma Assert (Close_OK);
      pragma Assert (Original_Manager.Active = 0);
      pragma Assert (not Connections.Is_Open (Owned));

      Sockets.Close_Socket (Original_Peer);
      if Candidate /= Sockets.No_Socket then
         Sockets.Close_Socket (Candidate);
      end if;
      Sockets.Close_Socket (Candidate_Peer);
      if Listener /= Sockets.No_Socket then
         Sockets.Close_Socket (Listener);
      end if;
   end Run_Close_In_Progress_Re_Adoption;

   procedure Run_Competing_Adopters
     (Model : Flyology.Execution_Model)
   is
      package Groups renames Flyology.Execution_Groups;

      First_Manager  : aliased Connections.Server (Capacity => 1);
      Second_Manager : aliased Connections.Server (Capacity => 1);
      Owned : Connections.Connection;
      First, First_Peer : Sockets.Socket_Type;
      Second, Second_Peer : Sockets.Socket_Type;

      protected Control is
         procedure Ready;
         entry Wait_Ready;
         procedure Open;
         entry Gate;
         procedure Finished (Won, Valid : Boolean);
         entry Wait_Finished (Passed : out Boolean);
      private
         Ready_Count    : Natural := 0;
         Opened         : Boolean := False;
         Finished_Count : Natural := 0;
         Winners        : Natural := 0;
         All_Valid      : Boolean := True;
      end Control;

      protected body Control is
         procedure Ready is
         begin
            Ready_Count := Ready_Count + 1;
         end Ready;

         entry Wait_Ready when Ready_Count = 2 is
         begin
            null;
         end Wait_Ready;

         procedure Open is
         begin
            Opened := True;
         end Open;

         entry Gate when Opened is
         begin
            null;
         end Gate;

         procedure Finished (Won, Valid : Boolean) is
         begin
            Finished_Count := Finished_Count + 1;
            if Won then
               Winners := Winners + 1;
            end if;
            All_Valid := All_Valid and Valid;
         end Finished;

         entry Wait_Finished (Passed : out Boolean)
           when Finished_Count = 2
         is
         begin
            Passed := All_Valid and Winners = 1;
         end Wait_Finished;
      end Control;
   begin
      Sockets.Create_Socket_Pair (First, First_Peer);
      Sockets.Create_Socket_Pair (Second, Second_Peer);

      declare
         task First_Adopter is
            pragma Task_Info (Model);
         end First_Adopter;

         task Second_Adopter is
            pragma Task_Info (Model);
         end Second_Adopter;

         task body First_Adopter is
            Won, Valid : Boolean := False;
         begin
            if Model = Flyology.Lightweight_Task then
               Groups.Migrate (1);
            end if;
            Control.Ready;
            Control.Gate;
            begin
               Connections.Take (First_Manager, First, Owned);
               Won := True;
               Valid := True;
            exception
               when Program_Error =>
                  Valid := True;
            end;
            Control.Finished (Won, Valid);
         exception
            when others =>
               Control.Finished (False, False);
         end First_Adopter;

         task body Second_Adopter is
            Won, Valid : Boolean := False;
         begin
            if Model = Flyology.Lightweight_Task then
               Groups.Migrate (2);
            end if;
            Control.Ready;
            Control.Gate;
            begin
               Connections.Take (Second_Manager, Second, Owned);
               Won := True;
               Valid := True;
            exception
               when Program_Error =>
                  Valid := True;
            end;
            Control.Finished (Won, Valid);
         exception
            when others =>
               Control.Finished (False, False);
         end Second_Adopter;

         Passed : Boolean;
      begin
         Control.Wait_Ready;
         Control.Open;
         Control.Wait_Finished (Passed);
         pragma Assert (Passed);
      end;

      if First = Sockets.No_Socket then
         pragma Assert (Second /= Sockets.No_Socket);
         pragma Assert (First_Manager.Active = 1);
         pragma Assert (Second_Manager.Active = 0);
      else
         pragma Assert (Second = Sockets.No_Socket);
         pragma Assert (First_Manager.Active = 0);
         pragma Assert (Second_Manager.Active = 1);
      end if;

      Connections.Close (Owned);
      pragma Assert (First_Manager.Active = 0);
      pragma Assert (Second_Manager.Active = 0);
      if First /= Sockets.No_Socket then
         Sockets.Close_Socket (First);
      end if;
      if Second /= Sockets.No_Socket then
         Sockets.Close_Socket (Second);
      end if;
      Sockets.Close_Socket (First_Peer);
      Sockets.Close_Socket (Second_Peer);
   end Run_Competing_Adopters;

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
   Run_Close_In_Progress_Re_Adoption
     (Flyology.Lightweight_Task, Take_Path);
   Run_Close_In_Progress_Re_Adoption
     (Flyology.Native_Task, Take_Path);
   Run_Close_In_Progress_Re_Adoption
     (Flyology.Lightweight_Task, Accept_Path);
   Run_Close_In_Progress_Re_Adoption
     (Flyology.Native_Task, Accept_Path);
   Run_Competing_Adopters (Flyology.Lightweight_Task);
   Run_Competing_Adopters (Flyology.Native_Task);
   Run_Exclusive_Waiters;
   Run_Timeout_Close_Reuse;
   Run_Timeout_Readiness_Races (Flyology.Lightweight_Task);
   Run_Timeout_Readiness_Races (Flyology.Native_Task);
   Sockets.Finalize;
end Descriptor_Ownership_Smoke;
