with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.Sockets;
with Flyology;
with Flyology.Bytes;
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
with Flyology.HTTP.Server.Routing;
with Flyology.HTTP.Server.SSE_Handlers;
with Flyology.HTTP.Server.WebSocket_Handlers;
with Flyology.HTTP.Server.WebSocket_Handlers.Lifecycle;
with Flyology.IO.Connections;
with Flyology.IO.Files;
with Flyology.IO.Structured_Servers;
with Flyology.IO.Timers;
with Flyology.Native_Executors;

procedure HTTP_Application_Server is
   use type Ada.Streams.Stream_Element_Offset;
   use type Flyology.HTTP.Server.WebSocket_Data_Kind;
   use type Flyology.IO.Files.File_Descriptor;
   use type Flyology.IO.Files.File_Offset;

   package HTTP renames Flyology.HTTP.Server;
   package App renames Flyology.HTTP.Server.Applications;
   package Bytes renames Flyology.Bytes;
   package Files renames Flyology.IO.Files;
   package Sockets renames GNAT.Sockets;
   package Owned renames Flyology.IO.Connections;

   --  Keep the command line compatible with the benchmark showcases. A zero
   --  request goal leaves the interactive server running until it is stopped.
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
   Project_Root : constant String :=
     (if Ada.Command_Line.Argument_Count >= 5
      then Ada.Command_Line.Argument (5) else ".");
   Showcase_Root : constant String :=
     Project_Root & "/showcases/http_application";

   function Compact (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   Origin : constant String :=
     "http://127.0.0.1:" & Compact (Natural (Port));

   --  Instantiate the same application once per execution model. Handler code
   --  below remains ordinary synchronous Ada in either instantiation.
   generic
      Model : Flyology.Execution_Model;
   procedure Run;

   procedure Run is
      --  The finite request goal lets scripts shut the showcase down cleanly.
      --  The protected counter is shared safely by concurrent handlers.
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

      --  Routing is generic over application state, so handlers receive the
      --  state directly without a global registry or untyped context lookup.
      package Routing is new
        Flyology.HTTP.Server.Routing (Application_Context);

      --  Access-log callbacks may arrive from multiple native handler tasks or
      --  event loops. Serialize only the example console sink, not requests.
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
      --  The implementation is intentionally bounded to 64 route label slots.
      Metrics : aliased Flyology.HTTP.Server.Metrics.In_Memory (64);

      --  This demo is same-origin. Credentials stay disabled so an origin can
      --  never be reflected together with credentialed CORS access.
      CORS_Policy : aliased constant Flyology.HTTP.Server.CORS.Policy :=
        Flyology.HTTP.Server.CORS.Create
          (Allowed_Origins   => Origin,
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

      --  This fixed token demonstrates the authentication hook only. Real
      --  applications should delegate identity verification to their policy.
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

      --  Peer socket identity is safe for this direct listener. A deployment
      --  behind proxies needs an explicit trusted-hop extraction policy.
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
           Content_Security_Policy =>
             "default-src 'self'; object-src 'none'; base-uri 'none'; "
             & "frame-ancestors 'none'; connect-src 'self' ws://127.0.0.1:"
             & Compact (Natural (Port)),
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
          (Application_Context, Routing.Components, Maximum => 20.0);

      Requests : Request_Counter (Request_Goal);

      --  Count only requests that reached an application handler. Rejections
      --  performed before dispatch remain visible through metrics instead.
      procedure Complete (State : in out Application_Context) is
      begin
         State.Calls := State.Calls + 1;
         Requests.Completed;
      end Complete;

      procedure Serve_File
        (State        : in out Application_Context;
         X            : in out App.Exchange;
         Path         : String;
         Content_Type : String;
         Cache        : Boolean := True)
      is
         File   : Files.File_Descriptor := Files.Invalid_File;
         Buffer : Ada.Streams.Stream_Element_Array (1 .. 32 * 1_024);
         Last   : Ada.Streams.Stream_Element_Offset;
         Offset : Files.File_Offset := 0;
      begin
         Complete (State);
         begin
            File := Files.Open (Path);
         exception
            when Flyology.IO.Device_Error =>
               X.Problem
                 (500, "showcase-asset-missing",
                  "A maintained showcase asset could not be opened");
               return;
         end;

         X.Add_Header
           ("Cache-Control", (if Cache then "public, max-age=3600" else "no-store"));
         --  Read_At returns bytes, and the binary Write_Chunk overload keeps
         --  them as bytes through HTTP chunk framing. Each write applies
         --  transport backpressure before this buffer is reused.
         X.Begin_Stream (200, Content_Type);
         loop
            Files.Read_At
              (File, Offset, Buffer, Last, Token => X.Cancellation);
            exit when Last < Buffer'First;
            X.Write_Chunk (Buffer (Buffer'First .. Last));
            Offset := Offset + Files.File_Offset (Last - Buffer'First + 1);
         end loop;
         Files.Close (File);
         X.End_Stream;
      exception
         when others =>
            --  File ownership stays local if cancellation, timeout, or a
            --  disconnected client interrupts the response stream.
            if File /= Files.Invalid_File then
               begin
                  Files.Close (File);
               exception
                  when others => null;
               end;
            end if;
            raise;
      end Serve_File;

      --  Only fixed route handlers select filesystem paths. No untrusted URL
      --  segment is joined to Project_Root in this showcase.
      procedure Home
        (State : in out Application_Context;
         X     : in out App.Exchange) is
      begin
         Serve_File
           (State, X, Showcase_Root & "/index.html",
            "text/html; charset=utf-8", Cache => False);
      end Home;

      procedure Application_CSS
        (State : in out Application_Context;
         X     : in out App.Exchange) is
      begin
         Serve_File
           (State, X, Showcase_Root & "/assets/app.css",
            "text/css; charset=utf-8", Cache => False);
      end Application_CSS;

      procedure Application_JS
        (State : in out Application_Context;
         X     : in out App.Exchange) is
      begin
         Serve_File
           (State, X, Showcase_Root & "/assets/app.js",
            "text/javascript; charset=utf-8", Cache => False);
      end Application_JS;

      procedure Brand_Mark
        (State : in out Application_Context;
         X     : in out App.Exchange) is
      begin
         Serve_File
           (State, X,
            Project_Root & "/assets/brand/flyology-mark-transparent.svg",
            "image/svg+xml");
      end Brand_Mark;

      procedure Geologica_Font
        (State : in out Application_Context;
         X     : in out App.Exchange) is
      begin
         Serve_File
           (State, X,
            Project_Root
            & "/website/assets/fonts/geologica-latin-variable.woff2",
            "font/woff2");
      end Geologica_Font;


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
         --  Stream_Body means the exchange never materializes the complete
         --  upload. Read_Body is deadline-aware and charges shared ingress.
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
         --  Begin, write, and end all happen on the connection owner. The
         --  exchange prevents another task from writing this response.
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
         --  The outer error middleware logs this detail, but the browser sees
         --  only its generic safe problem response.
         raise Constraint_Error with "example application failure";
      end Demonstrate_Error;

      procedure SSE_Events
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         package SSE renames Flyology.HTTP.Server.SSE_Handlers;
         Session  : aliased SSE.Session
           (Capacity => 3,
            Byte_Limit =>
              SSE.Default_Session_Bytes,
            Budget => null);

         --  The producer is nested inside the request task master. Its access
         --  to Session remains valid until the nested scope joins it.
         type Session_Access is access all SSE.Session;

         function Phase (Sequence : Positive) return String is
           (case Sequence is
               when 1 => "request accepted",
               when 2 => "route selected",
               when 3 => "lightweight task suspended",
               when 4 => "file completion received",
               when 5 => "mailbox backpressure released",
               when others => "response owner flushed");

         function Detail (Sequence : Positive) return String is
           (case Sequence is
               when 1 => "The request head passed bounded admission.",
               when 2 => "Route policy admitted an SSE lifecycle.",
               when 3 => "The event loop is free while the producer waits.",
               when 4 => "Read_At returned ownership of its buffer.",
               when 5 => "The sole writer drained another queued event.",
               when others => "The final typed event is on the wire.");

         task type Producer (Item : not null Session_Access) is
            pragma Task_Info (Model);
         end Producer;

         task body Producer is
            Accepted : Boolean;
            Timed_Out : Boolean;
         begin
            for Sequence in 1 .. 6 loop
               exit when SSE.Cancelled (Item.all);
               Flyology.IO.Timers.Sleep_For
                 ((if Sequence = 4 then 0.9 else 0.32));
               SSE.Publish_For
                 (Item.all,
                  (Data => Ada.Strings.Unbounded.To_Unbounded_String
                     ("{""sequence"":" & Compact (Sequence)
                      & ",""phase"":""" & Phase (Sequence)
                      & """,""detail"":""" & Detail (Sequence)
                      & """}"),
                   Event => Ada.Strings.Unbounded.To_Unbounded_String
                     ("flight"),
                   Id => Ada.Strings.Unbounded.To_Unbounded_String
                     (Compact (Sequence)),
                   Retry => 1_000,
                   Include_Id => True,
                   Include_Retry => Sequence = 1),
                  Accepted, Timeout => 1.0, Timed_Out => Timed_Out);
               --  Publish_For waits only within its explicit bound when the
               --  three-slot mailbox is full. It never writes the socket.
               exit when not Accepted or else Timed_Out;
            end loop;
            if not SSE.Cancelled (Item.all) then
               SSE.Publish_For
                 (Item.all,
                  (Data => Ada.Strings.Unbounded.To_Unbounded_String ("{}"),
                   Event => Ada.Strings.Unbounded.To_Unbounded_String
                     ("complete"),
                   Id => Ada.Strings.Unbounded.Null_Unbounded_String,
                   Retry => 0,
                   Include_Id => False,
                   Include_Retry => False),
                  Accepted, Timeout => 1.0, Timed_Out => Timed_Out);
            end if;
            SSE.Close (Item.all);
         exception
            when others =>
               SSE.Close (Item.all);
         end Producer;
      begin
         Complete (State);
         declare
            Source : Producer (Session'Unchecked_Access);
         begin
            --  Run is the sole response writer. It drains events in order,
            --  emits heartbeats while idle, and notices client cancellation.
            SSE.Run
              (X, Session, Metrics'Access,
               Idle_Quantum => 0.05, Heartbeat => 0.5);
         end;
      end SSE_Events;

      procedure WS_Open
        (X       : in out App.Exchange;
         Session : in out Flyology.HTTP.Server.WebSocket_Handlers.Session)
      is
         pragma Unreferenced (X);
         Accepted : Boolean;
      begin
         --  Open callbacks publish into the same bounded owner-drained queue.
         Flyology.HTTP.Server.WebSocket_Handlers.Try_Publish
           (Session,
            (Kind => HTTP.Text_Frame,
             Data => Bytes.From_Byte_String
               ("system: WebSocket accepted; the connection owner is ready")),
            Accepted);
      end WS_Open;

      procedure WS_Message
        (X       : in out App.Exchange;
         Session : in out Flyology.HTTP.Server.WebSocket_Handlers.Session;
         Kind    : HTTP.WebSocket_Data_Kind;
         Data    : Bytes.Unbounded_Bytes)
      is
         pragma Unreferenced (X);
         Accepted : Boolean;
      begin
         --  Binary frames remain Unbounded_Bytes. Text conversion occurs only
         --  in the text branch used to prepend the visible echo label.
         Flyology.HTTP.Server.WebSocket_Handlers.Try_Publish
           (Session,
            (Kind => Kind,
             Data =>
               (if Kind = HTTP.Text_Frame
                then Bytes.From_Byte_String
                  ("flyology: " & Bytes.To_Byte_String (Data))
                else Data)),
            Accepted);
         if not Accepted then
            Flyology.HTTP.Server.WebSocket_Handlers.Close (Session);
         end if;
      end WS_Message;

      procedure WS_Closed
        (X       : in out App.Exchange;
         Session : in out Flyology.HTTP.Server.WebSocket_Handlers.Session) is
      begin
         pragma Unreferenced (X, Session);
      end WS_Closed;

      procedure WebSocket_Echo
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         package WS renames Flyology.HTTP.Server.WebSocket_Handlers;
         Session : aliased WS.Session
           (Capacity => 16,
            Byte_Limit => WS.Default_Session_Bytes,
            Budget => null);
         --  Producers may retain the bounded mailbox during this request, but
         --  none receives the borrowed exchange or connection.
         type Session_Access is access all WS.Session;
         task type Producer
           (Item : not null Session_Access;
            Text : Character) is
            pragma Task_Info (Model);
         end Producer;

         task body Producer is
            Accepted : Boolean;
            Timed_Out : Boolean;
         begin
            Flyology.IO.Timers.Sleep_For
              ((if Text = 'a' then 0.08 else 0.22));
            WS.Publish_For
              (Item.all,
               (Kind => HTTP.Text_Frame,
                Data => Bytes.From_Byte_String
                  ("system: producer " & Text
                   & " published without owning the connection")),
               Accepted, Timeout => 1.0, Timed_Out => Timed_Out);
            --  The lifecycle owner below is the only task that emits frames.
            pragma Assert (Accepted and then not Timed_Out);
         end Producer;
         package WS_Lifecycle is new
           WS.Lifecycle (WS_Open, WS_Message, WS_Closed);
      begin
         Complete (State);
         declare
            First  : Producer (Session'Unchecked_Access, 'a');
            Second : Producer (Session'Unchecked_Access, 'b');
         begin
            --  Origin validation precedes the lifecycle upgrade and callbacks.
            WS_Lifecycle.Run
              (X, Session,
               Origin_Policy => HTTP.Require_Exact_Origin,
               Allowed_Origin => Origin,
               Metric_Output => Metrics'Access);
         end;
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
         Scope : Request_Operations.Scope (2, X.Cancellation);
         User, Orders : Request_Operations.Operation_Handle;
      begin
         --  Configure copies the exchange cancellation token and absolute
         --  deadline into the scope. Children cannot extend either value.
         Request_Work.Configure (Scope, X);
         Request_Operations.Spawn (Scope, 20, User);
         Request_Operations.Spawn (Scope, 1, Orders);
         Request_Operations.Join (Scope);
         --  Results are read only after Join. Scope finalization also cancels
         --  and joins unfinished children on an exceptional exit.
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
      Native_Pool : aliased Native_Work.Executor
        (Workers => 4, Capacity => 64);

      procedure Native_Boundary
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         Work  : Native_Work.Operation_Handle (Native_Pool'Access);
         Value : Integer;
         Accepted : Boolean;
      begin
         --  Blocking or CPU-heavy work crosses an explicit bounded boundary.
         --  The current lightweight task does not become a native task.
         Native_Work.Submit
           (Native_Pool, 12, X.Cancellation, X.Deadline,
            Work, Accepted);
         if not Accepted then
            X.Problem (503, "native-bulkhead", "Native executor is full");
            return;
         end if;
         Native_Work.Await
           (Native_Pool, Work, Value, X.Cancellation, X.Deadline);
         Complete (State);
         X.Text
           (200, "native" & Integer'Image (Value) & ASCII.LF);
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
           (Capacity => 24, Slashes => Routing.Strict_Slashes);
         Budget      : aliased HTTP.Ingress_Budget
           (Limit => 64 * 1_024 * 1_024);
      end record;

      procedure Handle
        (State        : in out Context;
         Connection   : in out Owned.Connection;
         Peer         : Sockets.Sock_Addr_Type;
         Cancellation : not null access Owned.Cancellation_Token)
      is
         --  Connection_Transport borrows the structured server's owning
         --  connection. HTTP.Connection adds protocol state without taking
         --  closing ownership away from the structured server.
         Channel : aliased HTTP.Connections.Connection_Transport
           (Connection'Unchecked_Access);
         Client : aliased HTTP.Connection (Channel'Access);
      begin
         --  Every connection charges buffered or retained request bytes to the
         --  same 64 MiB ingress budget before application body consumption.
         HTTP.Configure_Ingress_Budget (Client, State.Budget'Access);
         State.Routes.Serve
           (State.Application, Client, Peer,
            Timeout        => 120.0,
            Token          => Cancellation,
            Header_Timeout => 10.0);
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
      --  Registration order is execution order around the route. Error
      --  mapping is outermost so failures in later components are contained.
      State.Routes.Add_Middleware (Error_Middleware.Call'Access);
      State.Routes.Add_Middleware (Request_ID_Middleware.Call'Access);
      State.Routes.Add_Middleware (Logging_Middleware.Call'Access);
      State.Routes.Add_Middleware (Metrics_Middleware.Call'Access);
      State.Routes.Add_Middleware (CORS_Middleware.Call'Access);
      State.Routes.Add_Middleware (Rate_Middleware.Call'Access);
      State.Routes.Add_Middleware (Bulkhead_Middleware.Call'Access);
      State.Routes.Add_Middleware
        (Security_Middleware.Call'Access, Stage => Routing.Application);

      --  Static assets use ordinary routes and the same middleware as dynamic
      --  handlers. The low-level server remains usable without this router.
      State.Routes.Get ("/", Home'Access, Name => "home");
      State.Routes.Get
        ("/assets/app.css", Application_CSS'Access, Name => "assets.css");
      State.Routes.Get
        ("/assets/app.js", Application_JS'Access, Name => "assets.js");
      State.Routes.Get
        ("/assets/mark.svg", Brand_Mark'Access, Name => "assets.mark");
      State.Routes.Get
        ("/assets/geologica.woff2", Geologica_Font'Access,
         Name => "assets.font");
      State.Routes.Get
        ("/users/{id}", Show_User'Access, Name => "users.show");
      State.Routes.Post
        ("/echo", Buffered_Echo'Access, Name => "echo",
         Policy =>
           (Routing.Default_Route_Policy with delta
              --  Buffer only this small body after routing and admission.
              Body_Handling => App.Buffer_Body,
              Max_Body      => 64 * 1_024));
      State.Routes.Post
        ("/upload", Upload'Access, Name => "upload",
         Policy =>
           (Routing.Default_Route_Policy with delta
              --  Upload bytes are pulled incrementally by the handler.
              Body_Handling => App.Stream_Body,
              Timeout       => 30.0));
      State.Routes.Add_Route_Middleware
        ("upload", Deadline_Middleware.Call'Access);
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
              --  Upgrade eligibility and lifetime are explicit route policy.
              Upgrade => Routing.Allow_SSE,
              Timeout => 8.0));
      State.Routes.Get
        ("/chat", WebSocket_Echo'Access, Name => "chat",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Upgrade     => Routing.Allow_WebSocket,
              CORS_Policy => 1,
              Timeout     => 90.0));
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
      --  Mount keeps child policy and prefixes names so logs and metrics use
      --  bounded "admin.*" labels instead of arbitrary raw paths.
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

      --  Start workers only after listener setup succeeds. A bind or listen
      --  failure therefore cannot leave a partially initialized executor.
      Native_Work.Start (Native_Pool);

      Ada.Text_IO.Put_Line
        ("READY " & Lane & " http://127.0.0.1:"
         & Compact (Natural (Port)) & "/");
      Ada.Text_IO.Flush;

      declare
         --  Shutdown coordination is native and independent of the selected
         --  handler model. Goal zero keeps this entry closed indefinitely.
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
