with Ada.Real_Time;
with Ada.Streams;
with Fault_Control;
with Flyology;
with Flyology.IO;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with Flyology.IO.Structured_Servers;
with System.Multiprocessors;

procedure Accept_Transient_Smoke is
   package Connections renames Flyology.IO.Connections;
   package Sockets renames Flyology.IO.Sockets;

   use type Ada.Real_Time.Time;
   use type Ada.Real_Time.Time_Span;
   use type Ada.Streams.Stream_Element_Array;
   use type Fault_Control.Point;

   Injected_Count : constant Positive := 4;

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
      Sockets.Listen_Socket (Listener, Length => 16);
      Address := Sockets.Get_Socket_Name (Listener);
   end Open_Listener;

   procedure Await_Calls
     (At_Point : Fault_Control.Point;
      Count    : Positive)
   is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
   begin
      while Fault_Control.Calls (At_Point) < Count loop
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "accept fault was not reached";
         end if;
         delay 0.001;
      end loop;
   end Await_Calls;

   generic
      Model : Flyology.Execution_Model;
      CPU   : System.Multiprocessors.CPU_Range;
   procedure Run_Lane;

   procedure Run_Lane is
      protected type Tracker is
         procedure Handled;
         function Count return Natural;
      private
         Total : Natural := 0;
      end Tracker;

      protected body Tracker is
         procedure Handled is
         begin
            Total := Total + 1;
         end Handled;

         function Count return Natural is (Total);
      end Tracker;

      type Context is limited record
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
         Connection.Receive_Exactly
           (Data, Timeout => 1.0, Token => Cancellation);
         Connection.Send_All
           (Data, Timeout => 1.0, Token => Cancellation);
         State.State.Handled;
      end Handle;

      package Structured is new Flyology.IO.Structured_Servers
        (Handler_Context => Context,
         Handle          => Handle,
         Handler_Model   => Model,
         Handler_CPU     => CPU);

      use type Structured.Failure_Origin;

      procedure Run_Recovery (At_Point : Fault_Control.Point) is
         Item       : aliased Structured.Server (Capacity => 1);
         State      : aliased Context;
         Listener   : Sockets.Socket_Type;
         Address    : Sockets.Endpoint;
         Failed     : Boolean := False with Atomic;
         Client_OK  : Boolean := False with Atomic;
      begin
         Open_Listener (Listener, Address);
         Fault_Control.Reset;
         Fault_Control.Arm (At_Point, Count => Injected_Count);
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
                  when others =>
                     Failed := True;
               end;
            end Runner;

            task body Client is
               Socket : Sockets.Socket_Type;
               Sent   : constant Ada.Streams.Stream_Element_Array (1 .. 1) :=
                 (1 => 73);
               Got    : Ada.Streams.Stream_Element_Array (1 .. 1);
            begin
               Sockets.Create_Socket (Socket);
               Flyology.IO.Sockets.Connect (Socket, Address, Timeout => 1.0);
               Flyology.IO.Sockets.Send_All (Socket, Sent, Timeout => 1.0);
               Flyology.IO.Sockets.Receive_Exactly
                 (Socket, Got, Timeout => 1.0);
               Client_OK := Got = Sent;
               Sockets.Close_Socket (Socket);
               Structured.Request_Shutdown (Item);
            exception
               when others =>
                  if Sockets.Is_Open (Socket) then
                     Sockets.Close_Socket (Socket);
                  end if;
                  Structured.Request_Shutdown (Item);
            end Client;
         begin
            null;
         end;

         pragma Assert (not Failed);
         pragma Assert (Client_OK);
         pragma Assert (State.State.Count = 1);
         pragma Assert
           (Fault_Control.Calls (At_Point) >= Injected_Count);
         declare
            Sample : constant Structured.Snapshot := Structured.Current (Item);
         begin
            pragma Assert (Sample.Failures = 0);
            pragma Assert (Sample.Accepted_Connections = 1);
            pragma Assert (Sample.Completed_Connections = 1);
         end;
         Fault_Control.Reset;
      end Run_Recovery;

      procedure Run_Pressure_Shutdown is
         Item       : aliased Structured.Server (Capacity => 1);
         State      : aliased Context;
         Listener   : Sockets.Socket_Type;
         Address    : Sockets.Endpoint;
         Failed     : Boolean := False with Atomic;
         Started    : Ada.Real_Time.Time;
      begin
         Open_Listener (Listener, Address);
         Fault_Control.Reset;
         Fault_Control.Arm
           (Fault_Control.Accept_Process_File_Limit, Count => 1_000_000);
         declare
            task Runner;

            task body Runner is
            begin
               begin
                  Structured.Serve
                    (Item, Listener, State, Drain_Timeout => 0.2);
               exception
                  when others =>
                     Failed := True;
               end;
            end Runner;
         begin
            Await_Calls (Fault_Control.Accept_Process_File_Limit, 2);
            Started := Ada.Real_Time.Clock;
            Structured.Request_Shutdown (Item);
         end;

         pragma Assert (not Failed);
         pragma Assert
           (Ada.Real_Time.Clock - Started < Ada.Real_Time.Seconds (1));
         pragma Assert
           (Fault_Control.Calls (Fault_Control.Accept_Process_File_Limit) <
              100);
         pragma Assert (Structured.Current (Item).Failures = 0);
         pragma Assert
           (Structured.Current (Item).Accepted_Connections = 0);
         Fault_Control.Reset;
      end Run_Pressure_Shutdown;

      procedure Run_Deadline is
         Listener  : Sockets.Socket_Type;
         Address   : Sockets.Endpoint;
         Timed_Out : Boolean := False with Atomic;
      begin
         Open_Listener (Listener, Address);
         Fault_Control.Reset;
         Fault_Control.Arm
           (Fault_Control.Accept_System_File_Limit, Count => 1_000_000);
         declare
            task Acceptor is
               pragma Task_Info (Model);
            end Acceptor;

            task body Acceptor is
               Accepted : Sockets.Socket_Type;
               Peer     : Sockets.Endpoint;
            begin
               begin
                  Flyology.IO.Sockets.Accept_Connection
                    (Listener, Accepted, Peer, Timeout => 0.020);
               exception
                  when Flyology.IO.Timeout_Error =>
                     Timed_Out := True;
               end;
               if Sockets.Is_Open (Accepted) then
                  Sockets.Close_Socket (Accepted);
               end if;
            end Acceptor;
         begin
            null;
         end;
         Sockets.Close_Socket (Listener);
         pragma Assert (Timed_Out);
         pragma Assert
           (Fault_Control.Calls (Fault_Control.Accept_System_File_Limit) <
              100);
         Fault_Control.Reset;
      end Run_Deadline;

      procedure Run_Structural_Failure is
         Item       : aliased Structured.Server (Capacity => 1);
         State      : aliased Context;
         Listener   : Sockets.Socket_Type;
         Address    : Sockets.Endpoint;
         Propagated : Boolean := False;
      begin
         Open_Listener (Listener, Address);
         Fault_Control.Reset;
         Fault_Control.Arm (Fault_Control.Accept_Bad_Descriptor);
         begin
            Structured.Serve
              (Item, Listener, State, Drain_Timeout => 0.2);
         exception
            when Structured.Server_Failed =>
               Propagated := True;
         end;
         pragma Assert (Propagated);
         pragma Assert (Structured.Current (Item).Failures = 1);
         pragma Assert
           (Structured.Current (Item).First_Failure =
              Structured.Admission_Loop);
         Fault_Control.Reset;
      end Run_Structural_Failure;
   begin
      Run_Recovery (Fault_Control.Accept_Connection_Aborted);
      Run_Recovery (Fault_Control.Accept_Protocol_Error);
      Run_Recovery (Fault_Control.Accept_Process_File_Limit);
      Run_Recovery (Fault_Control.Accept_System_File_Limit);
      Run_Pressure_Shutdown;
      Run_Deadline;
      Run_Structural_Failure;
   end Run_Lane;

   procedure Run_Lightweight is new Run_Lane
     (Model => Flyology.Lightweight_Task,
      CPU   => 1);
   procedure Run_Native is new Run_Lane
     (Model => Flyology.Native_Task,
      CPU   => System.Multiprocessors.Not_A_Specific_CPU);
begin
   if not Fault_Control.Enabled then
      raise Program_Error with
        "accept transient test requires FLYOLOGY_TEST_FAULTS=1 runtime";
   end if;
   Run_Lightweight;
   Run_Native;
end Accept_Transient_Smoke;
