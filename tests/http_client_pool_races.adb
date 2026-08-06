with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology.Bytes;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.IO;
with Flyology.IO.Connections.Testing;
with Flyology.IO.Sockets;
with Interfaces.C;

procedure HTTP_Client_Pool_Races is
   package Client renames Flyology.HTTP.Client;
   package Connection_Testing renames Flyology.IO.Connections.Testing;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use type Ada.Real_Time.Time;
   use type Interfaces.C.int;
   use type Sockets.Selector_Status;

   CRLF : constant String := Character'Val (13) & Character'Val (10);

   function Open_FD_Count return Interfaces.C.int
     with Import, Convention => C,
          External_Name => "flyology_test_open_fd_count";

   function Bytes (Value : String) return Stream_Element_Array is
      Result : Stream_Element_Array
        (1 .. Stream_Element_Offset (Value'Length));
   begin
      for Offset in 0 .. Value'Length - 1 loop
         Result (Result'First + Stream_Element_Offset (Offset)) :=
           Stream_Element (Character'Pos (Value (Value'First + Offset)));
      end loop;
      return Result;
   end Bytes;

   function Decimal (Value : Natural) return String is
      Image : constant String := Natural'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Decimal;

   protected Coordination is
      procedure Publish
        (Value : Sockets.Port; Initial_FD_Count : Interfaces.C.int);
      entry Wait_Ready
        (Value : out Sockets.Port; Initial_FD_Count : out Interfaces.C.int);
      procedure Finish (Passed : Boolean);
      entry Wait_Done (Passed : out Boolean);
   private
      Port_Value : Sockets.Port := Sockets.Any_Port;
      Initial_FD_Count_Value : Interfaces.C.int := -1;
      Ready : Boolean := False;
      Done  : Boolean := False;
      OK    : Boolean := True;
   end Coordination;

   protected body Coordination is
      procedure Publish
        (Value : Sockets.Port; Initial_FD_Count : Interfaces.C.int) is
      begin
         Port_Value := Value;
         Initial_FD_Count_Value := Initial_FD_Count;
         Ready := True;
      end Publish;

      entry Wait_Ready
        (Value : out Sockets.Port; Initial_FD_Count : out Interfaces.C.int)
        when Ready
      is
      begin
         Value := Port_Value;
         Initial_FD_Count := Initial_FD_Count_Value;
      end Wait_Ready;

      procedure Finish (Passed : Boolean) is
      begin
         OK := OK and Passed;
         Done := True;
      end Finish;

      entry Wait_Done (Passed : out Boolean) when Done is
      begin
         Passed := OK;
      end Wait_Done;
   end Coordination;

   task Raw_Server;

   task body Raw_Server is
      Listener : Sockets.Socket_Type;
      Peer     : Sockets.Socket_Type;
      Address  : Sockets.Endpoint;
      Status   : Sockets.Selector_Status;
      Initial_FD_Count : constant Interfaces.C.int := Open_FD_Count;

      procedure Accept_Peer is
      begin
         Sockets.Accept_Socket
           (Listener, Peer, Address, Timeout => 3.0, Status => Status);
         pragma Assert (Status = Sockets.Completed);
      end Accept_Peer;

      function Receive_Head (Closed : out Boolean) return String is
         Buffer : Stream_Element_Array (1 .. 2_048);
         Last   : Stream_Element_Offset;
         Result : Unbounded_String;
      begin
         Closed := False;
         loop
            Sockets.Receive (Peer, Buffer, Last, Timeout => 3.0);
            if Last < Buffer'First then
               Closed := True;
               return To_String (Result);
            end if;
            for Index in Buffer'First .. Last loop
               Append (Result, Character'Val (Buffer (Index)));
            end loop;
            exit when Ada.Strings.Fixed.Index
              (To_String (Result), CRLF & CRLF) /= 0;
         end loop;
         return To_String (Result);
      end Receive_Head;

      procedure Expect (Target : String) is
         Closed : Boolean;
         Head   : constant String := Receive_Head (Closed);
      begin
         pragma Assert (not Closed);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Head, "GET " & Target & " HTTP/1.1" & CRLF) = 1);
      end Expect;

      procedure Send (Value : String) is
      begin
         Sockets.Send_All (Peer, Bytes (Value), Timeout => 3.0);
      end Send;

      procedure Expect_Close is
         Buffer : Stream_Element_Array (1 .. 1);
         Last   : Stream_Element_Offset;
      begin
         Sockets.Receive (Peer, Buffer, Last, Timeout => 3.0);
         pragma Assert (Last < Buffer'First);
         Sockets.Close_Socket (Peer);
      end Expect_Close;

      procedure Serve_Incomplete (Target : String) is
      begin
         Accept_Peer;
         Expect (Target);
         Send
           ("HTTP/1.1 200 OK" & CRLF &
            "Content-Length: 4" & CRLF & CRLF);
         Expect_Close;
      end Serve_Incomplete;
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint
           (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener);
      Coordination.Publish
        (Sockets.Get_Socket_Name (Listener).Port, Initial_FD_Count);

      Serve_Incomplete ("/return-vs-shutdown");
      Serve_Incomplete ("/abort-vs-shutdown");
      Serve_Incomplete ("/admission-holder");

      Accept_Peer;
      Expect ("/prune-prime");
      Send ("HTTP/1.1 204 No Content" & CRLF & CRLF);
      declare
         Closed : Boolean;
         Head   : constant String := Receive_Head (Closed);
      begin
         if Closed then
            Sockets.Close_Socket (Peer);
            Accept_Peer;
            Expect ("/prune-race");
         else
            pragma Assert
              (Ada.Strings.Fixed.Index
                 (Head, "GET /prune-race HTTP/1.1" & CRLF) = 1);
         end if;
      end;
      Send
        ("HTTP/1.1 204 No Content" & CRLF &
         "Connection: close" & CRLF & CRLF);
      Expect_Close;

      Sockets.Close_Socket (Listener);
      Coordination.Finish (True);
   exception
      when Occurrence : others =>
         Ada.Text_IO.Put_Line
           ("HTTP pool race server failed: " &
            Ada.Exceptions.Exception_Information (Occurrence));
         if Sockets.Is_Open (Peer) then
            Sockets.Close_Socket (Peer);
         end if;
         if Sockets.Is_Open (Listener) then
            Sockets.Close_Socket (Listener);
         end if;
         Coordination.Finish (False);
   end Raw_Server;

   procedure Assert_Drained
     (Item : Client.Client; Created : Positive; Reused : Natural := 0)
   is
      State : constant Client.Client_Diagnostics := Client.Diagnostics (Item);
   begin
      pragma Assert (State.Pending_Transports = 0);
      pragma Assert (State.Active_Exchanges = 0);
      pragma Assert (State.Reusable_Transports = 0);
      pragma Assert (State.Closing_Transports = 0);
      pragma Assert (State.Admission_Waiters = 0);
      pragma Assert (State.Transports_Created = Created);
      pragma Assert (State.Transport_Reuses = Reused);
      pragma Assert (State.Transports_Closed = Created);
   end Assert_Drained;

   procedure Run_Active_Race
     (Origin : Flyology.HTTP.Origin; Target : String; Abort_Reader : Boolean)
   is
      Item : aliased Client.Client (Capacity => 1);

      protected Progress is
         procedure Mark_Head_Ready;
         entry Wait_Head_Ready;
         procedure Start_Read;
         entry Wait_For_Read;
      private
         Head_Ready : Boolean := False;
         Read_Ready : Boolean := False;
      end Progress;

      protected body Progress is
         procedure Mark_Head_Ready is
         begin
            Head_Ready := True;
         end Mark_Head_Ready;

         entry Wait_Head_Ready when Head_Ready is
         begin
            null;
         end Wait_Head_Ready;

         procedure Start_Read is
         begin
            Read_Ready := True;
         end Start_Read;

         entry Wait_For_Read when Read_Ready is
         begin
            null;
         end Wait_For_Read;
      end Progress;

      task Reader is
         entry Start;
         entry Join (Passed : out Boolean);
      end Reader;

      task body Reader is
         OK      : Boolean := False;
         Request : Client.Request;
      begin
         accept Start;
         Client.Set_Target (Request, Target);
         declare
            Reply : Client.Response := Client.Execute (Item, Request);
         begin
            Progress.Mark_Head_Ready;
            Progress.Wait_For_Read;
            begin
               declare
                  Payload : constant Flyology.Bytes.Unbounded_Bytes :=
                    Client.Read_All (Reply);
                  pragma Unreferenced (Payload);
               begin
                  null;
               end;
            exception
               when Client.Client_Closed =>
                  OK := True;
            end;
         end;
         accept Join (Passed : out Boolean) do
            Passed := OK;
         end Join;
      exception
         when others =>
            accept Join (Passed : out Boolean) do
               Passed := False;
            end Join;
      end Reader;

      task Stopper is
         entry Start;
         entry Join (Passed : out Boolean);
      end Stopper;

      task body Stopper is
         OK : Boolean := False;
      begin
         accept Start;
         begin
            Client.Shutdown (Item, Timeout => 2.0);
            OK := True;
         exception
            when others =>
               null;
         end;
         accept Join (Passed : out Boolean) do
            Passed := OK;
         end Join;
      end Stopper;

      task Probe is
         entry Start;
         entry Join (Passed : out Boolean);
      end Probe;

      task body Probe is
         OK      : Boolean := False;
         Request : Client.Request;
      begin
         accept Start;
         Client.Set_Target (Request, "/closed-probe");
         begin
            declare
               Unexpected : Client.Response :=
                 Client.Execute (Item, Request, Timeout => 2.0);
               pragma Unreferenced (Unexpected);
            begin
               null;
            end;
         exception
            when Client.Client_Closed =>
               OK := True;
         end;
         accept Join (Passed : out Boolean) do
            Passed := OK;
         end Join;
      exception
         when others =>
            accept Join (Passed : out Boolean) do
               Passed := False;
            end Join;
      end Probe;

      Passed   : Boolean;
      Deadline : Ada.Real_Time.Time;
   begin
      Client.Configure (Item, Origin);
      Reader.Start;
      Progress.Wait_Head_Ready;
      Connection_Testing.Reset_Barriers;
      Connection_Testing.Arm (Connection_Testing.Active_Operation_Park);
      Progress.Start_Read;
      Connection_Testing.Wait_Reached
        (Connection_Testing.Active_Operation_Park);

      Stopper.Start;
      Probe.Start;
      Probe.Join (Passed);
      pragma Assert (Passed);

      if Abort_Reader then
         abort Reader;
         Deadline := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
         while not Reader'Terminated loop
            if Ada.Real_Time.Clock >= Deadline then
               raise Program_Error with
                 "aborted HTTP response reader did not terminate";
            end if;
            delay 0.001;
         end loop;
      else
         Connection_Testing.Release
           (Connection_Testing.Active_Operation_Park);
         Reader.Join (Passed);
         pragma Assert (Passed);
      end if;
      Connection_Testing.Release
        (Connection_Testing.Active_Operation_Park);
      Stopper.Join (Passed);
      pragma Assert (Passed);
      Connection_Testing.Reset_Barriers;
      Assert_Drained (Item, Created => 1);
   exception
      when others =>
         Connection_Testing.Release
           (Connection_Testing.Active_Operation_Park);
         Connection_Testing.Reset_Barriers;
         raise;
   end Run_Active_Race;

   procedure Run_Admission_Race (Origin : Flyology.HTTP.Origin) is
      Item : aliased Client.Client (Capacity => 1);

      protected Progress is
         procedure Mark_Holder_Ready;
         entry Wait_Holder_Ready;
      private
         Holder_Ready : Boolean := False;
      end Progress;

      protected body Progress is
         procedure Mark_Holder_Ready is
         begin
            Holder_Ready := True;
         end Mark_Holder_Ready;

         entry Wait_Holder_Ready when Holder_Ready is
         begin
            null;
         end Wait_Holder_Ready;
      end Progress;

      task Holder is
         entry Start;
         entry Release;
         entry Join (Passed : out Boolean);
      end Holder;

      task body Holder is
         OK      : Boolean := False;
         Request : Client.Request;
      begin
         accept Start;
         Client.Set_Target (Request, "/admission-holder");
         declare
            Reply : Client.Response := Client.Execute (Item, Request);
            pragma Unreferenced (Reply);
         begin
            Progress.Mark_Holder_Ready;
            accept Release;
         end;
         OK := True;
         accept Join (Passed : out Boolean) do
            Passed := OK;
         end Join;
      exception
         when others =>
            accept Join (Passed : out Boolean) do
               Passed := False;
            end Join;
      end Holder;

      task Waiter is
         entry Start;
         entry Join (Passed : out Boolean);
      end Waiter;

      task body Waiter is
         OK      : Boolean := False;
         Request : Client.Request;
      begin
         accept Start;
         Client.Set_Target (Request, "/admission-waiter");
         begin
            declare
               Unexpected : Client.Response :=
                 Client.Execute (Item, Request, Timeout => 3.0);
               pragma Unreferenced (Unexpected);
            begin
               null;
            end;
         exception
            when Client.Client_Closed =>
               OK := True;
         end;
         accept Join (Passed : out Boolean) do
            Passed := OK;
         end Join;
      exception
         when others =>
            accept Join (Passed : out Boolean) do
               Passed := False;
            end Join;
      end Waiter;

      task Stopper is
         entry Start;
         entry Join (Passed : out Boolean);
      end Stopper;

      task body Stopper is
         OK : Boolean := False;
      begin
         accept Start;
         begin
            Client.Shutdown (Item, Timeout => 2.0);
            OK := True;
         exception
            when others =>
               null;
         end;
         accept Join (Passed : out Boolean) do
            Passed := OK;
         end Join;
      end Stopper;

      Passed   : Boolean;
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
   begin
      Client.Configure (Item, Origin);
      Holder.Start;
      Progress.Wait_Holder_Ready;
      Waiter.Start;
      loop
         exit when Client.Diagnostics (Item).Admission_Waiters = 1;
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "HTTP pool waiter was not registered";
         end if;
         delay 0.001;
      end loop;
      Stopper.Start;
      Waiter.Join (Passed);
      pragma Assert (Passed);
      Holder.Release;
      Holder.Join (Passed);
      pragma Assert (Passed);
      Stopper.Join (Passed);
      pragma Assert (Passed);
      Assert_Drained (Item, Created => 1);
   end Run_Admission_Race;

   procedure Run_Prune_Race (Origin : Flyology.HTTP.Origin) is
      Item : aliased Client.Client (Capacity => 1);

      protected Gate is
         procedure Open;
         entry Wait;
      private
         Is_Open : Boolean := False;
      end Gate;

      protected body Gate is
         procedure Open is
         begin
            Is_Open := True;
         end Open;

         entry Wait when Is_Open is
         begin
            null;
         end Wait;
      end Gate;

      task Requester is
         entry Start;
         entry Join (Passed : out Boolean);
      end Requester;

      task body Requester is
         OK      : Boolean := False;
         Request : Client.Request;
      begin
         accept Start;
         Gate.Wait;
         Client.Set_Target (Request, "/prune-race");
         declare
            Reply : constant Client.Response := Client.Execute (Item, Request);
            pragma Unreferenced (Reply);
         begin
            OK := True;
         end;
         accept Join (Passed : out Boolean) do
            Passed := OK;
         end Join;
      exception
         when others =>
            accept Join (Passed : out Boolean) do
               Passed := False;
            end Join;
      end Requester;

      task Pruner is
         entry Start;
         entry Join (Passed : out Boolean);
      end Pruner;

      task body Pruner is
         OK : Boolean := False;
      begin
         accept Start;
         Gate.Wait;
         Client.Prune_Idle (Item);
         OK := True;
         accept Join (Passed : out Boolean) do
            Passed := OK;
         end Join;
      exception
         when others =>
            accept Join (Passed : out Boolean) do
               Passed := False;
            end Join;
      end Pruner;

      Request : Client.Request;
      Passed  : Boolean;
   begin
      Client.Configure (Item, Origin);
      Client.Set_Target (Request, "/prune-prime");
      declare
         Reply : constant Client.Response := Client.Execute (Item, Request);
         pragma Unreferenced (Reply);
      begin
         null;
      end;
      pragma Assert (Client.Diagnostics (Item).Reusable_Transports = 1);

      Requester.Start;
      Pruner.Start;
      Gate.Open;
      Requester.Join (Passed);
      pragma Assert (Passed);
      Pruner.Join (Passed);
      pragma Assert (Passed);
      Client.Shutdown (Item);
      declare
         State : constant Client.Client_Diagnostics :=
           Client.Diagnostics (Item);
      begin
         pragma Assert (State.Transports_Created in 1 .. 2);
         pragma Assert
           (State.Transports_Created + State.Transport_Reuses = 2);
         Assert_Drained
           (Item, State.Transports_Created, State.Transport_Reuses);
      end;
   end Run_Prune_Race;

   Port      : Sockets.Port;
   Baseline  : Interfaces.C.int;
   Server_OK : Boolean;
begin
   Coordination.Wait_Ready (Port, Baseline);
   declare
      Origin : constant Flyology.HTTP.Origin := Flyology.HTTP.Parse_Origin
        ("http://127.0.0.1:" & Decimal (Natural (Port)));
   begin
      Run_Active_Race (Origin, "/return-vs-shutdown", False);
      Run_Active_Race (Origin, "/abort-vs-shutdown", True);
      Run_Admission_Race (Origin);
      Run_Prune_Race (Origin);
   end;
   Coordination.Wait_Done (Server_OK);
   pragma Assert (Server_OK);
   pragma Assert (Open_FD_Count = Baseline);
end HTTP_Client_Pool_Races;
