with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.Sockets;
with Flyology;
with Flyology.Cancellation;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Connections;
with Flyology.HTTP.Server.CORS;
with Flyology.HTTP.Server.Logging;
with Flyology.HTTP.Server.Metrics;
with Flyology.HTTP.Server.Middleware_Authentication;
with Flyology.HTTP.Server.Middleware_Bulkheads;
with Flyology.HTTP.Server.Middleware_CORS;
with Flyology.HTTP.Server.Middleware_Deadlines;
with Flyology.HTTP.Server.Middleware_Errors;
with Flyology.HTTP.Server.Middleware_Logging;
with Flyology.HTTP.Server.Middleware_Metrics;
with Flyology.HTTP.Server.Middleware_Rate_Limits;
with Flyology.HTTP.Server.Middleware_Request_IDs;
with Flyology.HTTP.Server.Middleware_Security_Headers;
with Flyology.HTTP.Server.Request_Tasks;
with Flyology.HTTP.Server.Requests;
with Flyology.HTTP.Server.Routing;
with Flyology.HTTP.Server.SSE_Handlers;
with Flyology.HTTP.Server.WebSocket_Handlers;
with Flyology.IO.Connections;
with Flyology.IO.Structured_Servers;
with Flyology.IO.Timers;
with Flyology.Native_Executors;

procedure HTTP_Application_Server is
   use type Ada.Streams.Stream_Element_Offset;

   package HTTP renames Flyology.HTTP.Server;
   package App renames Flyology.HTTP.Server.Applications;
   package Sockets renames GNAT.Sockets;
   package Owned renames Flyology.IO.Connections;

   Lane : constant String :=
     (if Ada.Command_Line.Argument_Count >= 1
      then Ada.Command_Line.Argument (1) else "lightweight");
   Request_Goal : constant Natural :=
     (if Ada.Command_Line.Argument_Count >= 2
      then Natural'Value (Ada.Command_Line.Argument (2)) else 100_000);
   Port : constant Sockets.Port_Type :=
     (if Ada.Command_Line.Argument_Count >= 3
      then Sockets.Port_Type'Value (Ada.Command_Line.Argument (3)) else 18_082);
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

      type Application_Context is record
         Calls : Natural := 0;
      end record;

      package Routing is new
        Flyology.HTTP.Server.Routing (Application_Context);

      protected type Log_Lock is
         procedure Put (Value : String);
      end Log_Lock;

      protected body Log_Lock is
         procedure Put (Value : String) is
         begin
            Ada.Text_IO.Put_Line (Value);
         end Put;
      end Log_Lock;

      type Console_Logger is limited new
        Flyology.HTTP.Server.Logging.Sink with record
         Lock : Log_Lock;
      end record;

      overriding procedure Write
        (Item           : in out Console_Logger;
         Method         : String;
         Route          : String;
         Target         : String;
         Status         : Natural;
         Request_ID     : String;
         Peer           : Sockets.Sock_Addr_Type;
         Request_Bytes  : Natural;
         Response_Bytes : Natural;
         Elapsed        : Duration)
      is
         pragma Unreferenced
           (Target, Peer, Request_Bytes, Response_Bytes, Elapsed);
      begin
         Item.Lock.Put
           (Method & " " & Route & " status="
            & Ada.Strings.Fixed.Trim
                (Natural'Image (Status), Ada.Strings.Both)
            & " request_id=" & Request_ID);
      end Write;

      Logger  : aliased Console_Logger;
      Metrics : aliased Flyology.HTTP.Server.Metrics.In_Memory (64);

      CORS_Policy : aliased constant Flyology.HTTP.Server.CORS.Policy :=
        Flyology.HTTP.Server.CORS.Create
          (Allowed_Origins   => "http://127.0.0.1:3000",
           Allowed_Methods   => "GET, POST, OPTIONS",
           Allowed_Headers   => "Authorization, Content-Type",
           Exposed_Headers   => "X-Request-ID",
           Allow_Credentials => False,
           Max_Age           => 600.0);

      function Resolve_CORS
        (Slot : Positive)
         return access constant Flyology.HTTP.Server.CORS.Policy is
      begin
         if Slot /= 1 then
            raise Constraint_Error with "unknown example CORS policy";
         end if;
         return CORS_Policy'Unchecked_Access;
      end Resolve_CORS;

      procedure Authenticate
        (Scheme        : String;
         Credential    : String;
         Authenticated : out Boolean;
         Principal     : out Ada.Strings.Unbounded.Unbounded_String) is
      begin
         Authenticated :=
           Scheme = "Bearer" and then Credential = "example-token";
         Principal :=
           (if Authenticated
            then Ada.Strings.Unbounded.To_Unbounded_String ("example-user")
            else Ada.Strings.Unbounded.Null_Unbounded_String);
      end Authenticate;

      function Client_Key (X : App.Exchange) return String is
        (Sockets.Image (X.Peer));

      procedure Error_Log
        (Kind  : Routing.Components.Failure_Kind;
         Error : Ada.Exceptions.Exception_Occurrence;
         X     : in out App.Exchange)
      is
         pragma Unreferenced (X);
      begin
         Logger.Lock.Put
           (Routing.Components.Failure_Kind'Image (Kind) & ": "
            & Ada.Exceptions.Exception_Information (Error));
      end Error_Log;

      package Error_Middleware is new
        Flyology.HTTP.Server.Middleware_Errors
          (Application_Context, Routing.Components, Log => Error_Log);
      package Request_ID_Middleware is new
        Flyology.HTTP.Server.Middleware_Request_IDs
          (Application_Context, Routing.Components,
           Trust_Inbound => False);
      package Logging_Middleware is new
        Flyology.HTTP.Server.Middleware_Logging
          (Application_Context, Routing.Components, Logger'Access);
      package Metrics_Middleware is new
        Flyology.HTTP.Server.Middleware_Metrics
          (Application_Context, Routing.Components, Metrics'Access);
      package Authentication_Middleware is new
        Flyology.HTTP.Server.Middleware_Authentication
          (Application_Context, Routing.Components, Authenticate);
      package CORS_Middleware is new
        Flyology.HTTP.Server.Middleware_CORS
          (Application_Context, Routing.Components, Resolve_CORS);
      package Security_Middleware is new
        Flyology.HTTP.Server.Middleware_Security_Headers
          (Application_Context, Routing.Components,
           Content_Security_Policy => "default-src 'self'",
           Permissions_Policy      => "camera=(), microphone=()",
           Enable_HSTS             => False);
      package Rate_Middleware is new
        Flyology.HTTP.Server.Middleware_Rate_Limits
          (Application_Context, Routing.Components, Client_Key,
           Capacity => 1_024, Metric_Output => Metrics'Access);
      package Bulkhead_Middleware is new
        Flyology.HTTP.Server.Middleware_Bulkheads
          (Application_Context, Routing.Components,
           Global_Limit => Capacity, Route_Capacity => 64,
           Metric_Output => Metrics'Access);
      package Deadline_Middleware is new
        Flyology.HTTP.Server.Middleware_Deadlines
          (Application_Context, Routing.Components, Maximum => 4.0);

      Requests : Request_Counter (Request_Goal);

      procedure Complete (State : in out Application_Context) is
      begin
         State.Calls := State.Calls + 1;
         Requests.Completed;
      end Complete;

      procedure Home
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         Name : constant String :=
           Flyology.HTTP.Server.Requests.Query (X, "name");
      begin
         Complete (State);
         X.Text
           (200, "flyology"
            & (if Name'Length = 0 then "" else " for " & Name)
            & ASCII.LF);
      end Home;

      procedure Show_User
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
      begin
         Complete (State);
         X.Text (200, "user " & X.Parameter ("id") & ASCII.LF);
      end Show_User;

      procedure Buffered_Echo
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
      begin
         Complete (State);
         X.Text (200, X.Content);
      end Buffered_Echo;

      procedure Upload
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         Buffer   : Ada.Streams.Stream_Element_Array (1 .. 16 * 1_024);
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
         Complete (State);
         X.Text (200, "received" & Natural'Image (Total) & " bytes" & ASCII.LF);
      end Upload;

      procedure Stream_Response
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
      begin
         Complete (State);
         X.Begin_Stream (200, "text/plain; charset=utf-8");
         X.Write_Chunk ("first" & ASCII.LF);
         X.Write_Chunk ("second" & ASCII.LF);
         X.End_Stream;
      end Stream_Response;

      procedure Metrics_Endpoint
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         Snapshot : constant Flyology.HTTP.Server.Metrics.Snapshot :=
           Metrics.Read;
      begin
         Complete (State);
         X.JSON
           (200, "{""requests"":"
            & Ada.Strings.Fixed.Trim
                (Natural'Image (Snapshot.Requests), Ada.Strings.Both)
            & ",""active"":"
            & Ada.Strings.Fixed.Trim
                (Natural'Image (Snapshot.Active), Ada.Strings.Both) & "}");
      end Metrics_Endpoint;

      procedure Private_Profile
        (State : in out Application_Context;
         X     : in out App.Exchange) is
      begin
         Complete (State);
         X.Text (200, "hello " & X.Principal & ASCII.LF);
      end Private_Profile;

      procedure Demonstrate_Error
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         pragma Unreferenced (State, X);
      begin
         raise Constraint_Error with "example application failure";
      end Demonstrate_Error;

      procedure SSE_Events
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         Session  : Flyology.HTTP.Server.SSE_Handlers.Session (4);
         Accepted : Boolean;
      begin
         Complete (State);
         Flyology.HTTP.Server.SSE_Handlers.Try_Publish
           (Session,
            (Data  => Ada.Strings.Unbounded.To_Unbounded_String ("ready"),
             Event => Ada.Strings.Unbounded.To_Unbounded_String ("status"),
             Id    => Ada.Strings.Unbounded.To_Unbounded_String ("1"),
             Retry => 1_000), Accepted);
         pragma Assert (Accepted);
         Flyology.HTTP.Server.SSE_Handlers.Close (Session);
         Flyology.HTTP.Server.SSE_Handlers.Run
           (X, Session, Metrics'Access);
      end SSE_Events;

      procedure WS_Open
        (X       : in out App.Exchange;
         Session : in out Flyology.HTTP.Server.WebSocket_Handlers.Session)
      is
         pragma Unreferenced (X);
         Accepted : Boolean;
      begin
         Flyology.HTTP.Server.WebSocket_Handlers.Try_Publish
           (Session,
            (Kind => HTTP.Text_Frame,
             Data => Ada.Strings.Unbounded.To_Unbounded_String ("ready")),
            Accepted);
      end WS_Open;

      procedure WS_Message
        (X       : in out App.Exchange;
         Session : in out Flyology.HTTP.Server.WebSocket_Handlers.Session;
         Kind    : HTTP.WebSocket_Data_Kind;
         Data    : String)
      is
         pragma Unreferenced (X);
         Accepted : Boolean;
      begin
         Flyology.HTTP.Server.WebSocket_Handlers.Try_Publish
           (Session,
            (Kind => Kind,
             Data => Ada.Strings.Unbounded.To_Unbounded_String (Data)),
            Accepted);
         if not Accepted then
            Flyology.HTTP.Server.WebSocket_Handlers.Close (Session);
         end if;
      end WS_Message;

      procedure WebSocket_Echo
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         package WS renames Flyology.HTTP.Server.WebSocket_Handlers;
         Session : aliased WS.Session (16);
         type Session_Access is access all WS.Session;
         task type Producer
           (Item : not null Session_Access;
            Text : Character) is
            pragma Task_Info (Model);
         end Producer;

         task body Producer is
            Accepted : Boolean;
         begin
            WS.Publish
              (Item.all,
               (Kind => HTTP.Text_Frame,
               Data => Ada.Strings.Unbounded.To_Unbounded_String
                  ("producer-" & Text)),
               Accepted);
            pragma Assert (Accepted);
         end Producer;
      begin
         Complete (State);
         declare
            First  : Producer (Session'Unchecked_Access, 'a');
            Second : Producer (Session'Unchecked_Access, 'b');
         begin
            null;
         end;
         WS.Run
           (X, Session, Open => WS_Open'Unrestricted_Access,
            Message => WS_Message'Unrestricted_Access,
            Origin_Policy => HTTP.Require_Exact_Origin,
            Allowed_Origin => "http://127.0.0.1:3000",
            Metric_Output => Metrics'Access);
      end WebSocket_Echo;

      procedure Simulated_Upstream
        (Input    : Integer;
         Token    : access Flyology.Cancellation.Token;
         Deadline : Ada.Real_Time.Time;
         Result   : out Integer)
      is
         pragma Unreferenced (Deadline);
      begin
         if Token.Requested then
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
         Flyology.IO.Timers.Sleep_For (0.010);
         if Token.Requested then
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
         Result := Input * 2;
      end Simulated_Upstream;

      package Request_Work is new
        Flyology.HTTP.Server.Request_Tasks
          (Integer, Integer, Simulated_Upstream);
      package Request_Operations renames Request_Work.Operations;

      procedure Parallel_Work
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         Scope : Request_Operations.Scope (2);
         User, Orders : Request_Operations.Operation_Handle;
      begin
         Request_Work.Configure (Scope, X);
         Request_Operations.Spawn (Scope, 20, User);
         Request_Operations.Spawn (Scope, 1, Orders);
         Request_Operations.Join (Scope);
         Complete (State);
         X.Text
           (200, "combined"
            & Integer'Image
                (Request_Operations.Result (Scope, User)
                 + Request_Operations.Result (Scope, Orders))
            & ASCII.LF);
      end Parallel_Work;

      procedure CPU_Work
        (Input    : Integer;
         Token    : access Flyology.Cancellation.Token;
         Deadline : Ada.Real_Time.Time;
         Result   : out Integer)
      is
         pragma Unreferenced (Deadline);
      begin
         if Token.Requested then
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
         Result := Input * Input;
      end CPU_Work;

      package Native_Work is new
        Flyology.Native_Executors (Integer, Integer, CPU_Work);
      package Native_Operations renames Native_Work.Operations;

      procedure Native_Boundary
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         Scope : Native_Operations.Scope (1);
         Work  : Native_Operations.Operation_Handle;
      begin
         Native_Operations.Configure
           (Scope, X.Cancellation, X.Deadline,
            Cancel_Siblings_On_Failure => False);
         Native_Operations.Spawn (Scope, 12, Work);
         Native_Operations.Join (Scope);
         Complete (State);
         X.Text
           (200, "native" & Integer'Image
              (Native_Operations.Result (Scope, Work)) & ASCII.LF);
      end Native_Boundary;

      procedure Admin_Status
        (State : in out Application_Context;
         X     : in out App.Exchange) is
      begin
         Complete (State);
         X.Text (200, "admin ok" & ASCII.LF);
      end Admin_Status;

      type Context is limited record
         Application : Application_Context;
         Routes      : Routing.Router
           (Capacity => 20, Slashes => Routing.Strict_Slashes);
         Budget      : aliased HTTP.Ingress_Budget
           (Limit => 64 * 1_024 * 1_024);
      end record;

      procedure Handle
        (State        : in out Context;
         Connection   : in out Owned.Connection;
         Peer         : Sockets.Sock_Addr_Type;
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
      Admin_Routes : Routing.Router
        (Capacity => 2, Slashes => Routing.Strict_Slashes);
      Listener : Sockets.Socket_Type;
   begin
      State.Routes.Add_Middleware (Error_Middleware.Call'Access);
      State.Routes.Add_Middleware (Request_ID_Middleware.Call'Access);
      State.Routes.Add_Middleware (Logging_Middleware.Call'Access);
      State.Routes.Add_Middleware (Metrics_Middleware.Call'Access);
      State.Routes.Add_Middleware (CORS_Middleware.Call'Access);
      State.Routes.Add_Middleware (Rate_Middleware.Call'Access);
      State.Routes.Add_Middleware (Bulkhead_Middleware.Call'Access);
      State.Routes.Add_Middleware (Deadline_Middleware.Call'Access);
      State.Routes.Add_Middleware
        (Security_Middleware.Call'Access, Stage => Routing.Application);

      State.Routes.Get ("/", Home'Access, Name => "home");
      State.Routes.Get
        ("/users/{id}", Show_User'Access, Name => "users.show");
      State.Routes.Post
        ("/echo", Buffered_Echo'Access, Name => "echo",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Body_Handling => App.Buffer_Body,
              Max_Body      => 64 * 1_024));
      State.Routes.Post
        ("/upload", Upload'Access, Name => "upload",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Body_Handling => App.Stream_Body));
      State.Routes.Get
        ("/stream", Stream_Response'Access, Name => "stream");
      State.Routes.Get
        ("/metrics", Metrics_Endpoint'Access, Name => "metrics");
      State.Routes.Get
        ("/private", Private_Profile'Access, Name => "private",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Authentication => Routing.Required_Authentication,
              CORS_Policy     => 1,
              Rate_Per_Second => 10,
              Concurrency     => 8));
      State.Routes.Add_Route_Middleware
        ("private", Authentication_Middleware.Call'Access);
      State.Routes.Get
        ("/error", Demonstrate_Error'Access, Name => "error");
      State.Routes.Get
        ("/events", SSE_Events'Access, Name => "events",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Upgrade => Routing.Allow_SSE));
      State.Routes.Get
        ("/chat", WebSocket_Echo'Access, Name => "chat",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Upgrade     => Routing.Allow_WebSocket,
              CORS_Policy => 1));
      State.Routes.Get
        ("/parallel", Parallel_Work'Access, Name => "parallel",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Timeout => 1.0, Concurrency => 8));
      State.Routes.Get
        ("/native", Native_Boundary'Access, Name => "native-boundary",
         Policy =>
           (Routing.Default_Route_Policy with delta Concurrency => 2));

      Admin_Routes.Get
        ("/status", Admin_Status'Access, Name => "status");
      Admin_Routes.Add_Middleware (Security_Middleware.Call'Access);
      State.Routes.Mount
        ("/admin", Admin_Routes, Name_Prefix => "admin.");

      Sockets.Create_Socket (Listener);
      Sockets.Set_Socket_Option
        (Listener, Sockets.Socket_Level, (Sockets.Reuse_Address, True));
      Sockets.Bind_Socket
        (Listener,
         (Family => Sockets.Family_Inet,
          Addr   => Sockets.Loopback_Inet_Addr,
          Port   => Port));
      Sockets.Listen_Socket (Listener, Length => Capacity);

      Ada.Text_IO.Put_Line
        ("READY " & Lane & " http://127.0.0.1:"
         & Sockets.Port_Type'Image (Port) & "/");
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
end HTTP_Application_Server;
