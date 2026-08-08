with Ada.Streams;
with Flyology;
with Flyology.IO;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with Flyology.IO.Structured_Servers;
with Interfaces.C;
with System.Multiprocessors;

procedure Structured_Server_Reset_Smoke is
   package Connections renames Flyology.IO.Connections;
   package Sockets renames Flyology.IO.Sockets;

   use type Ada.Streams.Stream_Element_Array;
   use type Interfaces.C.int;

   Reset_Count : constant := 32;

   function Open_FD_Count return Interfaces.C.int
     with Import,
          Convention => C,
          External_Name => "flyology_test_open_fd_count";

   function Queue_TCP_Resets
     (Port  : Interfaces.C.unsigned;
      Count : Interfaces.C.unsigned) return Interfaces.C.int
     with Import,
          Convention => C,
          External_Name => "flyology_test_queue_tcp_resets";

   protected type Tracker is
      procedure Healthy_Connection;
      function Healthy_Count return Natural;
   private
      Healthy : Natural := 0;
   end Tracker;

   protected body Tracker is
      procedure Healthy_Connection is
      begin
         Healthy := Healthy + 1;
      end Healthy_Connection;

      function Healthy_Count return Natural is (Healthy);
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
      Marker : Ada.Streams.Stream_Element_Array (1 .. 1);
      pragma Unreferenced (Peer);
   begin
      begin
         Connection.Receive_Exactly
           (Marker, Timeout => 1.0, Token => Cancellation);
         if Marker = [1 => 91] then
            Connection.Send_All
              (Marker, Timeout => 1.0, Token => Cancellation);
            State.State.Healthy_Connection;
         end if;
      exception
         --  Linux can configure and admit a socket whose reset is observed by
         --  the first receive.  That is a per-connection protocol outcome,
         --  so this test handler contains it rather than failing its server.
         when Sockets.Socket_Error | Flyology.IO.Device_Error =>
            null;
      end;
   end Handle;

   package Structured is new Flyology.IO.Structured_Servers
     (Handler_Context => Context,
      Handle          => Handle,
      Handler_Model   => Flyology.Native_Task,
      Handler_CPU     => System.Multiprocessors.Not_A_Specific_CPU);

   Before : constant Interfaces.C.int := Open_FD_Count;
begin
   declare
      Item      : aliased Structured.Server (Capacity => 1);
      State     : aliased Context;
      Listener  : Sockets.Socket_Type;
      Address   : Sockets.Endpoint;
      Failed    : Boolean := False with Atomic;
      Client_OK : Boolean := False with Atomic;
      Error     : Interfaces.C.int;
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
      Sockets.Listen_Socket (Listener, Length => Reset_Count + 4);
      Address := Sockets.Get_Socket_Name (Listener);

      Error := Queue_TCP_Resets
        (Interfaces.C.unsigned (Address.Port), Reset_Count);
      pragma Assert (Error = 0, "could not queue reset TCP clients");

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
                  Failed := True;
            end;
         end Runner;

         task body Client is
            Socket   : Sockets.Socket_Type;
            Marker   : constant Ada.Streams.Stream_Element_Array (1 .. 1) :=
              [1 => 91];
            Response : Ada.Streams.Stream_Element_Array (1 .. 1);
         begin
            begin
               Sockets.Create_Socket (Socket);
               Sockets.Connect (Socket, Address, Timeout => 2.0);
               Sockets.Send_All (Socket, Marker, Timeout => 2.0);
               Sockets.Receive_Exactly (Socket, Response, Timeout => 2.0);
               Client_OK := Response = Marker;
               Sockets.Close_Socket (Socket);
            exception
               when others =>
                  if Sockets.Is_Open (Socket) then
                     Sockets.Close_Socket (Socket);
                  end if;
            end;
            Structured.Request_Shutdown (Item);
         end Client;
      begin
         null;
      end;

      pragma Assert (not Failed, "a reset client stopped the server");
      pragma Assert (Client_OK, "server did not accept the healthy client");
      pragma Assert (State.State.Healthy_Count = 1);
      pragma Assert (Structured.Current (Item).Failures = 0);
   end;

   pragma Assert
     (Open_FD_Count = Before,
      "reset clients changed the process descriptor count");
end Structured_Server_Reset_Smoke;
