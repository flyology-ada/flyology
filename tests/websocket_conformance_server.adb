with Ada.Command_Line;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology;
with Flyology.Bytes;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Connection_Handlers;
with Flyology.HTTP.Server.Connections;
with Flyology.IO.Connections;
with Flyology.IO.Connections.TLS;
with Flyology.IO.Sockets;
with Flyology.IO.Structured_Servers;
with Flyology.IO.TLS;
with Flyology.IO.TLS.OpenSSL;

--  Echo server used only as the public-API test adapter for Autobahn.
procedure WebSocket_Conformance_Server is
   package HTTP renames Flyology.HTTP.Server;
   package Owned renames Flyology.IO.Connections;
   package Connection_TLS renames Flyology.IO.Connections.TLS;
   package Sockets renames Flyology.IO.Sockets;
   package TLS renames Flyology.IO.TLS;
   package OpenSSL renames Flyology.IO.TLS.OpenSSL;

   Lane : constant String :=
     (if Ada.Command_Line.Argument_Count >= 1
      then Ada.Command_Line.Argument (1) else "lightweight");
   Port : constant Sockets.Port :=
     (if Ada.Command_Line.Argument_Count >= 2
      then Sockets.Port'Value (Ada.Command_Line.Argument (2)) else 18_081);
   Capacity : constant Positive :=
     (if Ada.Command_Line.Argument_Count >= 3
      then Positive'Value (Ada.Command_Line.Argument (3)) else 32);
   Transport : constant String :=
     (if Ada.Command_Line.Argument_Count >= 4
      then Ada.Command_Line.Argument (4) else "plain");
   Use_TLS : constant Boolean := Transport = "tls";
   Certificate : constant String :=
     (if Ada.Command_Line.Argument_Count >= 5
      then Ada.Command_Line.Argument (5)
      else "tests/fixtures/tls/server-cert.pem");
   Private_Key : constant String :=
     (if Ada.Command_Line.Argument_Count >= 6
      then Ada.Command_Line.Argument (6)
      else "tests/fixtures/tls/server-key.pem");
   Library_Directory : constant String :=
     (if Ada.Command_Line.Argument_Count >= 7
      then Ada.Command_Line.Argument (7) else "");

   generic
      Model : Flyology.Execution_Model;
   procedure Run;

   procedure Run is
      type Context is limited record
         Backend : OpenSSL.OpenSSL_Provider;
      end record;

      procedure Handle
        (State        : in out Context;
         Connection   : in out Owned.Connection;
         Peer         : Sockets.Endpoint;
         Cancellation : not null access Owned.Cancellation_Token)
      is
         pragma Unreferenced (Peer);
         Channel : aliased HTTP.Connections.Connection_Transport
           (Connection'Unchecked_Access);
         Client : HTTP.Connection (Channel'Access);

         procedure Route
           (Item  : in out HTTP.Connection;
            Value : HTTP.Request)
         is
            Message : Flyology.Bytes.Unbounded_Bytes;
            Kind    : HTTP.WebSocket_Data_Kind;
            Closed  : Boolean;
         begin
            if HTTP.Target (Value) /= "/websocket" then
               HTTP.Respond
                 (Item, 404, "text/plain; charset=utf-8", "not found" & ASCII.LF,
                  Close => True, Timeout => 5.0, Token => Cancellation);
               return;
            end if;

            HTTP.Accept_WebSocket
              (Item, Value,
               Origin_Policy => HTTP.Allow_Any_Origin,
               Compression   => HTTP.Permessage_Deflate,
               Timeout       => 5.0,
               Token         => Cancellation);
            loop
               HTTP.Receive_WebSocket
                 (Item, Kind, Message, Closed,
                  Max_Message     => HTTP.Max_WebSocket_Frame,
                  Timeout         => 30.0,
                  Message_Timeout => 300.0,
                  Token           => Cancellation);
               exit when Closed;
               HTTP.Send_WebSocket
                 (Item, Kind, Message,
                  Timeout => 30.0, Token => Cancellation);
            end loop;
         end Route;

         package Handler is new
           Flyology.HTTP.Server.Connection_Handlers (Route);
      begin
         if Use_TLS then
            Connection_TLS.Upgrade
              (Connection, State.Backend, TLS.Server, "",
               Timeout => 5.0, Token => Cancellation);
         end if;
         Handler.Serve
           (Client,
            Timeout            => 30.0,
            Buffer_Body        => False,
            Max_Requests       => 1,
            Max_Connection_Age => -1.0,
            Token              => Cancellation);
      end Handle;

      package Server_Instance is new Flyology.IO.Structured_Servers
        (Handler_Context => Context,
         Handle          => Handle,
         Handler_Model   => Model);

      Server   : aliased Server_Instance.Server (Capacity => Capacity);
      State    : aliased Context;
      Listener : Sockets.Socket_Type;
   begin
      if Use_TLS then
         OpenSSL.Initialize_Server
           (State.Backend, Certificate, Private_Key,
            Library_Directory => Library_Directory);
      elsif Transport /= "plain" then
         raise Constraint_Error with "transport must be plain or tls";
      end if;
      Sockets.Create_Socket (Listener);
      Sockets.Set_Socket_Option
        (Listener, Sockets.Socket_Level, (Sockets.Reuse_Address, True));
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port));
      Sockets.Listen_Socket (Listener, Length => Capacity);

      Ada.Text_IO.Put_Line
         ("READY " & Lane & " "
          & (if Use_TLS then "wss://" else "ws://") & "127.0.0.1:"
         & Ada.Strings.Fixed.Trim
             (Sockets.Port'Image (Port), Ada.Strings.Both)
         & "/websocket");
      if Use_TLS then
         Ada.Text_IO.Put_Line
           ("TLS_PROVIDER " & OpenSSL.Name (State.Backend));
         Ada.Text_IO.Put_Line
           ("TLS_VERSION " & OpenSSL.Version (State.Backend));
      end if;
      Ada.Text_IO.Flush;
      Server_Instance.Serve (Server, Listener, State);
   end Run;

   procedure Run_Lightweight is new Run (Flyology.Lightweight_Task);
   procedure Run_Native is new Run (Flyology.Native_Task);
begin
   if Lane = "lightweight" then
      Run_Lightweight;
   elsif Lane = "native" then
      Run_Native;
   else
      raise Constraint_Error with "lane must be lightweight or native";
   end if;
end WebSocket_Conformance_Server;
