with Ada.Real_Time;
with Ada.Streams;
with Flyology;
with Flyology.Execution_Groups;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with Flyology.IO.Structured_Servers;
with System.Multiprocessors;

procedure Structured_Server_Smoke is
   package Connections renames Flyology.IO.Connections;
   package Sockets renames Flyology.IO.Sockets;

   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Array;
   use type Flyology.IO.Descriptor;
   use type Flyology.Execution_Groups.Group_Id;
   use type Flyology.Execution_Model;

   procedure Open_Listener
     (Listener : in out Sockets.Socket_Type;
      Address  : out Sockets.Endpoint)
   is
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Set_Socket_Option
        (Listener,
         Sockets.Socket_Level,
         (Sockets.Reuse_Address, True));
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint
           (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener, Length => 32);
      Address := Sockets.Get_Socket_Name (Listener);
   end Open_Listener;

   generic
      Model : Flyology.Execution_Model;
      CPU   : System.Multiprocessors.CPU_Range;
   procedure Run_Lane;

   procedure Run_Lane is
      type Handler_Mode is (Gated_Echo, Draining_Read, Failing);

      protected type Tracker is
         procedure Handler_Entered;
         procedure Client_Ready;
         procedure Release_Gate;
         entry Await_Gate;
         function Handler_Count return Natural;
         function Ready_Clients return Natural;
      private
         Handlers : Natural := 0;
         Clients  : Natural := 0;
         Released : Boolean := False;
      end Tracker;

      protected body Tracker is
         procedure Handler_Entered is
         begin
            Handlers := Handlers + 1;
         end Handler_Entered;

         procedure Client_Ready is
         begin
            Clients := Clients + 1;
         end Client_Ready;

         procedure Release_Gate is
         begin
            Released := True;
         end Release_Gate;

         entry Await_Gate when Released is
         begin
            null;
         end Await_Gate;

         function Handler_Count return Natural is (Handlers);
         function Ready_Clients return Natural is (Clients);
      end Tracker;

      type Context is limited record
         Mode  : Handler_Mode;
         State : Tracker;
      end record;

      procedure Handle
        (State        : in out Context;
         Connection   : in out Connections.Connection;
         Peer         : Sockets.Endpoint;
         Cancellation : not null access Connections.Cancellation_Token)
      is
         Data : Ada.Streams.Stream_Element_Array (1 .. 1);
         pragma Unreferenced (Peer);
      begin
         if Model = Flyology.Lightweight_Task then
            pragma Assert
              (Flyology.Execution_Groups.Current =
                 Flyology.Execution_Groups.Group_Id (CPU));
         end if;
         State.State.Handler_Entered;
         case State.Mode is
            when Gated_Echo =>
               State.State.Await_Gate;
               Connection.Receive_Exactly
                 (Data, Timeout => 1.0, Token => Cancellation);
               Connection.Send_All
                 (Data, Timeout => 1.0, Token => Cancellation);
            when Draining_Read =>
               Connection.Receive_Exactly
                 (Data, Timeout => 2.0, Token => Cancellation);
            when Failing =>
               raise Program_Error with "deliberate handler failure";
         end case;
      end Handle;

      package Structured is new Flyology.IO.Structured_Servers
        (Handler_Context => Context,
         Handle          => Handle,
         Handler_Model   => Model,
         Handler_CPU     => CPU);

      use type Structured.Failure_Origin;

      procedure Wait_Until
        (Condition : not null access function return Boolean;
         Message   : String)
      is
         Deadline : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
      begin
         while not Condition.all loop
            if Ada.Real_Time.Clock >= Deadline then
               raise Program_Error with Message;
            end if;
            delay 0.001;
         end loop;
      end Wait_Until;

      procedure Run_Overload is
         Item     : aliased Structured.Server (Capacity => 2);
         State    : aliased Context := (Mode => Gated_Echo, others => <>);
         Listener : Sockets.Socket_Type;
         Address  : Sockets.Endpoint;

         protected Results is
            procedure Report (OK : Boolean);
            function Count return Natural;
            function Passed return Boolean;
         private
            Done : Natural := 0;
            All_OK : Boolean := True;
         end Results;

         protected body Results is
            procedure Report (OK : Boolean) is
            begin
               Done := Done + 1;
               All_OK := All_OK and OK;
            end Report;
            function Count return Natural is (Done);
            function Passed return Boolean is (All_OK);
         end Results;

         function Two_Handlers return Boolean is
           (State.State.Handler_Count = 2);
         function All_Clients return Boolean is (Results.Count = 4);
      begin
         Open_Listener (Listener, Address);
         declare
            task Runner;
            task type Client is
               pragma Task_Info (Flyology.Native_Task);
            end Client;

            task body Runner is
            begin
               Structured.Serve
                 (Item, Listener, State, Drain_Timeout => 0.5);
            end Runner;

            task body Client is
               Socket : Sockets.Socket_Type;
               Sent   : constant Ada.Streams.Stream_Element_Array (1 .. 1) :=
                 (1 => 42);
               Got    : Ada.Streams.Stream_Element_Array (1 .. 1);
            begin
               Sockets.Create_Socket (Socket);
               Flyology.IO.Sockets.Connect (Socket, Address, Timeout => 1.0);
               Flyology.IO.Sockets.Send_All (Socket, Sent, Timeout => 1.0);
               Flyology.IO.Sockets.Receive_Exactly
                 (Socket, Got, Timeout => 2.0);
               Results.Report (Got = Sent);
               Sockets.Close_Socket (Socket);
            exception
               when others =>
                  Results.Report (False);
            end Client;

            Clients : array (1 .. 4) of Client;
            pragma Unreferenced (Clients);
         begin
            begin
               Wait_Until (Two_Handlers'Access,
                           "capacity did not admit two handlers");
               declare
                  Sample : constant Structured.Snapshot :=
                    Structured.Current (Item);
               begin
                  pragma Assert (Sample.Active_Handlers = 2);
                  pragma Assert (Sample.Accepted_Connections = 2);
               end;
               delay 0.020;
               pragma Assert
                 (Structured.Current (Item).Accepted_Connections = 2);
               State.State.Release_Gate;
               Wait_Until
                 (All_Clients'Access, "overload clients did not drain");
               Structured.Request_Shutdown (Item);
            exception
               when others =>
                  --  A failed observation must not leave handlers behind the
                  --  test gate while the enclosing master completes.
                  State.State.Release_Gate;
                  Structured.Request_Shutdown (Item);
                  raise;
            end;
         end;
         pragma Assert (not Sockets.Is_Open (Listener));
         pragma Assert (Results.Passed);
         declare
            Sample : constant Structured.Snapshot := Structured.Current (Item);
         begin
            pragma Assert (not Sample.Running);
            pragma Assert (Sample.Accepted_Connections = 4);
            pragma Assert (Sample.Completed_Connections = 4);
            pragma Assert (Sample.Active_Handlers = 0);
            pragma Assert (not Sample.Forced_Cancellation);
         end;
      end Run_Overload;

      procedure Run_Graceful_Drain is
         Item     : aliased Structured.Server (Capacity => 1);
         State    : aliased Context := (Mode => Draining_Read, others => <>);
         Listener : Sockets.Socket_Type;
         Address  : Sockets.Endpoint;

         function Handler_Active return Boolean is
           (State.State.Handler_Count = 1);
      begin
         Open_Listener (Listener, Address);
         declare
            task Runner;
            task Client is
               pragma Task_Info (Flyology.Native_Task);
            end Client;

            task body Runner is
            begin
               Structured.Serve
                 (Item, Listener, State, Drain_Timeout => 0.5);
            end Runner;

            task body Client is
               Socket : Sockets.Socket_Type;
               Data   : constant Ada.Streams.Stream_Element_Array (1 .. 1) :=
                 (1 => 7);
            begin
               Sockets.Create_Socket (Socket);
               Flyology.IO.Sockets.Connect (Socket, Address, Timeout => 1.0);
               State.State.Client_Ready;
               State.State.Await_Gate;
               Flyology.IO.Sockets.Send_All (Socket, Data, Timeout => 1.0);
               Sockets.Close_Socket (Socket);
            end Client;
         begin
            begin
               Wait_Until (Handler_Active'Access,
                           "draining handler was not admitted");
               Structured.Request_Shutdown (Item);
               delay 0.020;
               pragma Assert (Structured.Current (Item).Active_Handlers = 1);
               State.State.Release_Gate;
            exception
               when others =>
                  State.State.Release_Gate;
                  Structured.Request_Shutdown (Item);
                  raise;
            end;
         end;
         declare
            Sample : constant Structured.Snapshot := Structured.Current (Item);
         begin
            pragma Assert (Sample.Completed_Connections = 1);
            pragma Assert (Sample.Cancelled_Connections = 0);
            pragma Assert (not Sample.Forced_Cancellation);
         end;
      end Run_Graceful_Drain;

      procedure Run_Deadline_Cancel is
         Item     : aliased Structured.Server (Capacity => 1);
         State    : aliased Context := (Mode => Draining_Read, others => <>);
         Listener : Sockets.Socket_Type;
         Address  : Sockets.Endpoint;

         function Handler_Active return Boolean is
           (State.State.Handler_Count = 1);

         function Forced_Cancellation_Completed return Boolean is
            Sample : constant Structured.Snapshot := Structured.Current (Item);
         begin
            return Sample.Forced_Cancellation
              and then Sample.Active_Handlers = 0;
         end Forced_Cancellation_Completed;
      begin
         Open_Listener (Listener, Address);
         declare
            task Runner;
            task Client is
               pragma Task_Info (Flyology.Native_Task);
            end Client;

            task body Runner is
            begin
               Structured.Serve
                 (Item, Listener, State, Drain_Timeout => 0.020);
            end Runner;

            task body Client is
               Socket : Sockets.Socket_Type;
            begin
               Sockets.Create_Socket (Socket);
               Flyology.IO.Sockets.Connect (Socket, Address, Timeout => 1.0);
               State.State.Await_Gate;
               Sockets.Close_Socket (Socket);
            end Client;
         begin
            Wait_Until (Handler_Active'Access,
                        "cancellable handler was not admitted");
            Structured.Request_Shutdown (Item);
            Wait_Until
              (Forced_Cancellation_Completed'Access,
               "drain deadline did not complete handler cancellation");
            State.State.Release_Gate;
         end;
         declare
            Sample : constant Structured.Snapshot := Structured.Current (Item);
         begin
            pragma Assert (Sample.Forced_Cancellation);
            pragma Assert (Sample.Cancelled_Connections = 1);
            pragma Assert (Sample.Active_Handlers = 0);
         end;
      end Run_Deadline_Cancel;

      procedure Run_Failure is
         Item     : aliased Structured.Server (Capacity => 1);
         State    : aliased Context := (Mode => Failing, others => <>);
         Listener : Sockets.Socket_Type;
         Address  : Sockets.Endpoint;
         Propagated : Boolean := False with Atomic;
      begin
         Open_Listener (Listener, Address);
         declare
            task Runner;
            task Client is
               pragma Task_Info (Flyology.Native_Task);
            end Client;

            task body Runner is
            begin
               begin
                  Structured.Serve
                    (Item, Listener, State, Drain_Timeout => 0.2);
               exception
                  when Structured.Server_Failed =>
                     Propagated := True;
               end;
            end Runner;

            task body Client is
               Socket : Sockets.Socket_Type;
            begin
               Sockets.Create_Socket (Socket);
               Flyology.IO.Sockets.Connect (Socket, Address, Timeout => 1.0);
               delay 0.020;
               Sockets.Close_Socket (Socket);
            end Client;
         begin
            null;
         end;
         pragma Assert (Propagated);
         pragma Assert (Structured.Current (Item).Failures = 1);
         pragma Assert
           (Structured.Current (Item).First_Failure =
              Structured.Handler_Callback);
         pragma Assert
           (Structured.First_Failure_Information (Item)'Length > 0);
      end Run_Failure;

      procedure Run_Concurrent_Idle_Shutdown_And_Reuse is
         Item     : aliased Structured.Server (Capacity => 1);
         State    : aliased Context := (Mode => Draining_Read, others => <>);
         Listener : Sockets.Socket_Type;
         Address  : Sockets.Endpoint;
         Old_FD   : Flyology.IO.Descriptor;

         function Is_Running return Boolean is
           (Structured.Current (Item).Running);
      begin
         Open_Listener (Listener, Address);
         Old_FD := Flyology.IO.Sockets.Native_Descriptor (Listener);
         declare
            task Runner;
            task First_Stop is entry Go; end First_Stop;
            task Second_Stop is entry Go; end Second_Stop;

            task body Runner is
            begin
               Structured.Serve
                 (Item, Listener, State, Drain_Timeout => 0.2);
            end Runner;

            task body First_Stop is
            begin
               accept Go;
               Structured.Request_Shutdown (Item);
            end First_Stop;

            task body Second_Stop is
            begin
               accept Go;
               Structured.Request_Shutdown (Item);
            end Second_Stop;
         begin
            Wait_Until (Is_Running'Access, "server did not enter accept");
            delay 0.020;
            First_Stop.Go;
            Second_Stop.Go;
         end;
         pragma Assert (not Sockets.Is_Open (Listener));
         declare
            Reused : Sockets.Socket_Type;
         begin
            Sockets.Create_Socket (Reused);
            pragma Assert
              (Flyology.IO.Sockets.Native_Descriptor (Reused) = Old_FD);
            Sockets.Close_Socket (Reused);
         end;
         pragma Assert (Structured.Current (Item).Active_Handlers = 0);
         pragma Assert
           (Structured.Current (Item).Accepted_Connections = 0);
      end Run_Concurrent_Idle_Shutdown_And_Reuse;

      procedure Run_Pre_Requested_Shutdown is
         Item     : aliased Structured.Server (Capacity => 4);
         State    : aliased Context := (Mode => Draining_Read, others => <>);
         Listener : Sockets.Socket_Type;
         Address  : Sockets.Endpoint;
      begin
         Open_Listener (Listener, Address);
         Structured.Request_Shutdown (Item);
         Structured.Request_Shutdown (Item);
         Structured.Serve
           (Item, Listener, State, Drain_Timeout => 0.1);
         pragma Assert (not Sockets.Is_Open (Listener));
         declare
            Sample : constant Structured.Snapshot := Structured.Current (Item);
         begin
            pragma Assert (not Sample.Running);
            pragma Assert (Sample.Shutdown_Requested);
            pragma Assert (Sample.Accepted_Connections = 0);
            pragma Assert (Sample.Active_Handlers = 0);
            pragma Assert (not Sample.Forced_Cancellation);
         end;
      end Run_Pre_Requested_Shutdown;
   begin
      Run_Overload;
      Run_Graceful_Drain;
      Run_Deadline_Cancel;
      Run_Failure;
      Run_Concurrent_Idle_Shutdown_And_Reuse;
      Run_Pre_Requested_Shutdown;
   end Run_Lane;

   procedure Run_Lightweight is new Run_Lane
     (Model => Flyology.Lightweight_Task,
      CPU   => 1);
   procedure Run_Native is new Run_Lane
     (Model => Flyology.Native_Task,
      CPU   => System.Multiprocessors.Not_A_Specific_CPU);
begin
   Run_Lightweight;
   Run_Native;
end Structured_Server_Smoke;
