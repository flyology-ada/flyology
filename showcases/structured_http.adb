with Ada.Streams;
with Ada.Text_IO;
with Flyology;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with Flyology.IO.Structured_Servers;

procedure Structured_HTTP is
   package Connections renames Flyology.IO.Connections;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Text_IO;
   use type Ada.Streams.Stream_Element_Array;

   CRLF : constant String := Character'Val (13) & Character'Val (10);
   Request_Text : constant String := "GET / HTTP/1.0" & CRLF & CRLF;
   Response_Body : constant String :=
     "hello from a structured Flyology server" & CRLF;
   Response_Text : constant String :=
     "HTTP/1.0 200 OK" & CRLF
     & "Content-Type: text/plain" & CRLF
     & "Content-Length:" & Natural'Image (Response_Body'Length) & CRLF
     & "Connection: close" & CRLF & CRLF & Response_Body;

   Request_Count : constant Positive := 12;
   Handler_Capacity : constant Positive := 3;

   function Bytes (Text : String) return Ada.Streams.Stream_Element_Array is
      Result : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Text'Length));
   begin
      for Index in Text'Range loop
         Result (Ada.Streams.Stream_Element_Offset
                   (Index - Text'First + 1)) :=
           Ada.Streams.Stream_Element (Character'Pos (Text (Index)));
      end loop;
      return Result;
   end Bytes;

   generic
      Model : Flyology.Execution_Model;
      with function Lane_Name return String;
   procedure Run_Lane;

   procedure Run_Lane is
      protected type Progress is
         procedure Handler_Done;
         procedure Client_Done (Passed : Boolean);
         entry Await_Handlers;
         entry Await_Clients;
         function Clients_Passed return Boolean;
      private
         Handled : Natural := 0;
         Clients : Natural := 0;
         All_OK  : Boolean := True;
      end Progress;

      protected body Progress is
         procedure Handler_Done is
         begin
            Handled := Handled + 1;
         end Handler_Done;

         procedure Client_Done (Passed : Boolean) is
         begin
            Clients := Clients + 1;
            All_OK := All_OK and Passed;
         end Client_Done;

         entry Await_Handlers when Handled = Request_Count is
         begin
            null;
         end Await_Handlers;

         entry Await_Clients when Clients = Request_Count is
         begin
            null;
         end Await_Clients;

         function Clients_Passed return Boolean is (All_OK);
      end Progress;

      type Context is limited record
         State : Progress;
      end record;

      procedure Handle
        (State        : in out Context;
         Connection   : in out Connections.Connection;
         Peer         : Sockets.Endpoint;
         Cancellation : not null access Connections.Cancellation_Token)
      is
         Request : Ada.Streams.Stream_Element_Array := Bytes (Request_Text);
         pragma Unreferenced (Peer);
      begin
         Connection.Receive_Exactly
           (Request, Timeout => 2.0, Token => Cancellation);
         if Request /= Bytes (Request_Text) then
            raise Program_Error with "malformed showcase request";
         end if;
         Connection.Send_All
           (Bytes (Response_Text), Timeout => 2.0, Token => Cancellation);
         State.State.Handler_Done;
      end Handle;

      package HTTP_Server is new Flyology.IO.Structured_Servers
        (Handler_Context => Context,
         Handle          => Handle,
         Handler_Model   => Model);

      Server   : aliased HTTP_Server.Server (Capacity => Handler_Capacity);
      State    : aliased Context;
      Listener : Sockets.Socket_Type;
      Address  : Sockets.Endpoint;
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
      Sockets.Listen_Socket (Listener, Length => Request_Count);
      Address := Sockets.Get_Socket_Name (Listener);

      Put_Line
        (Lane_Name & ": " & Request_Count'Image
         & " requests, at most" & Handler_Capacity'Image
         & " accepted handlers");

      declare
         task Stopper is
            pragma Task_Info (Flyology.Native_Task);
         end Stopper;

         task type Client is
            pragma Task_Info (Flyology.Native_Task);
         end Client;

         task body Stopper is
         begin
            State.State.Await_Handlers;
            HTTP_Server.Request_Shutdown (Server);
         end Stopper;

         task body Client is
            Socket   : Sockets.Socket_Type;
            Response : Ada.Streams.Stream_Element_Array :=
              Bytes (Response_Text);
         begin
            Sockets.Create_Socket (Socket);
            Flyology.IO.Sockets.Connect (Socket, Address, Timeout => 2.0);
            Flyology.IO.Sockets.Send_All
              (Socket, Bytes (Request_Text), Timeout => 2.0);
            Flyology.IO.Sockets.Receive_Exactly
              (Socket, Response, Timeout => 2.0);
            State.State.Client_Done (Response = Bytes (Response_Text));
            Sockets.Close_Socket (Socket);
         exception
            when others =>
               if Sockets.Is_Open (Socket) then
                  Sockets.Close_Socket (Socket);
               end if;
               State.State.Client_Done (False);
         end Client;

         Clients : array (1 .. Request_Count) of Client;
         pragma Unreferenced (Clients);
      begin
         HTTP_Server.Serve
           (Server, Listener, State, Drain_Timeout => 1.0);
         State.State.Await_Clients;
      end;

      if not State.State.Clients_Passed then
         raise Program_Error with Lane_Name & " clients failed";
      end if;

      declare
         Sample : constant HTTP_Server.Snapshot := HTTP_Server.Current (Server);
      begin
         Put_Line
           (Lane_Name & ": accepted="
            & Sample.Accepted_Connections'Image
            & " completed=" & Sample.Completed_Connections'Image
            & " forced=" & Sample.Forced_Cancellation'Image);
      end;
   end Run_Lane;

   function Lightweight_Name return String is ("lightweight handlers");
   function Native_Name return String is ("native handlers");

   procedure Run_Lightweight is new Run_Lane
     (Flyology.Lightweight_Task, Lightweight_Name);
   procedure Run_Native is new Run_Lane
     (Flyology.Native_Task, Native_Name);
begin
   Put_Line
     ("Each Serve call owns its listener, handler task scope, admission bound,"
      & " and deterministic shutdown.");
   Run_Lightweight;
   Run_Native;
end Structured_HTTP;
