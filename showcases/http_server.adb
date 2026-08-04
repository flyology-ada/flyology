with Ada.Command_Line;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology;
with Flyology.Bytes;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Connection_Handlers;
with Flyology.HTTP.Server.Connections;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with Flyology.IO.Structured_Servers;

procedure HTTP_Server is
   use type Ada.Streams.Stream_Element_Offset;

   package HTTP_Engine renames Flyology.HTTP.Server;
   package Sockets renames Flyology.IO.Sockets;
   package Owned renames Flyology.IO.Connections;

   Lane : constant String :=
     (if Ada.Command_Line.Argument_Count >= 1
      then Ada.Command_Line.Argument (1) else "lightweight");
   Request_Goal : constant Natural :=
     (if Ada.Command_Line.Argument_Count >= 2
      then Natural'Value (Ada.Command_Line.Argument (2)) else 100_000);
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

      type Context is limited record
         Requests : Request_Counter (Request_Goal);
         Budget   : aliased HTTP_Engine.Ingress_Budget
           (Limit => 64 * 1_024 * 1_024);
      end record;

      procedure Handle
        (State        : in out Context;
         Connection   : in out Owned.Connection;
         Peer         : Sockets.Endpoint;
         Cancellation : not null access Owned.Cancellation_Token)
      is
         pragma Unreferenced (Peer);
         Channel : aliased HTTP_Engine.Connections.Connection_Transport
           (Connection'Unchecked_Access);
         Client : HTTP_Engine.Connection (Channel'Access);

         procedure Route
           (Item  : in out HTTP_Engine.Connection;
            Value : HTTP_Engine.Request)
         is
            Message : Flyology.Bytes.Unbounded_Bytes;
            Kind    : HTTP_Engine.WebSocket_Data_Kind;
            Closed  : Boolean;
         begin
            if HTTP_Engine.Target (Value) = "/" then
               HTTP_Engine.Respond
                 (Item, 200, "text/plain; charset=utf-8",
                  "flyology" & ASCII.LF,
                  Timeout => 5.0, Token => Cancellation);
            elsif HTTP_Engine.Target (Value) = "/events" then
               HTTP_Engine.Begin_SSE
                 (Item, Timeout => 5.0, Token => Cancellation);
               for Sequence in 1 .. 3 loop
                  HTTP_Engine.Send_Event
                    (Item,
                     "event " & Positive'Image (Sequence),
                     Event   => "tick",
                     Id      => Positive'Image (Sequence),
                     Timeout => 5.0,
                     Token   => Cancellation);
               end loop;
               HTTP_Engine.End_SSE
                 (Item, Timeout => 5.0, Token => Cancellation);
            elsif HTTP_Engine.Target (Value) = "/upload"
              and then HTTP_Engine.Method (Value) = "POST"
            then
               declare
                  Buffer   : Ada.Streams.Stream_Element_Array (1 .. 16 * 1_024);
                  Last     : Ada.Streams.Stream_Element_Offset;
                  Finished : Boolean;
                  Total    : Natural := 0;
               begin
                  HTTP_Engine.Accept_Body (Item, Cancellation);
                  loop
                     HTTP_Engine.Read_Body
                       (Item, Buffer, Last, Finished, Cancellation);
                     if Last >= Buffer'First then
                        Total := Total
                          + Natural (Last - Buffer'First + 1);
                     end if;
                     exit when Finished;
                  end loop;
                  HTTP_Engine.Respond
                    (Item, 200, "text/plain; charset=utf-8",
                     "received" & Natural'Image (Total) & " bytes"
                     & ASCII.LF,
                     Timeout => 5.0, Token => Cancellation);
               end;
            elsif HTTP_Engine.Target (Value) = "/websocket" then
               HTTP_Engine.Accept_WebSocket
                 (Item, Value, Timeout => 5.0, Token => Cancellation);
               HTTP_Engine.Receive_WebSocket
                 (Item, Kind, Message, Closed,
                  Timeout => 30.0, Token => Cancellation);
               if not Closed then
                  HTTP_Engine.Send_WebSocket
                    (Item, Kind, Flyology.Bytes.To_Array (Message),
                     Timeout => 5.0, Token => Cancellation);
                  HTTP_Engine.Close_WebSocket
                    (Item, Timeout => 5.0, Token => Cancellation);
               end if;
            else
               HTTP_Engine.Respond
                 (Item, 404, "text/plain; charset=utf-8",
                  "not found" & ASCII.LF,
                  Timeout => 5.0, Token => Cancellation);
            end if;
            if Request_Goal > 0 then
               State.Requests.Completed;
            end if;
         end Route;

         package Handler is new
           Flyology.HTTP.Server.Connection_Handlers (Route);
      begin
         HTTP_Engine.Configure_Ingress_Budget
           (Client, State.Budget'Access);
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
        (Listener,
         Sockets.Socket_Level,
         (Sockets.Reuse_Address, True));
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port));
      Sockets.Listen_Socket (Listener, Length => Capacity);

      Ada.Text_IO.Put_Line
        ("READY " & Lane & " http://127.0.0.1:"
         & Ada.Strings.Fixed.Trim
             (Sockets.Port'Image (Port), Ada.Strings.Both) & "/");
      Ada.Text_IO.Flush;

      declare
         task Stopper is
            pragma Task_Info (Flyology.Native_Task);
         end Stopper;

         task body Stopper is
         begin
            State.Requests.Await_Goal;
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
end HTTP_Server;
