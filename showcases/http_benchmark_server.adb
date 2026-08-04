with Ada.Command_Line;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Connections;
with Flyology.HTTP.Server.Metrics;
with Flyology.HTTP.Server.Middleware_Bulkheads;
with Flyology.HTTP.Server.Middleware_Deadlines;
with Flyology.HTTP.Server.Middleware_Errors;
with Flyology.HTTP.Server.Middleware_Metrics;
with Flyology.HTTP.Server.Middleware_Rate_Limits;
with Flyology.HTTP.Server.Middleware_Request_IDs;
with Flyology.HTTP.Server.Middleware_Security_Headers;
with Flyology.HTTP.Server.Routing;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with Flyology.IO.Structured_Servers;

--  Dedicated release-benchmark fixture. It keeps endpoint behavior fixed and
--  excludes console logging from measured request paths.
procedure HTTP_Benchmark_Server is
   use type Ada.Streams.Stream_Element_Offset;

   package HTTP renames Flyology.HTTP.Server;
   package App renames Flyology.HTTP.Server.Applications;
   package Sockets renames Flyology.IO.Sockets;
   package Owned renames Flyology.IO.Connections;

   Lane : constant String :=
     (if Ada.Command_Line.Argument_Count >= 1
      then Ada.Command_Line.Argument (1) else "lightweight");
   Request_Goal : constant Natural :=
     (if Ada.Command_Line.Argument_Count >= 2
      then Natural'Value (Ada.Command_Line.Argument (2)) else 0);
   Port : constant Sockets.Port :=
     (if Ada.Command_Line.Argument_Count >= 3
      then Sockets.Port'Value (Ada.Command_Line.Argument (3)) else 18_080);
   Capacity : constant Positive :=
     (if Ada.Command_Line.Argument_Count >= 4
      then Positive'Value (Ada.Command_Line.Argument (4)) else 256);

   generic
      Model : Flyology.Execution_Model;
   procedure Run;

   procedure Run is
      protected type Request_Counter (Goal : Natural) is
         procedure Completed;
         entry Await_Goal;
      private
         Count : Natural := 0;
      end Request_Counter;

      protected body Request_Counter is
         procedure Completed is
         begin
            if Goal > 0 and then Count < Goal then
               Count := Count + 1;
            end if;
         end Completed;

         entry Await_Goal when Goal > 0 and then Count = Goal is
         begin
            null;
         end Await_Goal;
      end Request_Counter;

      type Application_Context is null record;
      package Routing is new HTTP.Routing (Application_Context);

      Requests : Request_Counter (Request_Goal);
      Metrics  : aliased HTTP.Metrics.In_Memory (32);

      function Client_Key (X : App.Exchange) return String is
        (Sockets.Image (X.Peer.Address));

      package Errors is new HTTP.Middleware_Errors
        (Application_Context, Routing.Components);
      package Request_IDs is new HTTP.Middleware_Request_IDs
        (Application_Context, Routing.Components, Trust_Inbound => False);
      package Metric_Middleware is new HTTP.Middleware_Metrics
        (Application_Context, Routing.Components, Metrics'Access);
      package Security is new HTTP.Middleware_Security_Headers
        (Application_Context, Routing.Components,
         Content_Security_Policy => "default-src 'none'",
         Permissions_Policy      => "camera=(), microphone=()",
         Enable_HSTS             => False);
      package Deadlines is new HTTP.Middleware_Deadlines
        (Application_Context, Routing.Components, Maximum => 4.0);
      package Rates is new HTTP.Middleware_Rate_Limits
        (Application_Context, Routing.Components, Client_Key,
         Capacity => 2_048, Metric_Output => Metrics'Access);
      package Bulkheads is new HTTP.Middleware_Bulkheads
        (Application_Context, Routing.Components,
         Global_Limit => Capacity, Route_Capacity => 16,
         Metric_Output => Metrics'Access);

      procedure Finish is
      begin
         if Request_Goal > 0 then
            Requests.Completed;
         end if;
      end Finish;

      procedure Routed_Get
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         pragma Unreferenced (State);
      begin
         Finish;
         X.Text (200, "flyology" & ASCII.LF);
      end Routed_Get;

      procedure Buffered
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         pragma Unreferenced (State);
      begin
         Finish;
         X.Text (200, X.Content);
      end Buffered;

      procedure Streamed
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         pragma Unreferenced (State);
         Buffer   : Ada.Streams.Stream_Element_Array (1 .. 4 * 1_024);
         Last     : Ada.Streams.Stream_Element_Offset;
         Finished : Boolean;
         Total    : Natural := 0;
      begin
         loop
            X.Read_Body (Buffer, Last, Finished);
            if Last >= Buffer'First then
               Total := Total + Natural (Last - Buffer'First + 1);
            end if;
            exit when Finished;
         end loop;
         Finish;
         X.Text (200, Natural'Image (Total));
      end Streamed;

      type Context is limited record
         Application : Application_Context;
         Routes : Routing.Router
           (Capacity => 5, Slashes => Routing.Strict_Slashes);
         Budget : aliased HTTP.Ingress_Budget (Limit => 64 * 1_024 * 1_024);
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
      State.Routes.Get ("/route", Routed_Get'Access, Name => "route");
      State.Routes.Get
        ("/middleware", Routed_Get'Access, Name => "middleware");
      State.Routes.Post
        ("/buffered", Buffered'Access, Name => "buffered",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Body_Handling => App.Buffer_Body, Max_Body => 4 * 1_024));
      State.Routes.Post
        ("/upload", Streamed'Access, Name => "upload",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Body_Handling => App.Stream_Body, Max_Body => 64 * 1_024));
      State.Routes.Get
        ("/admission", Routed_Get'Access, Name => "admission",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Concurrency => Capacity, Rate_Per_Second => 1_000_000));

      State.Routes.Add_Route_Middleware
        ("middleware", Errors.Call'Access);
      State.Routes.Add_Route_Middleware
        ("middleware", Request_IDs.Call'Access);
      State.Routes.Add_Route_Middleware
        ("middleware", Metric_Middleware.Call'Access);
      State.Routes.Add_Route_Middleware
        ("middleware", Security.Call'Access,
         Stage => Routing.Application);
      State.Routes.Add_Route_Middleware
        ("middleware", Deadlines.Call'Access);
      State.Routes.Add_Route_Middleware
        ("admission", Rates.Call'Access);
      State.Routes.Add_Route_Middleware
        ("admission", Bulkheads.Call'Access);

      Sockets.Create_Socket (Listener);
      Sockets.Set_Socket_Option
        (Listener, Sockets.Socket_Level, (Sockets.Reuse_Address, True));
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port));
      Sockets.Listen_Socket (Listener, Length => Capacity);

      Ada.Text_IO.Put_Line
        ("READY " & Lane & " http://127.0.0.1:"
         & Ada.Strings.Fixed.Trim
             (Sockets.Port'Image (Port), Ada.Strings.Both) & "/route");
      Ada.Text_IO.Flush;

      declare
         task Stopper is
            pragma Task_Info (Flyology.Native_Task);
         end Stopper;
         task body Stopper is
         begin
            Requests.Await_Goal;
            Server_Instance.Request_Shutdown (Server);
         end Stopper;
      begin
         Server_Instance.Serve
           (Server, Listener, State, Drain_Timeout => 0.050);
      end;
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
end HTTP_Benchmark_Server;
