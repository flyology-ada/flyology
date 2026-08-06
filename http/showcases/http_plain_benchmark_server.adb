with Ada.Command_Line;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Connection_Handlers;
with Flyology.HTTP.Server.Connections;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with Flyology.IO.Structured_Servers;

--  Minimal HTTP-engine benchmark fixture. It deliberately excludes routing,
--  middleware, metrics, and per-request logging so it can be compared with
--  other servers' direct callback interfaces.
procedure HTTP_Plain_Benchmark_Server is
   package HTTP renames Flyology.HTTP.Server;
   package Owned renames Flyology.IO.Connections;
   package Sockets renames Flyology.IO.Sockets;

   Plaintext : constant String := "Hello, World!";
   One_KiB   : constant String (1 .. 1_024) := (others => 'x');

   Lane : constant String :=
     (if Ada.Command_Line.Argument_Count >= 1
      then Ada.Command_Line.Argument (1) else "lightweight");
   Port : constant Sockets.Port :=
     (if Ada.Command_Line.Argument_Count >= 2
      then Sockets.Port'Value (Ada.Command_Line.Argument (2)) else 18_090);
   Capacity : constant Positive :=
     (if Ada.Command_Line.Argument_Count >= 3
      then Positive'Value (Ada.Command_Line.Argument (3)) else 256);

   generic
      Model : Flyology.Execution_Model;
   procedure Run;

   procedure Run is
      type Context is limited record
         Budget : aliased HTTP.Ingress_Budget (Limit => 64 * 1_024 * 1_024);
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

         procedure Respond
           (Item    : in out HTTP.Connection;
            Request : HTTP.Request) is
         begin
            if HTTP.Method (Request) /= "GET" then
               HTTP.Respond
                 (Item, 405, "text/plain", "method not allowed",
                  Timeout => 5.0, Token => Cancellation);
            elsif HTTP.Target (Request) = "/plaintext" then
               HTTP.Respond
                 (Item, 200, "text/plain", Plaintext,
                  Timeout => 5.0, Token => Cancellation);
            elsif HTTP.Target (Request) = "/response-1k" then
               HTTP.Respond
                 (Item, 200, "application/octet-stream", One_KiB,
                  Timeout => 5.0, Token => Cancellation);
            else
               HTTP.Respond
                 (Item, 404, "text/plain", "not found",
                  Timeout => 5.0, Token => Cancellation);
            end if;
         end Respond;

         package Handler is new HTTP.Connection_Handlers (Respond);
      begin
         HTTP.Configure_Ingress_Budget (Client, State.Budget'Access);
         Handler.Serve
           (Client, Timeout => 5.0, Buffer_Body => False,
            Token => Cancellation);
      end Handle;

      package Server_Instance is new Flyology.IO.Structured_Servers
        (Handler_Context => Context,
         Handle          => Handle,
         Handler_Model   => Model);

      Server   : aliased Server_Instance.Server (Capacity => Capacity);
      State    : aliased Context;
      Listener : Sockets.Socket_Type;
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Set_Socket_Option
        (Listener, Sockets.Socket_Level, (Sockets.Reuse_Address, True));
      Sockets.Bind_Socket
        (Listener, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port));
      Sockets.Listen_Socket (Listener, Length => Capacity);

      Ada.Text_IO.Put_Line
        ("READY flyology-" & Lane & " http://127.0.0.1:"
         & Ada.Strings.Fixed.Trim
             (Sockets.Port'Image (Port), Ada.Strings.Both)
         & "/plaintext");
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
end HTTP_Plain_Benchmark_Server;
