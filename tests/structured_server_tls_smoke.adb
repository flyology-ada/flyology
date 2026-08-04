with Ada.Streams;
with Flyology;
with Flyology.IO.Connections;
with Flyology.IO.Connections.TLS;
with Flyology.IO.Sockets;
with Flyology.IO.Structured_Servers;
with Flyology.IO.TLS;
with System.Multiprocessors;
with TLS_Test_Provider;

procedure Structured_Server_TLS_Smoke is
   package Connections renames Flyology.IO.Connections;
   package Connection_TLS renames Flyology.IO.Connections.TLS;
   package Sockets renames Flyology.IO.Sockets;
   package TLS renames Flyology.IO.TLS;
   package Provider renames TLS_Test_Provider;

   use Ada.Streams;

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
      Sockets.Listen_Socket (Listener, Length => 8);
      Address := Sockets.Get_Socket_Name (Listener);
   end Open_Listener;

   generic
      Model : Flyology.Execution_Model;
      CPU   : System.Multiprocessors.CPU_Range;
   procedure Run_Lane;

   procedure Run_Lane is
      type Handler_Mode is (Negotiated_TLS, Plain_Fallback, Blocked_Upgrade);

      protected type Tracker is
         procedure Finished;
         entry Wait_Finished;
      private
         Done : Boolean := False;
      end Tracker;

      protected body Tracker is
         procedure Finished is
         begin
            Done := True;
         end Finished;

         entry Wait_Finished when Done is
         begin
            null;
         end Wait_Finished;
      end Tracker;

      type Context is limited record
         Mode    : Handler_Mode;
         Backend : Provider.Provider;
         State   : Tracker;
      end record;

      procedure Handle
        (State        : in out Context;
         Connection   : in out Connections.Connection;
         Peer         : Sockets.Endpoint;
         Cancellation : not null access Connections.Cancellation_Token)
      is
         Request : Stream_Element_Array (1 .. 1);
         Data    : Stream_Element_Array (1 .. 1);
         pragma Unreferenced (Peer);
      begin
         Connection.Receive_Exactly
           (Request, Timeout => 1.0, Token => Cancellation);
         case State.Mode is
            when Negotiated_TLS =>
               pragma Assert (Request = [1]);
               Connection.Send_All
                 ([1 => Character'Pos ('S')],
                  Timeout => 1.0,
                  Token => Cancellation);
               Connection_TLS.Upgrade
                 (Connection,
                  State.Backend,
                  TLS.Server,
                  "",
                  Timeout => 1.0,
                  Token => Cancellation);
               Connection.Receive_Exactly
                 (Data, Timeout => 1.0, Token => Cancellation);
               pragma Assert (Data = [42]);
               Connection.Send_All
                 ([1 => 7], Timeout => 1.0, Token => Cancellation);
               State.State.Finished;
            when Plain_Fallback =>
               pragma Assert (Request = [0]);
               Connection.Send_All
                 ([1 => Character'Pos ('N')],
                  Timeout => 1.0,
                  Token => Cancellation);
               Connection.Receive_Exactly
                 (Data, Timeout => 1.0, Token => Cancellation);
               Connection.Send_All
                 (Data, Timeout => 1.0, Token => Cancellation);
               State.State.Finished;
            when Blocked_Upgrade =>
               pragma Assert (Request = [1]);
               Connection.Send_All
                 ([1 => Character'Pos ('S')],
                  Timeout => 1.0,
                  Token => Cancellation);
               Connection_TLS.Upgrade
                 (Connection,
                  State.Backend,
                  TLS.Server,
                  "",
                  Timeout => Flyology.IO.Infinite,
                  Token => Cancellation);
         end case;
      end Handle;

      package Structured is new Flyology.IO.Structured_Servers
        (Handler_Context => Context,
         Handle          => Handle,
         Handler_Model   => Model,
         Handler_CPU     => CPU);

      procedure Close_If_Open (Socket : in out Sockets.Socket_Type) is
      begin
         if Sockets.Is_Open (Socket) then
            Sockets.Close_Socket (Socket);
         end if;
      exception
         when others =>
            null;
      end Close_If_Open;

      procedure Run_Success (Mode : Handler_Mode) is
         Item       : aliased Structured.Server (Capacity => 1);
         State      : aliased Context := (Mode => Mode, others => <>);
         Listener   : Sockets.Socket_Type;
         Address    : Sockets.Endpoint;
         Client     : Sockets.Socket_Type;
         Server_OK  : Boolean := False with Atomic;
         Response   : Stream_Element_Array (1 .. 1);
         Snapshot   : Structured.Snapshot;
      begin
         Provider.Reset_State_Telemetry;
         if Mode = Negotiated_TLS then
            Provider.Set_Script
              (State.Backend,
               Provider.Handshake_Operation,
               [1 => (TLS.Complete, Provider.Preserve_Output, 0)]);
            Provider.Set_Script
              (State.Backend,
               Provider.Receive_Operation,
               [1 => (TLS.Complete, Provider.Advance_Output, 1)]);
            Provider.Set_Script
              (State.Backend,
               Provider.Send_Operation,
               [1 => (TLS.Complete, Provider.Advance_Output, 1)]);
         end if;
         Open_Listener (Listener, Address);

         declare
            task Server_Task is
               pragma Task_Info (Flyology.Native_Task);
            end Server_Task;

            task body Server_Task is
            begin
               Structured.Serve
                 (Item, Listener, State, Drain_Timeout => 0.5);
               Server_OK := True;
            exception
               when others =>
                  Server_OK := False;
            end Server_Task;
         begin
            Sockets.Create_Socket (Client);
            Sockets.Connect (Client, Address, Timeout => 1.0);
            if Mode = Negotiated_TLS then
               Sockets.Send_All (Client, [1 => 1], Timeout => 1.0);
               Sockets.Receive_Exactly
                 (Client, Response, Timeout => 1.0);
               pragma Assert (Response = [Character'Pos ('S')]);
               --  The scripted provider supplies post-upgrade application
               --  data after observing readiness from this byte.
               Sockets.Send_All (Client, [1 => 9], Timeout => 1.0);
            else
               Sockets.Send_All (Client, [0, 9], Timeout => 1.0);
               Sockets.Receive_Exactly
                 (Client, Response, Timeout => 1.0);
               pragma Assert (Response = [Character'Pos ('N')]);
               Sockets.Receive_Exactly
                 (Client, Response, Timeout => 1.0);
               pragma Assert (Response = [9]);
            end if;
            State.State.Wait_Finished;
            Structured.Request_Shutdown (Item);
         end;

         pragma Assert (Server_OK);
         Snapshot := Structured.Current (Item);
         pragma Assert (Snapshot.Accepted_Connections = 1);
         pragma Assert (Snapshot.Completed_Connections = 1);
         pragma Assert (Snapshot.Cancelled_Connections = 0);
         pragma Assert (Snapshot.Failures = 0);
         Close_If_Open (Client);
         if Mode = Negotiated_TLS then
            declare
               TLS_State : Provider.State_Telemetry;
            begin
               Provider.Get_State_Telemetry (TLS_State);
               pragma Assert (TLS_State.Sessions_Created = 1);
               pragma Assert (TLS_State.Sessions_Finalized = 1);
               pragma Assert (TLS_State.Sessions_Live = 0);
               pragma Assert (TLS_State.Finalized_While_FD_Open = 1);
            end;
         else
            declare
               TLS_State : Provider.State_Telemetry;
            begin
               Provider.Get_State_Telemetry (TLS_State);
               pragma Assert (TLS_State.Sessions_Created = 0);
            end;
         end if;
      end Run_Success;

      procedure Run_Forced_Cancellation is
         Item       : aliased Structured.Server (Capacity => 1);
         State      : aliased Context :=
           (Mode => Blocked_Upgrade, others => <>);
         Listener   : Sockets.Socket_Type;
         Address    : Sockets.Endpoint;
         Client     : Sockets.Socket_Type;
         Server_OK  : Boolean := False with Atomic;
         Response   : Stream_Element_Array (1 .. 1);
         Snapshot   : Structured.Snapshot;
      begin
         Provider.Reset_State_Telemetry;
         Provider.Set_Script
           (State.Backend,
            Provider.Handshake_Operation,
            [1 => (TLS.Want_Read, Provider.Preserve_Output, 0)]);
         Open_Listener (Listener, Address);

         declare
            task Server_Task is
               pragma Task_Info (Flyology.Native_Task);
            end Server_Task;

            task body Server_Task is
            begin
               Structured.Serve
                 (Item, Listener, State, Drain_Timeout => 0.020);
               Server_OK := True;
            exception
               when others =>
                  Server_OK := False;
            end Server_Task;
         begin
            Sockets.Create_Socket (Client);
            Sockets.Connect (Client, Address, Timeout => 1.0);
            Sockets.Send_All (Client, [1 => 1], Timeout => 1.0);
            Sockets.Receive_Exactly (Client, Response, Timeout => 1.0);
            pragma Assert (Response = [Character'Pos ('S')]);
            Provider.Wait_For_First_Call (Provider.Handshake_Operation);
            Structured.Request_Shutdown (Item);
         end;

         pragma Assert (Server_OK);
         Snapshot := Structured.Current (Item);
         pragma Assert (Snapshot.Forced_Cancellation);
         pragma Assert (Snapshot.Accepted_Connections = 1);
         pragma Assert (Snapshot.Cancelled_Connections = 1);
         pragma Assert (Snapshot.Failures = 0);
         Close_If_Open (Client);
         declare
            TLS_State : Provider.State_Telemetry;
         begin
            Provider.Get_State_Telemetry (TLS_State);
            pragma Assert (TLS_State.Sessions_Created = 1);
            pragma Assert (TLS_State.Sessions_Finalized = 1);
            pragma Assert (TLS_State.Sessions_Live = 0);
         end;
      end Run_Forced_Cancellation;

   begin
      Run_Success (Negotiated_TLS);
      Run_Success (Plain_Fallback);
      Run_Forced_Cancellation;
   end Run_Lane;

   procedure Run_Lightweight is new Run_Lane
     (Model => Flyology.Lightweight_Task,
      CPU   => 6);
   procedure Run_Native is new Run_Lane
     (Model => Flyology.Native_Task,
      CPU   => System.Multiprocessors.Not_A_Specific_CPU);

begin
   Run_Lightweight;
   Run_Native;
end Structured_Server_TLS_Smoke;
