with Ada.Command_Line;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Connections;
with Flyology.HTTP.Server.Native_Routes;
with Flyology.HTTP.Server.Routing;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with Flyology.IO.Structured_Servers;
with Flyology.Native_Executors;
with HTTP_CPU_Work;
with Interfaces;

--  Routed CPU benchmark fixture. Networking, routing, and response I/O remain
--  on the configured request lane. Only /cpu-native crosses the typed bounded
--  executor boundary.
procedure HTTP_Hybrid_Benchmark_Server is
   package HTTP renames Flyology.HTTP.Server;
   package App renames Flyology.HTTP.Server.Applications;
   package Owned renames Flyology.IO.Connections;
   package Sockets renames Flyology.IO.Sockets;

   Variant : constant String :=
     (if Ada.Command_Line.Argument_Count >= 1
      then Ada.Command_Line.Argument (1) else "lightweight");
   Port : constant Sockets.Port :=
     (if Ada.Command_Line.Argument_Count >= 2
      then Sockets.Port'Value (Ada.Command_Line.Argument (2)) else 18_100);
   Handler_Capacity : constant Positive :=
     (if Ada.Command_Line.Argument_Count >= 3
      then Positive'Value (Ada.Command_Line.Argument (3)) else 256);
   Worker_Count : constant Positive :=
     (if Ada.Command_Line.Argument_Count >= 4
      then Positive'Value (Ada.Command_Line.Argument (4)) else 4);
   Queue_Capacity : constant Natural :=
     (if Ada.Command_Line.Argument_Count >= 5
      then Natural'Value (Ada.Command_Line.Argument (5)) else 64);
   Iterations : constant Natural :=
     (if Ada.Command_Line.Argument_Count >= 6
      then Natural'Value (Ada.Command_Line.Argument (6)) else 100_000);
   Outstanding_Capacity : constant Positive :=
     Worker_Count + Queue_Capacity;

   generic
      Model : Flyology.Execution_Model;
   procedure Run;

   procedure Run is
      type Application_Context is record
         Input : HTTP_CPU_Work.Work_Input :=
           (Iterations => Iterations, Seed => <>);
      end record;

      package Routing is new HTTP.Routing (Application_Context);
      package Native_Work is new Flyology.Native_Executors
        (HTTP_CPU_Work.Work_Input,
         HTTP_CPU_Work.Work_Result,
         HTTP_CPU_Work.Execute);
      Pool : aliased Native_Work.Executor
        (Workers => Worker_Count, Capacity => Outstanding_Capacity);

      procedure Prepare
        (State : in out Application_Context;
         X     : in out App.Exchange;
         Input : out HTTP_CPU_Work.Work_Input)
      is
         pragma Unreferenced (X);
      begin
         Input := State.Input;
      end Prepare;

      procedure Render
        (State  : in out Application_Context;
         X      : in out App.Exchange;
         Result : HTTP_CPU_Work.Work_Result)
      is
         pragma Unreferenced (State);
      begin
         X.Text (200, HTTP_CPU_Work.Image (Result));
      end Render;

      package Native_Route is new HTTP.Native_Routes
        (App_Context => Application_Context,
         Input_Type  => HTTP_CPU_Work.Work_Input,
         Result_Type => HTTP_CPU_Work.Work_Result,
         Operations  => Native_Work,
         Executor    => Pool'Access,
         Prepare     => Prepare,
         Render      => Render);

      procedure IO_Control
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         pragma Unreferenced (State);
      begin
         X.Text (200, "control");
      end IO_Control;

      procedure CPU_Inline
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         Result : HTTP_CPU_Work.Work_Result;
      begin
         HTTP_CPU_Work.Execute
           (State.Input, X.Cancellation, X.Deadline, Result);
         X.Text (200, HTTP_CPU_Work.Image (Result));
      end CPU_Inline;

      procedure Executor_Stats
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         pragma Unreferenced (State);
         Sample : constant Native_Work.Executor_Statistics :=
           Native_Work.Statistics (Pool);
      begin
         X.Respond
           (200, "application/json",
            "{""accepted"":" & Interfaces.Unsigned_64'Image
              (Sample.Accepted_Submissions)
            & ",""rejected"":" & Interfaces.Unsigned_64'Image
              (Sample.Rejected_Submissions)
            & ",""successful"":" & Interfaces.Unsigned_64'Image
              (Sample.Successful_Executions)
            & ",""failed"":" & Interfaces.Unsigned_64'Image
              (Sample.Failed_Executions)
            & ",""abandoned"":" & Interfaces.Unsigned_64'Image
              (Sample.Abandoned_Operations)
            & ",""outstanding"":" & Natural'Image
              (Sample.Outstanding_Operations)
            & ",""peak"":" & Natural'Image (Sample.Peak_Outstanding)
            & "}");
      end Executor_Stats;

      type Context is limited record
         Application : Application_Context;
         Routes      : Routing.Router
           (Capacity => 4, Slashes => Routing.Strict_Slashes);
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
            Timeout => 30.0, Token => Cancellation);
      end Handle;

      package Server_Instance is new Flyology.IO.Structured_Servers
        (Handler_Context => Context,
         Handle          => Handle,
         Handler_Model   => Model);

      Server   : aliased Server_Instance.Server
        (Capacity => Handler_Capacity);
      State    : aliased Context;
      Listener : Sockets.Socket_Type;
   begin
      State.Routes.Get
        ("/io-control", IO_Control'Access, Name => "io-control");
      State.Routes.Get
        ("/cpu-inline", CPU_Inline'Access, Name => "cpu-inline");
      State.Routes.Get
        ("/executor-stats", Executor_Stats'Access, Name => "executor-stats");
      if Variant = "hybrid" then
         Native_Work.Start (Pool);
         State.Routes.Get
           ("/cpu-native", Native_Route.Handle'Access, Name => "cpu-native");
      end if;

      Sockets.Create_Socket (Listener);
      Sockets.Set_Socket_Option
        (Listener, Sockets.Socket_Level, (Sockets.Reuse_Address, True));
      Sockets.Bind_Socket
        (Listener, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port));
      Sockets.Listen_Socket (Listener, Length => Handler_Capacity);

      Ada.Text_IO.Put_Line
        ("READY hybrid-" & Variant & " http://127.0.0.1:"
         & Ada.Strings.Fixed.Trim
             (Sockets.Port'Image (Port), Ada.Strings.Both)
         & "/io-control workers="
         & Ada.Strings.Fixed.Trim
             (Positive'Image (Worker_Count), Ada.Strings.Both)
         & " queue="
         & Ada.Strings.Fixed.Trim
             (Natural'Image (Queue_Capacity), Ada.Strings.Both)
         & " iterations="
         & Ada.Strings.Fixed.Trim
             (Natural'Image (Iterations), Ada.Strings.Both));
      Ada.Text_IO.Flush;
      Server_Instance.Serve (Server, Listener, State);
      if Variant = "hybrid" then
         Native_Work.Shutdown (Pool);
      end if;
   end Run;

   procedure Run_Lightweight is new Run (Flyology.Lightweight_Task);
   procedure Run_Native is new Run (Flyology.Native_Task);
begin
   if Variant = "inline" or else Variant = "hybrid" then
      Run_Lightweight;
   elsif Variant = "fully-native" then
      Run_Native;
   else
      raise Constraint_Error with
        "variant must be inline, hybrid, or fully-native";
   end if;
end HTTP_Hybrid_Benchmark_Server;
