with Ada.Command_Line;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Connections;
with Flyology.HTTP.Server.Routing;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with Flyology.IO.Structured_Servers;

--  Application-server fixture. Unlike the plain fixture, this request passes
--  through Flyology's router and exchange abstraction before producing the
--  response. It has no benchmark-only logging or middleware.
procedure HTTP_Application_Benchmark_Server is
   package HTTP renames Flyology.HTTP.Server;
   package App renames Flyology.HTTP.Server.Applications;
   package Owned renames Flyology.IO.Connections;
   package Sockets renames Flyology.IO.Sockets;

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
      type Application_Context is null record;
      package Routing is new HTTP.Routing (Application_Context);

      procedure Routed_Get
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         pragma Unreferenced (State);
      begin
         X.Text (200, "Hello, World!");
      end Routed_Get;

      type Context is limited record
         Application : Application_Context;
         Routes      : Routing.Router
           (Capacity => 1, Slashes => Routing.Strict_Slashes);
         Budget      : aliased HTTP.Ingress_Budget
           (Limit => 64 * 1_024 * 1_024);
      end record;

      procedure Handle
        (State        : in out Context;
         Connection   : in out Owned.Connection;
         Peer         : Sockets.Endpoint;
         Cancellation : not null access Owned.Cancellation_Token)
      is
         Channel : aliased HTTP.Connections.Connection_Transport
           (Connection'Unchecked_Access);
         Client : aliased HTTP.Connection (Channel'Access);
      begin
         HTTP.Configure_Ingress_Budget (Client, State.Budget'Access);
         State.Routes.Serve
           (State.Application, Client, Peer,
            Timeout => 5.0, Token => Cancellation);
      end Handle;

      package Server_Instance is new Flyology.IO.Structured_Servers
        (Handler_Context => Context,
         Handle          => Handle,
         Handler_Model   => Model);

      Server   : aliased Server_Instance.Server (Capacity => Capacity);
      State    : aliased Context;
      Listener : Sockets.Socket_Type;
   begin
      State.Routes.Get
        ("/benchmark/route.html", Routed_Get'Access, Name => "benchmark");

      Sockets.Create_Socket (Listener);
      Sockets.Set_Socket_Option
        (Listener, Sockets.Socket_Level, (Sockets.Reuse_Address, True));
      Sockets.Bind_Socket
        (Listener, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port));
      Sockets.Listen_Socket (Listener, Length => Capacity);

      Ada.Text_IO.Put_Line
        ("READY flyology-application-" & Lane & " http://127.0.0.1:"
         & Ada.Strings.Fixed.Trim
             (Sockets.Port'Image (Port), Ada.Strings.Both)
         & "/benchmark/route.html");
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
end HTTP_Application_Benchmark_Server;
