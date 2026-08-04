with Ada.Characters.Handling;
with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with System.Multiprocessors;
with Flyology;
with Flyology.Bytes;
with Flyology.Cancellation;
with Flyology.Execution_Groups;
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
with Flyology.HTTP.Server.WebSocket_Handlers.Lifecycle;
with Flyology.IO.Connections;
with Flyology.IO.Files;
with Flyology.IO.Sockets;
with Flyology.IO.Structured_Servers;
with Flyology.IO.Timers;
with Flyology.Native_Executors;
with Flyology.Observability;
with UUIDs;
with UUIDs.V7;

procedure HTTP_Application_Server is
   use type Ada.Streams.Stream_Element_Offset;
   use type Flyology.Observability.Counter;
   use type Flyology.Execution_Groups.Group_Id;
   use type Flyology.HTTP.Server.WebSocket_Data_Kind;
   use type Flyology.IO.Files.File_Descriptor;
   use type Flyology.IO.Files.File_Offset;

   package HTTP renames Flyology.HTTP.Server;
   package App renames Flyology.HTTP.Server.Applications;
   package Bytes renames Flyology.Bytes;
   package Files renames Flyology.IO.Files;
   package Groups renames Flyology.Execution_Groups;
   package Observation renames Flyology.Observability;
   package Request_Helpers renames Flyology.HTTP.Server.Requests;
   package Sockets renames Flyology.IO.Sockets;
   package Owned renames Flyology.IO.Connections;

   --  Keep the command line compatible with the benchmark showcases. A zero
   --  request goal leaves the interactive server running until it is stopped.
   Lane : constant String :=
     (if Ada.Command_Line.Argument_Count >= 1
      then Ada.Command_Line.Argument (1) else "lightweight");
   Request_Goal : constant Natural :=
     (if Ada.Command_Line.Argument_Count >= 2
      then Natural'Value (Ada.Command_Line.Argument (2)) else 100_000);
   Port : constant Sockets.Port :=
     (if Ada.Command_Line.Argument_Count >= 3
      then Sockets.Port'Value (Ada.Command_Line.Argument (3)) else 18_082);
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

   function Compact (Value : Observation.Counter) return String is
     (Ada.Strings.Fixed.Trim
        (Observation.Counter'Image (Value), Ada.Strings.Both));

   function Compact (Value : Duration) return String is
     (Ada.Strings.Fixed.Trim (Duration'Image (Value), Ada.Strings.Both));

   function Hex_Digit (Value : Natural) return Character is
     (if Value < 10
      then Character'Val (Character'Pos ('0') + Value)
      else Character'Val (Character'Pos ('A') + Value - 10));

   function JSON_Quote (Value : String) return String is
      Result : Ada.Strings.Unbounded.Unbounded_String;
   begin
      Ada.Strings.Unbounded.Append (Result, '"');
      for Item of Value loop
         case Item is
            when '"' | Character'Val (92) =>
               Ada.Strings.Unbounded.Append
                 (Result, Character'Val (92));
               Ada.Strings.Unbounded.Append (Result, Item);
            when ASCII.BS =>
               Ada.Strings.Unbounded.Append (Result, "\b");
            when ASCII.HT =>
               Ada.Strings.Unbounded.Append (Result, "\t");
            when ASCII.LF =>
               Ada.Strings.Unbounded.Append (Result, "\n");
            when ASCII.FF =>
               Ada.Strings.Unbounded.Append (Result, "\f");
            when ASCII.CR =>
               Ada.Strings.Unbounded.Append (Result, "\r");
            when others =>
               if Character'Pos (Item) < 32 then
                  Ada.Strings.Unbounded.Append
                    (Result,
                     "\u00"
                     & Hex_Digit (Character'Pos (Item) / 16)
                     & Hex_Digit (Character'Pos (Item) mod 16));
               else
                  Ada.Strings.Unbounded.Append (Result, Item);
               end if;
         end case;
      end loop;
      Ada.Strings.Unbounded.Append (Result, '"');
      return Ada.Strings.Unbounded.To_String (Result);
   end JSON_Quote;

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

      --  The UUID library protects its randomizer internally, but the
      --  application owns this additional serialization point so generator
      --  state and any future deployment prefix remain explicitly task-safe.
      protected type UUIDv7_Request_ID_Source is
         procedure Initialize;
         procedure Generate
           (Value : out Ada.Strings.Unbounded.Unbounded_String);
      private
         Ready : Boolean := False;
      end UUIDv7_Request_ID_Source;

      protected body UUIDv7_Request_ID_Source is
         procedure Initialize is
         begin
            if not Ready then
               declare
                  Discard : constant UUIDs.UUID := UUIDs.V7.UUID7;
                  pragma Unreferenced (Discard);
               begin
                  Ready := True;
               end;
            end if;
         end Initialize;

         procedure Generate
           (Value : out Ada.Strings.Unbounded.Unbounded_String)
         is
            Item : constant UUIDs.UUID := UUIDs.V7.UUID7;
         begin
            --  Generate remains safe even if a caller forgets the eager
            --  initialization below. The normal server path initializes on
            --  the native environment task before lightweight work starts.
            Ready := True;
            Value := Ada.Strings.Unbounded.To_Unbounded_String (Item'Image);
         end Generate;
      end UUIDv7_Request_ID_Source;

      type Application_Context is limited record
         Calls         : Natural := 0;
         Introspection : Ada.Strings.Unbounded.Unbounded_String;
         Request_IDs   : UUIDv7_Request_ID_Source;
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

      Access_Log_Capacity  : constant Positive := 64;
      Access_Log_Max_Bytes : constant Positive := 1_024;

      subtype Access_Log_Index is Natural range 0 .. Access_Log_Capacity - 1;

      type Access_Log_Entry is record
         Sequence : Observation.Counter := 0;
         Length   : Natural range 0 .. Access_Log_Max_Bytes := 0;
         Data     : String (1 .. Access_Log_Max_Bytes) := (others => ' ');
      end record;

      type Access_Log_Entries is
        array (Access_Log_Index) of Access_Log_Entry;

      --  Logging must never wait for a browser. Completed request records are
      --  copied into a fixed ring, and each SSE subscriber advances its own
      --  cursor over the retained window. Slow subscribers observe a gap
      --  count instead of applying backpressure to request completion.
      protected type Access_Log_Buffer is
         procedure Append (Value : String);
         procedure Read_After
           (After     : Observation.Counter;
            Value     : out Access_Log_Entry;
            Available : out Boolean;
            Dropped   : out Observation.Counter);
      private
         Entries       : Access_Log_Entries;
         Head          : Access_Log_Index := 0;
         Count         : Natural range 0 .. Access_Log_Capacity := 0;
         Next_Sequence : Observation.Counter := 1;
      end Access_Log_Buffer;

      protected body Access_Log_Buffer is
         procedure Append (Value : String) is
            Overflow : constant String :=
              "{""type"":""access-log-record-too-large""}";
            Stored   : constant String :=
              (if Value'Length <= Access_Log_Max_Bytes then Value else Overflow);
            Slot     : Access_Log_Index;
         begin
            if Count = Access_Log_Capacity then
               Slot := Head;
               Head := Access_Log_Index
                 ((Natural (Head) + 1) mod Access_Log_Capacity);
            else
               Slot := Access_Log_Index
                 ((Natural (Head) + Count) mod Access_Log_Capacity);
               Count := Count + 1;
            end if;
            Entries (Slot).Sequence := Next_Sequence;
            Entries (Slot).Length := Stored'Length;
            Entries (Slot).Data (1 .. Stored'Length) := Stored;
            Next_Sequence := Next_Sequence + 1;
         end Append;

         procedure Read_After
           (After     : Observation.Counter;
            Value     : out Access_Log_Entry;
            Available : out Boolean;
            Dropped   : out Observation.Counter)
         is
            Slot : Access_Log_Index;
         begin
            Value := (others => <>);
            Available := False;
            Dropped := 0;
            if Count = 0 then
               return;
            end if;
            for Offset in 0 .. Count - 1 loop
               Slot := Access_Log_Index
                 ((Natural (Head) + Offset) mod Access_Log_Capacity);
               if Entries (Slot).Sequence > After then
                  Value := Entries (Slot);
                  Available := True;
                  Dropped := Entries (Slot).Sequence - After - 1;
                  return;
               end if;
            end loop;
         end Read_After;
      end Access_Log_Buffer;

      type Console_Logger is limited new
        Flyology.HTTP.Server.Logging.Sink with record
         Lock : Log_Lock;
         Feed : Access_Log_Buffer;
      end record;

      overriding procedure Write
        (Item           : in out Console_Logger;
         Method         : String;
         Route          : String;
         Target         : String;
         Status         : Natural;
         Request_ID     : String;
         Peer           : Sockets.Endpoint;
         Request_Bytes  : Natural;
         Response_Bytes : Natural;
         Elapsed        : Duration)
      is
         pragma Unreferenced (Target);
      begin
         declare
            Record_JSON : constant String :=
              "{""method"":" & JSON_Quote (Method)
              & ",""route"":" & JSON_Quote (Route)
              & ",""status"":" & Compact (Status)
              & ",""request_id"":" & JSON_Quote (Request_ID)
              & ",""peer"":" & JSON_Quote (Sockets.Image (Peer))
              & ",""request_bytes"":" & Compact (Request_Bytes)
              & ",""response_bytes"":" & Compact (Response_Bytes)
              & ",""elapsed"":" & Compact (Elapsed) & "}";
         begin
            Item.Feed.Append (Record_JSON);
         end;
         Item.Lock.Put
           (Method & " " & Route & " status="
            & Ada.Strings.Fixed.Trim
                (Natural'Image (Status), Ada.Strings.Both)
            & " request_id=" & Request_ID);
      exception
         when others =>
            --  A diagnostic sink cannot be allowed to fail the request it
            --  observes. Middleware also guards this boundary independently.
            null;
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

      procedure Generate_Request_ID
        (State : in out Application_Context;
         X     : App.Exchange;
         Value : out Ada.Strings.Unbounded.Unbounded_String)
      is
         pragma Unreferenced (X);
      begin
         --  The borrowed exchange is available for trace-context policies,
         --  but this showcase needs only application-owned UUIDv7 state.
         State.Request_IDs.Generate (Value);
      end Generate_Request_ID;

      package Error_Middleware is new
        Flyology.HTTP.Server.Middleware_Errors
          (Application_Context, Routing.Components, Log => Error_Log);
      package Request_ID_Middleware is new
        Flyology.HTTP.Server.Middleware_Request_IDs
          (Application_Context, Routing.Components,
           Trust_Inbound => False,
           Generate      => Generate_Request_ID'Access);
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

      Migration_Worker_Count : constant Positive := 4;
      subtype Migration_Worker_Id is
        Positive range 1 .. Migration_Worker_Count;

      type Migration_Action is
        (No_Migration_Action, Populate_Groups, Rotate_Groups,
         Consolidate_Group_Zero);
      type Migration_Group_Array is
        array (Migration_Worker_Id) of Groups.Group_Id;
      type Migration_Count_Array is
        array (Migration_Worker_Id) of Natural;
      type Migration_Online_Array is
        array (Migration_Worker_Id) of Boolean;

      type Migration_Lab_Snapshot is record
         Worker_Groups : Migration_Group_Array :=
           (others => Groups.Default_Group);
         Moves       : Migration_Count_Array := (others => 0);
         Online      : Migration_Online_Array := (others => False);
         Active      : Natural range 0 .. Migration_Worker_Count := 0;
         Total_Moves : Natural := 0;
         Failures    : Natural := 0;
         Last_Action : Migration_Action := No_Migration_Action;
      end record;

      --  Runtime samples can race with migration commands. Keep the lab's
      --  small public snapshot behind one protected object; scheduler state
      --  itself remains owned and observed through Flyology's runtime APIs.
      protected Migration_Lab is
         procedure Started
           (Worker : Migration_Worker_Id;
            Group  : Groups.Group_Id);
         procedure Record_Move
           (Worker    : Migration_Worker_Id;
            Group     : Groups.Group_Id;
            Moved     : Boolean;
            Succeeded : Boolean);
         procedure Finish (Action : Migration_Action);
         function Read return Migration_Lab_Snapshot;
      private
         Value : Migration_Lab_Snapshot;
      end Migration_Lab;

      protected body Migration_Lab is
         procedure Started
           (Worker : Migration_Worker_Id;
            Group  : Groups.Group_Id) is
         begin
            if not Value.Online (Worker) then
               Value.Active := Value.Active + 1;
            end if;
            Value.Online (Worker) := True;
            Value.Worker_Groups (Worker) := Group;
         end Started;

         procedure Record_Move
           (Worker    : Migration_Worker_Id;
            Group     : Groups.Group_Id;
            Moved     : Boolean;
            Succeeded : Boolean) is
         begin
            Value.Worker_Groups (Worker) := Group;
            if Succeeded and then Moved then
               Value.Moves (Worker) := Value.Moves (Worker) + 1;
               Value.Total_Moves := Value.Total_Moves + 1;
            elsif not Succeeded then
               Value.Failures := Value.Failures + 1;
            end if;
         end Record_Move;

         procedure Finish (Action : Migration_Action) is
         begin
            Value.Last_Action := Action;
         end Finish;

         function Read return Migration_Lab_Snapshot is (Value);
      end Migration_Lab;

      task type Migration_Worker (Worker : Migration_Worker_Id) is
         pragma Task_Info (Flyology.Lightweight_Task);
         entry Move_To (Destination : Groups.Shared_Group_Id);
         entry Stop;
      end Migration_Worker;

      task body Migration_Worker is
      begin
         Migration_Lab.Started (Worker, Groups.Current);
         loop
            select
               accept Move_To (Destination : Groups.Shared_Group_Id) do
                  declare
                     Before    : constant Groups.Group_Id := Groups.Current;
                     Arrived   : Groups.Group_Id := Before;
                     Did_Move  : constant Boolean := Before /= Destination;
                     Succeeded : Boolean := True;
                  begin
                     begin
                        --  Migration is a cooperative safe point performed by
                        --  the lightweight task that owns this stack. The
                        --  controller never moves an arbitrary runtime task.
                        if Did_Move then
                           Groups.Migrate (Destination);
                           Arrived := Groups.Current;
                        end if;
                     exception
                        when others =>
                           Succeeded := False;
                     end;
                     Migration_Lab.Record_Move
                       (Worker, Arrived, Did_Move, Succeeded);
                  end;
               end Move_To;
            or
               accept Stop;
               exit;
            end select;
         end loop;
      end Migration_Worker;

      type Migration_Worker_Access is access Migration_Worker;
      type Migration_Worker_Array is
        array (Migration_Worker_Id) of Migration_Worker_Access;
      Migration_Workers : Migration_Worker_Array := (others => null);

      function Migration_Action_Name
        (Value : Migration_Action) return String is
        (case Value is
            when No_Migration_Action      => "none",
            when Populate_Groups          => "populate",
            when Rotate_Groups            => "rotate",
            when Consolidate_Group_Zero   => "consolidate");

      procedure Ensure_Migration_Workers is
      begin
         --  Laziness matters to the native showcase: merely serving the page
         --  must not start event-loop machinery. The first explicit lab action
         --  creates these four isolated lightweight tasks.
         for Worker in Migration_Worker_Id loop
            if Migration_Workers (Worker) = null then
               Migration_Workers (Worker) := new Migration_Worker (Worker);
            end if;
         end loop;
      end Ensure_Migration_Workers;

      function Body_Name
        (Value : App.Request_Body_Policy) return String is
        (case Value is
            when App.Reject_Body         => "reject",
            when App.Stream_Body         => "stream",
            when App.Buffer_Body         => "buffer",
            when App.Discard_Request_Body => "discard");

      function Authentication_Name
        (Value : App.Authentication_Mode) return String is
        (case Value is
            when App.No_Authentication       => "none",
            when App.Optional_Authentication => "optional",
            when App.Required_Authentication => "required");

      function Upgrade_Name (Value : App.Upgrade_Mode) return String is
        (case Value is
            when App.No_Upgrade       => "none",
            when App.Allow_SSE        => "sse",
            when App.Allow_WebSocket  => "websocket");

      function Stage_Name (Value : Routing.Middleware_Stage) return String is
        (case Value is
            when Routing.Request_Head => "request-head",
            when Routing.Application  => "application");

      function Thread_State_Name
        (Value : Observation.Event_Thread_State) return String is
        (case Value is
            when Observation.Starting => "starting",
            when Observation.Running  => "running",
            when Observation.Failed   => "failed");

      function Build_Routing_JSON (Item : Routing.Router) return String is
         Result : Ada.Strings.Unbounded.Unbounded_String;
      begin
         Ada.Strings.Unbounded.Append
           (Result,
            "{""lane"":" & JSON_Quote (Lane)
            & ",""capacity"":" & Compact (Capacity)
            & ",""cpu_count"":"
            & Compact
                (Natural (System.Multiprocessors.Number_Of_CPUs))
            & ",""configured_groups"":"
            & Compact (Natural (Groups.Configured_Pool_Size))
            & "," & JSON_Quote ("middleware") & ":[");
         for Index in 1 .. Routing.Global_Middleware_Count (Item) loop
            declare
               Value : constant Routing.Middleware_Description :=
                 Routing.Describe_Global_Middleware (Item, Index);
            begin
               if Index > 1 then
                  Ada.Strings.Unbounded.Append (Result, ',');
               end if;
               Ada.Strings.Unbounded.Append
                 (Result,
                  "{""name"":"
                  & JSON_Quote (Ada.Strings.Unbounded.To_String (Value.Name))
                  & ",""stage"":" & JSON_Quote (Stage_Name (Value.Stage))
                  & "}");
            end;
         end loop;
         Ada.Strings.Unbounded.Append
           (Result, "]," & JSON_Quote ("routes") & ":[");
         for Index in 1 .. Routing.Route_Count (Item) loop
            declare
               Value : constant Routing.Route_Description :=
                 Routing.Describe_Route (Item, Index);
               Policy : Routing.Route_Policy renames Value.Policy;
            begin
               if Index > 1 then
                  Ada.Strings.Unbounded.Append (Result, ',');
               end if;
               Ada.Strings.Unbounded.Append
                 (Result,
                  "{""method"":"
                  & JSON_Quote (Ada.Strings.Unbounded.To_String (Value.Method))
                  & ",""pattern"":"
                  & JSON_Quote (Ada.Strings.Unbounded.To_String (Value.Pattern))
                  & ",""name"":"
                  & JSON_Quote (Ada.Strings.Unbounded.To_String (Value.Name))
                  & "," & JSON_Quote ("policy") & ":{"
                  & JSON_Quote ("body") & ":"
                  & JSON_Quote (Body_Name (Policy.Body_Handling))
                  & ",""max_body"":" & Compact (Policy.Max_Body)
                  & ",""timeout"":" & Compact (Policy.Timeout)
                  & ",""concurrency"":" & Compact (Policy.Concurrency)
                  & ",""rate"":" & Compact (Policy.Rate_Per_Second)
                  & ",""authentication"":"
                  & JSON_Quote (Authentication_Name (Policy.Authentication))
                  & ",""cors_slot"":" & Compact (Policy.CORS_Policy)
                  & ",""upgrade"":"
                  & JSON_Quote (Upgrade_Name (Policy.Upgrade))
                  & "}," & JSON_Quote ("middleware") & ":[");
               for Middleware_Index in 1 ..
                 Routing.Route_Middleware_Count (Item, Index)
               loop
                  declare
                     Middleware : constant Routing.Middleware_Description :=
                       Routing.Describe_Route_Middleware
                         (Item, Index, Middleware_Index);
                  begin
                     if Middleware_Index > 1 then
                        Ada.Strings.Unbounded.Append (Result, ',');
                     end if;
                     Ada.Strings.Unbounded.Append
                       (Result,
                        "{""name"":"
                        & JSON_Quote
                            (Ada.Strings.Unbounded.To_String
                               (Middleware.Name))
                        & ",""stage"":"
                        & JSON_Quote (Stage_Name (Middleware.Stage)) & "}");
                  end;
               end loop;
               Ada.Strings.Unbounded.Append (Result, "]}");
            end;
         end loop;
         Ada.Strings.Unbounded.Append (Result, "]}");
         return Ada.Strings.Unbounded.To_String (Result);
      end Build_Routing_JSON;

      function Runtime_JSON (Sequence : Positive) return String is
         Result  : Ada.Strings.Unbounded.Unbounded_String;
         Stack   : constant Observation.Stack_Pool_Snapshot :=
           Observation.Stack_Pool;
         HTTP_Metrics : constant Flyology.HTTP.Server.Metrics.Snapshot :=
           Metrics.Read;
         First_Group : Boolean := True;
         Created     : Natural := 0;
         Lab         : constant Migration_Lab_Snapshot := Migration_Lab.Read;
      begin
         Ada.Strings.Unbounded.Append
           (Result,
            "{""sequence"":" & Compact (Sequence)
            & ",""lane"":" & JSON_Quote (Lane)
            & ",""cpu_count"":"
            & Compact (Natural (System.Multiprocessors.Number_Of_CPUs))
            & ",""configured_groups"":"
            & Compact (Natural (Groups.Configured_Pool_Size))
            & "," & JSON_Quote ("http") & ":{"
            & JSON_Quote ("active") & ":" & Compact (HTTP_Metrics.Active)
            & ",""requests"":" & Compact (HTTP_Metrics.Requests)
            & ",""request_bytes"":"
            & Compact (HTTP_Metrics.Request_Bytes)
            & ",""response_bytes"":"
            & Compact (HTTP_Metrics.Response_Bytes) & "}"
            & "," & JSON_Quote ("stacks") & ":{"
            & JSON_Quote ("live") & ":" & Compact (Stack.Live_Stacks)
            & ",""arenas"":" & Compact (Stack.Active_Arenas)
            & ",""usable_bytes"":" & Compact (Stack.Live_Usable_Bytes)
            & ",""reserved_bytes"":" & Compact (Stack.Reserved_Bytes)
            & "}," & JSON_Quote ("groups") & ":[");
         for Index in 0 .. Natural (Groups.Configured_Pool_Size) - 1 loop
            declare
               Sample : Observation.Group_Snapshot;
               Available : constant Boolean := Observation.Snapshot
                 (Observation.Group_Id (Index), Sample);
            begin
               if Available then
                  Created := Created + 1;
                  if not First_Group then
                     Ada.Strings.Unbounded.Append (Result, ',');
                  end if;
                  First_Group := False;
                  Ada.Strings.Unbounded.Append
                    (Result,
                     "{""id"":" & Compact (Index)
                     & ",""state"":"
                     & JSON_Quote (Thread_State_Name (Sample.Thread_State))
                     & ",""members"":" & Compact (Sample.Members)
                     & ",""pinned"":" & Compact (Sample.Pinned_Members)
                     & ",""ready"":" & Compact (Sample.Ready)
                     & ",""waiting"":" & Compact (Sample.Waiting)
                     & ",""running"":" & Compact (Sample.Running)
                     & ",""timers"":" & Compact (Sample.Timer_Waits)
                     & ",""descriptors"":"
                     & Compact (Sample.Descriptor_Waits)
                     & ",""files"":" & Compact (Sample.File_Waits)
                     & ",""dispatches"":" & Compact (Sample.Dispatches)
                     & ",""poll_events"":" & Compact (Sample.Poll_Events)
                     & ",""wakeups"":" & Compact (Sample.Wakeups) & "}");
               end if;
            end;
         end loop;
         Ada.Strings.Unbounded.Append
           (Result,
            "],""created_groups"":" & Compact (Created)
            & ",""migration_lab"":{"
            & """started"":" & (if Lab.Active > 0 then "true" else "false")
            & ",""active_workers"":" & Compact (Lab.Active)
            & ",""total_moves"":" & Compact (Lab.Total_Moves)
            & ",""failures"":" & Compact (Lab.Failures)
            & ",""last_action"":"
            & JSON_Quote (Migration_Action_Name (Lab.Last_Action))
            & ",""workers"":[");
         for Worker in Migration_Worker_Id loop
            if Worker > Migration_Worker_Id'First then
               Ada.Strings.Unbounded.Append (Result, ',');
            end if;
            Ada.Strings.Unbounded.Append
              (Result,
               "{""id"":" & Compact (Worker)
               & ",""online"":"
               & (if Lab.Online (Worker) then "true" else "false")
               & ",""group"":"
               & Compact (Natural (Lab.Worker_Groups (Worker)))
               & ",""moves"":" & Compact (Lab.Moves (Worker)) & "}");
         end loop;
         Ada.Strings.Unbounded.Append (Result, "]}}");
         return Ada.Strings.Unbounded.To_String (Result);
      end Runtime_JSON;

      Requests : Request_Counter (Request_Goal);

      --  Count only requests that reached an application handler. Rejections
      --  performed before dispatch remain visible through metrics instead.
      procedure Complete (State : in out Application_Context) is
      begin
         State.Calls := State.Calls + 1;
         Requests.Completed;
      end Complete;

      procedure Migration_Action_Endpoint
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         Requested  : constant String := X.Parameter ("action");
         Action     : Migration_Action;
         Pool_Size  : constant Natural :=
           Natural (Groups.Configured_Pool_Size);
         Expected_Origin : constant String :=
           "http://"
           & Ada.Characters.Handling.To_Lower
               (Request_Helpers.Authority (X));
      begin
         --  These controls mutate local scheduler state. Require a browser
         --  same-origin request so an unrelated page cannot drive a listener
         --  on localhost with a simple cross-origin POST.
         if X.Request_Header_Count ("Origin") /= 1
           or else X.Request_Header ("Origin") /= Expected_Origin
         then
            Complete (State);
            X.Problem
              (403, "migration-origin",
               "Migration controls require the showcase origin");
            return;
         end if;

         if Requested = "populate" then
            Action := Populate_Groups;
         elsif Requested = "rotate" then
            Action := Rotate_Groups;
         elsif Requested = "consolidate" then
            Action := Consolidate_Group_Zero;
         else
            Complete (State);
            X.Problem
              (400, "unknown-migration-action",
               "Use populate, rotate, or consolidate");
            return;
         end if;

         Ensure_Migration_Workers;
         declare
            Before : constant Migration_Lab_Snapshot := Migration_Lab.Read;
         begin
            for Worker in Migration_Worker_Id loop
               declare
                  Destination : Groups.Shared_Group_Id;
               begin
                  case Action is
                     when Populate_Groups =>
                        --  Spread wraps when the configured pool has fewer
                        --  groups than the fixed four-worker demonstration.
                        Destination := Groups.Shared_Group_Id
                          ((Worker - Migration_Worker_Id'First) mod Pool_Size);
                     when Rotate_Groups =>
                        Destination := Groups.Shared_Group_Id
                          ((Natural (Before.Worker_Groups (Worker)) + 1)
                           mod Pool_Size);
                     when Consolidate_Group_Zero =>
                        Destination := Groups.Default_Group;
                     when No_Migration_Action =>
                        raise Program_Error;
                  end case;
                  --  The rendezvous returns only after the worker has reached
                  --  its destination or recorded a bounded failure.
                  Migration_Workers (Worker).Move_To (Destination);
               end;
            end loop;
         end;
         Migration_Lab.Finish (Action);
         Complete (State);
         declare
            After : constant Migration_Lab_Snapshot := Migration_Lab.Read;
         begin
            X.JSON
              (200,
               "{""action"":" & JSON_Quote (Requested)
               & ",""workers"":" & Compact (After.Active)
               & ",""configured_groups"":" & Compact (Pool_Size)
               & ",""total_moves"":" & Compact (After.Total_Moves)
               & ",""failures"":" & Compact (After.Failures) & "}");
         end;
      end Migration_Action_Endpoint;

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

      procedure Introspection_Endpoint
        (State : in out Application_Context;
         X     : in out App.Exchange) is
      begin
         Complete (State);
         X.JSON
           (200, Ada.Strings.Unbounded.To_String (State.Introspection));
      end Introspection_Endpoint;

      procedure Runtime_Events
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         package SSE renames Flyology.HTTP.Server.SSE_Handlers;
         Session : aliased SSE.Session
           (Capacity   => 2,
            Byte_Limit => SSE.Default_Session_Bytes,
            Budget     => null);
         type Session_Access is access all SSE.Session;

         task type Producer (Item : not null Session_Access) is
            pragma Task_Info (Model);
         end Producer;

         task body Producer is
            Accepted  : Boolean;
            Timed_Out : Boolean;
         begin
            for Sequence in 1 .. 140 loop
               exit when SSE.Cancelled (Item.all);
               SSE.Publish_For
                 (Item.all,
                  (Data => Ada.Strings.Unbounded.To_Unbounded_String
                     (Runtime_JSON (Sequence)),
                   Event => Ada.Strings.Unbounded.To_Unbounded_String
                     ("runtime"),
                   Id => Ada.Strings.Unbounded.To_Unbounded_String
                     (Compact (Sequence)),
                   Retry         => 1_000,
                   Include_Id    => True,
                   Include_Retry => Sequence = 1),
                  Accepted, Timeout => 0.5, Timed_Out => Timed_Out);
               exit when not Accepted or else Timed_Out;
               Flyology.IO.Timers.Sleep_For (0.75);
            end loop;
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
            --  Sampling reads existing counters only. It does not create
            --  execution groups or add instrumentation to scheduler paths.
            SSE.Run
              (X, Session, Metrics'Access,
               Idle_Quantum => 0.10, Heartbeat => 5.0);
         end;
      end Runtime_Events;

      procedure Request_Log_Events
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         package SSE renames Flyology.HTTP.Server.SSE_Handlers;
         Session : aliased SSE.Session
           (Capacity   => 16,
            Byte_Limit => SSE.Default_Session_Bytes,
            Budget     => null);
         type Session_Access is access all SSE.Session;

         function Event_JSON
           (Value   : Access_Log_Entry;
            Dropped : Observation.Counter) return String is
           ("{""sequence"":" & Compact (Value.Sequence)
            & ",""dropped_before"":" & Compact (Dropped)
            & ",""entry"":" & Value.Data (1 .. Value.Length) & "}");

         function Requested_Cursor return Observation.Counter is
            Value : constant String := X.Request_Header ("Last-Event-ID");
         begin
            return
              (if Value = "" then 0 else Observation.Counter'Value (Value));
         exception
            when Constraint_Error =>
               --  An invalid or out-of-range cursor gets a bounded replay;
               --  it never reaches the protected ring as attacker text.
               return 0;
         end Requested_Cursor;

         task type Producer
           (Item  : not null Session_Access;
            Start : Observation.Counter)
         is
            pragma Task_Info (Model);
         end Producer;

         task body Producer is
            Cursor    : Observation.Counter := Start;
            Value     : Access_Log_Entry;
            Dropped   : Observation.Counter;
            Available : Boolean;
            Accepted  : Boolean;
            Timed_Out : Boolean;
         begin
            loop
               exit when SSE.Cancelled (Item.all);
               Logger.Feed.Read_After
                 (Cursor, Value, Available, Dropped);
               if Available then
                  SSE.Publish_For
                    (Item.all,
                     (Data => Ada.Strings.Unbounded.To_Unbounded_String
                        (Event_JSON (Value, Dropped)),
                      Event => Ada.Strings.Unbounded.To_Unbounded_String
                        ("request"),
                      Id => Ada.Strings.Unbounded.To_Unbounded_String
                        (Compact (Value.Sequence)),
                      Retry         => 1_000,
                      Include_Id    => True,
                      Include_Retry => Cursor = 0),
                     Accepted, Timeout => 0.5, Timed_Out => Timed_Out);
                  if Accepted then
                     Cursor := Value.Sequence;
                  elsif not Timed_Out then
                     exit;
                  end if;
               else
                  --  The access-log callback only copies into the fixed ring.
                  --  This request-scoped producer waits cooperatively for the
                  --  next cursor check and never writes the connection.
                  Flyology.IO.Timers.Sleep_For (0.10);
               end if;
            end loop;
            SSE.Close (Item.all);
         exception
            when others =>
               SSE.Close (Item.all);
         end Producer;
      begin
         Complete (State);
         declare
            Source : Producer
              (Session'Unchecked_Access, Requested_Cursor);
         begin
            --  Run remains the sole response writer even while application
            --  requests complete concurrently on either handler lane.
            SSE.Run
              (X, Session, Metrics'Access,
               Idle_Quantum => 0.05, Heartbeat => 5.0);
         end;
      end Request_Log_Events;

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

      package WS renames Flyology.HTTP.Server.WebSocket_Handlers;

      procedure WS_Open
        (X       : in out App.Exchange;
         Session : in out WS.Session)
      is
         pragma Unreferenced (X);
         Accepted : Boolean;
      begin
         --  Open callbacks publish into the same bounded owner-drained queue.
         WS.Try_Publish
           (Session,
            (Kind => HTTP.Text_Frame,
             Data => Bytes.From_Byte_String
               ("system: WebSocket accepted; the connection owner is ready")),
            Accepted);
      end WS_Open;

      procedure WS_Message
        (X       : in out App.Exchange;
         Session : in out WS.Session;
         Kind    : HTTP.WebSocket_Data_Kind;
         Data    : Bytes.Unbounded_Bytes)
      is
         pragma Unreferenced (X);
         Accepted : Boolean;
      begin
         --  Binary frames remain Unbounded_Bytes. Text conversion occurs only
         --  in the text branch used to prepend the visible echo label.
         WS.Try_Publish
           (Session,
            (Kind => Kind,
             Data =>
               (if Kind = HTTP.Text_Frame
                then Bytes.From_Byte_String
                  ("flyology: " & Bytes.To_Byte_String (Data))
                else Data)),
            Accepted);
         if not Accepted then
            WS.Close (Session);
         end if;
      end WS_Message;

      procedure WS_Closed
        (X       : in out App.Exchange;
         Session : in out WS.Session) is
      begin
         pragma Unreferenced (X, Session);
      end WS_Closed;

      procedure WebSocket_Echo
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         Session : aliased WS.Session
           (Capacity => 16,
            Byte_Limit => WS.Default_Session_Bytes,
            Budget => null,
            Buffer_Pool => null);
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
         --  The browser serializes its Origin from the URL used to open the
         --  page. Derive the one permitted origin from the already validated
         --  request authority so both localhost and 127.0.0.1 remain exact
         --  same-origin deployments rather than weakening this to Allow_Any.
         Expected_Origin : constant String :=
           "http://"
           & Ada.Characters.Handling.To_Lower
               (Request_Helpers.Authority (X));
      begin
         Complete (State);
         --  Reject at the application boundary first so policy refusal has a
         --  useful HTTP status and access-log value. Accept_WebSocket repeats
         --  the exact check as the protocol-layer defense in depth.
         if X.Request_Header_Count ("Origin") /= 1
           or else X.Request_Header ("Origin") /= Expected_Origin
         then
            X.Problem
              (403, "websocket-origin", "WebSocket origin is not allowed");
            return;
         end if;
         declare
            First  : Producer (Session'Unchecked_Access, 'a');
            Second : Producer (Session'Unchecked_Access, 'b');
         begin
            --  Origin validation precedes the lifecycle upgrade and callbacks.
            WS_Lifecycle.Run
              (X, Session,
               Origin_Policy => HTTP.Require_Exact_Origin,
               Allowed_Origin => Expected_Origin,
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
           (Capacity => 30, Slashes => Routing.Strict_Slashes);
         Budget      : aliased HTTP.Ingress_Budget
           (Limit => 64 * 1_024 * 1_024);
      end record;

      procedure Handle
        (State        : in out Context;
         Connection   : in out Owned.Connection;
         Peer         : Sockets.Endpoint;
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
      State.Routes.Add_Middleware
        (Error_Middleware.Call'Access, Name => "errors");
      State.Routes.Add_Middleware
        (Request_ID_Middleware.Call'Access, Name => "request-id");
      State.Routes.Add_Middleware
        (Logging_Middleware.Call'Access, Name => "access-log");
      State.Routes.Add_Middleware
        (Metrics_Middleware.Call'Access, Name => "metrics");
      State.Routes.Add_Middleware
        (CORS_Middleware.Call'Access, Name => "cors");
      State.Routes.Add_Middleware
        (Rate_Middleware.Call'Access, Name => "rate-limit");
      State.Routes.Add_Middleware
        (Bulkhead_Middleware.Call'Access, Name => "bulkhead");
      State.Routes.Add_Middleware
        (Security_Middleware.Call'Access, Stage => Routing.Application,
         Name => "security-headers");

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
        ("upload", Deadline_Middleware.Call'Access,
         Middleware_Name => "deadline-narrowing");
      State.Routes.Get
        ("/stream", Stream_Response'Access, Name => "stream");
      State.Routes.Get
        ("/metrics", Metrics_Endpoint'Access, Name => "metrics");
      State.Routes.Get
        ("/introspection", Introspection_Endpoint'Access,
         Name => "introspection");
      State.Routes.Get
        ("/runtime/events", Runtime_Events'Access, Name => "runtime.events",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Upgrade => Routing.Allow_SSE,
              Timeout => 110.0));
      State.Routes.Post
        ("/runtime/groups/{action}", Migration_Action_Endpoint'Access,
         Name => "runtime.groups.action",
         Policy =>
           (Routing.Default_Route_Policy with delta
              --  Serialize access to the fixed worker handles. The workers
              --  themselves migrate cooperatively on their own stacks.
              Concurrency => 1,
              Timeout     => 5.0));
      State.Routes.Get
        ("/request-log/events", Request_Log_Events'Access,
         Name => "request-log.events",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Upgrade     => Routing.Allow_SSE,
              Timeout     => 110.0,
              Concurrency => 8));
      State.Routes.Get
        ("/private", Private_Profile'Access, Name => "private",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Authentication => Routing.Required_Authentication,
              CORS_Policy     => 1,
              Rate_Per_Second => 10,
              Concurrency     => 8));
      State.Routes.Add_Route_Middleware
        ("private", Authentication_Middleware.Call'Access,
         Middleware_Name => "authentication");
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
      Admin_Routes.Add_Middleware
        (Security_Middleware.Call'Access, Name => "admin-security-headers");
      --  Mount keeps child policy and prefixes names so logs and metrics use
      --  bounded "admin.*" labels instead of arbitrary raw paths.
      State.Routes.Mount
        ("/admin", Admin_Routes, Name_Prefix => "admin.");

      --  Routes and middleware are immutable after setup. Cache one owned JSON
      --  description so introspection requests do not rebuild it per request.
      State.Application.Introspection :=
        Ada.Strings.Unbounded.To_Unbounded_String
          (Build_Routing_JSON (State.Routes));

      --  UUIDs seeds its default pseudorandom generator on first use. Do that
      --  once on the native environment task so initialization cannot occupy
      --  a cooperative event-loop pthread when the first request arrives.
      State.Application.Request_IDs.Initialize;

      Sockets.Create_Socket (Listener);
      Sockets.Set_Socket_Option
        (Listener, Sockets.Socket_Level, (Sockets.Reuse_Address, True));
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port));
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

      --  Access-task allocation gives these workers Run's task master. Stop
      --  every created worker before leaving so none can outlive showcase
      --  state or keep application shutdown waiting indefinitely.
      for Worker in Migration_Worker_Id loop
         if Migration_Workers (Worker) /= null then
            begin
               Migration_Workers (Worker).Stop;
            exception
               when Tasking_Error => null;
            end;
         end if;
      end loop;
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
