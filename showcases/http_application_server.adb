with Ada.Command_Line;
with Ada.Streams;
with Ada.Text_IO;
with GNAT.Sockets;
with Flyology;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Connections;
with Flyology.HTTP.Server.Routing;
with Flyology.IO.Connections;
with Flyology.IO.Structured_Servers;

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
      begin
         Complete (State);
         X.Text (200, "flyology" & ASCII.LF);
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

      type Context is limited record
         Application : Application_Context;
         Routes      : Routing.Router
           (Capacity => 8, Slashes => Routing.Strict_Slashes);
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
      Listener : Sockets.Socket_Type;
   begin
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
