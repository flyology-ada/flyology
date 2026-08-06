with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.Bytes;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.IO;
with Flyology.IO.Connections.Testing;
with Flyology.IO.Sockets;

procedure HTTP_Client_Deadline_Matrix is
   package Client renames Flyology.HTTP.Client;
   package Connection_Testing renames Flyology.IO.Connections.Testing;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use type Sockets.Selector_Status;

   CRLF : constant String := Character'Val (13) & Character'Val (10);
   Boundary_Timeout : constant Duration := 0.15;
   Release_Delay    : constant Duration := 0.25;

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

   protected type Outcome is
      procedure Publish (Value : Sockets.Port);
      entry Wait_Ready (Value : out Sockets.Port);
      procedure Report (Passed : Boolean);
      entry Wait_Done;
      function Passed return Boolean;
   private
      Port_Value : Sockets.Port := Sockets.Any_Port;
      Ready      : Boolean := False;
      Count      : Natural := 0;
      OK         : Boolean := True;
   end Outcome;

   protected body Outcome is
      procedure Publish (Value : Sockets.Port) is
      begin
         Port_Value := Value;
         Ready := True;
      end Publish;

      entry Wait_Ready (Value : out Sockets.Port) when Ready is
      begin
         Value := Port_Value;
      end Wait_Ready;

      procedure Report (Passed : Boolean) is
      begin
         Count := Count + 1;
         OK := OK and Passed;
      end Report;

      entry Wait_Done when Count = 2 is
      begin
         null;
      end Wait_Done;

      function Passed return Boolean is (OK);
   end Outcome;

   generic
      Model : Flyology.Execution_Model;
   procedure Run_Lane;

   procedure Run_Lane is
      Result : Outcome;

      task Raw_Server is
         pragma Task_Info (Flyology.Native_Task);
      end Raw_Server;

      task body Raw_Server is
         Listener : Sockets.Socket_Type;
         Peer     : Sockets.Socket_Type;
         Address  : Sockets.Endpoint;
         Status   : Sockets.Selector_Status;

         procedure Accept_Peer is
         begin
            Sockets.Accept_Socket
              (Listener, Peer, Address, Timeout => 3.0, Status => Status);
            pragma Assert (Status = Sockets.Completed);
         end Accept_Peer;

         function Receive_Head return String is
            Buffer : Stream_Element_Array (1 .. 2_048);
            Last   : Stream_Element_Offset;
            Value  : Unbounded_String;
         begin
            loop
               Sockets.Receive (Peer, Buffer, Last, Timeout => 3.0);
               pragma Assert (Last >= Buffer'First);
               for Index in Buffer'First .. Last loop
                  Append (Value, Character'Val (Buffer (Index)));
               end loop;
               exit when Ada.Strings.Fixed.Index
                 (To_String (Value), CRLF & CRLF) /= 0;
            end loop;
            return To_String (Value);
         end Receive_Head;

         procedure Expect_Target (Target : String) is
            Head : constant String := Receive_Head;
         begin
            pragma Assert
              (Ada.Strings.Fixed.Index
                 (Head, "GET " & Target & " HTTP/1.1" & CRLF) = 1);
         end Expect_Target;

         procedure Expect_Close is
            Buffer : Stream_Element_Array (1 .. 256);
            Last   : Stream_Element_Offset;
         begin
            loop
               Sockets.Receive (Peer, Buffer, Last, Timeout => 3.0);
               exit when Last < Buffer'First;
            end loop;
            Sockets.Close_Socket (Peer);
         end Expect_Close;

         procedure Send (Value : String) is
         begin
            Sockets.Send_All (Peer, Bytes (Value), Timeout => 3.0);
         end Send;

         procedure Serve_Headless (Target : String) is
         begin
            Accept_Peer;
            Expect_Target (Target);
            Expect_Close;
         end Serve_Headless;

         procedure Serve_Incomplete
           (Target : String; Head_And_Prefix : String) is
         begin
            Accept_Peer;
            Expect_Target (Target);
            Send (Head_And_Prefix);
            Expect_Close;
         end Serve_Incomplete;

         procedure Serve_Partial_Send is
            Buffer : Stream_Element_Array (1 .. 1);
            Last   : Stream_Element_Offset;
         begin
            Accept_Peer;
            Sockets.Receive (Peer, Buffer, Last, Timeout => 3.0);
            pragma Assert (Last = Buffer'First);
            pragma Assert (Character'Val (Buffer (Buffer'First)) = 'G');
            Expect_Close;
         end Serve_Partial_Send;
      begin
         Sockets.Create_Socket (Listener);
         Sockets.Bind_Socket
           (Listener,
            Sockets.Network_Endpoint
              (Sockets.Loopback_IPv4, Sockets.Any_Port));
         Sockets.Listen_Socket (Listener);
         Result.Publish (Sockets.Get_Socket_Name (Listener).Port);

         Serve_Partial_Send;
         Serve_Partial_Send;
         Serve_Headless ("/head-timeout");
         Serve_Headless ("/head-cancel");
         Serve_Incomplete
           ("/fixed-timeout",
            "HTTP/1.1 200 OK" & CRLF &
            "Content-Length: 4" & CRLF & CRLF & "A");
         Serve_Incomplete
           ("/fixed-cancel",
            "HTTP/1.1 200 OK" & CRLF &
            "Content-Length: 4" & CRLF & CRLF & "A");
         Serve_Incomplete
           ("/chunk-timeout",
            "HTTP/1.1 200 OK" & CRLF &
            "Transfer-Encoding: chunked" & CRLF & CRLF &
            "4" & CRLF & "A");
         Serve_Incomplete
           ("/chunk-cancel",
            "HTTP/1.1 200 OK" & CRLF &
            "Transfer-Encoding: chunked" & CRLF & CRLF &
            "4" & CRLF & "A");
         Serve_Incomplete
           ("/close-timeout",
            "HTTP/1.1 200 OK" & CRLF &
            "Connection: close" & CRLF & CRLF & "A");
         Serve_Incomplete
           ("/close-cancel",
            "HTTP/1.1 200 OK" & CRLF &
            "Connection: close" & CRLF & CRLF & "A");

         Sockets.Close_Socket (Listener);
         Result.Report (True);
      exception
         when Occurrence : others =>
            Ada.Text_IO.Put_Line
              ("HTTP deadline server failed: " &
               Ada.Exceptions.Exception_Information (Occurrence));
            if Sockets.Is_Open (Peer) then
               Sockets.Close_Socket (Peer);
            end if;
            if Sockets.Is_Open (Listener) then
               Sockets.Close_Socket (Listener);
            end if;
            Result.Report (False);
      end Raw_Server;

      task Caller is
         pragma Task_Info (Model);
      end Caller;

      task body Caller is
         Port : Sockets.Port;

         procedure Expect_Interruption
           (Point  : Connection_Testing.Barrier_Point;
            Cancel : Boolean;
            Action : not null access procedure
              (Timeout : Duration;
               Token   : access Flyology.Cancellation.Token))
         is
            Token : aliased Flyology.Cancellation.Token;

            task Trigger is
               entry Start;
               entry Join;
            end Trigger;

            task body Trigger is
            begin
               accept Start;
               Connection_Testing.Wait_Reached (Point);
               if Cancel then
                  Token.Request;
               else
                  delay Release_Delay;
               end if;
               Connection_Testing.Release (Point);
               accept Join;
            end Trigger;

            Raised : Boolean := False;
         begin
            Connection_Testing.Reset_Barriers;
            Connection_Testing.Arm (Point);
            Trigger.Start;
            begin
               Action
                 ((if Cancel then -1.0 else Boundary_Timeout),
                  (if Cancel then Token'Access else null));
            exception
               when Flyology.IO.Timeout_Error =>
                  Raised := not Cancel;
               when Flyology.Cancellation.Operation_Cancelled =>
                  Raised := Cancel;
            end;
            Trigger.Join;
            Connection_Testing.Reset_Barriers;
            pragma Assert (Raised);
         exception
            when others =>
               Connection_Testing.Release (Point);
               Connection_Testing.Reset_Barriers;
               raise;
         end Expect_Interruption;

         procedure Assert_Drained
           (Item : Client.Client; Created : Natural) is
            State : constant Client.Client_Diagnostics :=
              Client.Diagnostics (Item);
         begin
            pragma Assert (State.Pending_Transports = 0);
            pragma Assert (State.Active_Exchanges = 0);
            pragma Assert (State.Reusable_Transports = 0);
            pragma Assert (State.Closing_Transports = 0);
            pragma Assert (State.Admission_Waiters = 0);
            pragma Assert (State.Transports_Created = Created);
            pragma Assert (State.Transports_Closed = Created);
         end Assert_Drained;
      begin
         Result.Wait_Ready (Port);
         declare
            DNS_Origin : constant Flyology.HTTP.Origin :=
              Flyology.HTTP.Parse_Origin
                ("http://deadline.invalid:" & Decimal (Natural (Port)));
            Origin : constant Flyology.HTTP.Origin :=
              Flyology.HTTP.Parse_Origin
                ("http://127.0.0.1:" & Decimal (Natural (Port)));
            DNS_Client : aliased Client.Client (Capacity => 1);
            HTTP       : aliased Client.Client (Capacity => 1);
            Request    : Client.Request;

            procedure Execute_DNS
              (Timeout : Duration;
               Token   : access Flyology.Cancellation.Token) is
            begin
               declare
                  Unexpected : Client.Response :=
                    Client.Execute
                      (DNS_Client, Request, Timeout => Timeout, Token => Token);
                  pragma Unreferenced (Unexpected);
               begin
                  null;
               end;
            end Execute_DNS;

            procedure Execute_HTTP
              (Timeout : Duration;
               Token   : access Flyology.Cancellation.Token) is
            begin
               declare
                  Unexpected : Client.Response :=
                    Client.Execute
                      (HTTP, Request, Timeout => Timeout, Token => Token);
                  pragma Unreferenced (Unexpected);
               begin
                  null;
               end;
            end Execute_HTTP;

            procedure Exercise_Body (Target : String; Cancel : Boolean) is
            begin
               Client.Set_Target (Request, Target);
               declare
                  Reply : Client.Response := Client.Execute
                    (HTTP, Request,
                     Timeout =>
                       (if Cancel then -1.0 else Boundary_Timeout));

                  procedure Read_Response
                    (Timeout : Duration;
                     Token   : access Flyology.Cancellation.Token)
                  is
                     pragma Unreferenced (Timeout);
                     Unexpected : constant Flyology.Bytes.Unbounded_Bytes :=
                       Client.Read_All (Reply, Token => Token);
                     pragma Unreferenced (Unexpected);
                  begin
                     null;
                  end Read_Response;
               begin
                  Expect_Interruption
                    (Connection_Testing.Active_Operation_Park,
                     Cancel, Read_Response'Access);
               end;
            end Exercise_Body;
         begin
            Client.Configure (DNS_Client, DNS_Origin);
            Client.Configure (HTTP, Origin);

            Client.Set_Target (Request, "/dns-timeout");
            Expect_Interruption
              (Connection_Testing.Before_HTTP_Client_DNS,
               False, Execute_DNS'Access);
            Client.Set_Target (Request, "/dns-cancel");
            Expect_Interruption
              (Connection_Testing.Before_HTTP_Client_DNS,
               True, Execute_DNS'Access);
            Client.Shutdown (DNS_Client);
            Assert_Drained (DNS_Client, Created => 0);

            Client.Set_Target (Request, "/connect-timeout");
            Expect_Interruption
              (Connection_Testing.Before_HTTP_Client_Connect,
               False, Execute_HTTP'Access);
            Client.Set_Target (Request, "/connect-cancel");
            Expect_Interruption
              (Connection_Testing.Before_HTTP_Client_Connect,
               True, Execute_HTTP'Access);

            Client.Set_Target (Request, "/send-timeout");
            Expect_Interruption
              (Connection_Testing.Send_Chunk_Boundary,
               False, Execute_HTTP'Access);
            Client.Set_Target (Request, "/send-cancel");
            Expect_Interruption
              (Connection_Testing.Send_Chunk_Boundary,
               True, Execute_HTTP'Access);

            Client.Set_Target (Request, "/head-timeout");
            Expect_Interruption
              (Connection_Testing.Active_Operation_Park,
               False, Execute_HTTP'Access);
            Client.Set_Target (Request, "/head-cancel");
            Expect_Interruption
              (Connection_Testing.Active_Operation_Park,
               True, Execute_HTTP'Access);

            Exercise_Body ("/fixed-timeout", False);
            Exercise_Body ("/fixed-cancel", True);
            Exercise_Body ("/chunk-timeout", False);
            Exercise_Body ("/chunk-cancel", True);
            Exercise_Body ("/close-timeout", False);
            Exercise_Body ("/close-cancel", True);

            Client.Shutdown (HTTP);
            Assert_Drained (HTTP, Created => 10);
         end;
         Result.Report (True);
      exception
         when Occurrence : others =>
            Connection_Testing.Reset_Barriers;
            Ada.Text_IO.Put_Line
              ("HTTP deadline caller failed: " &
               Ada.Exceptions.Exception_Information (Occurrence));
            Result.Report (False);
      end Caller;
   begin
      Result.Wait_Done;
      pragma Assert (Result.Passed);
   end Run_Lane;

   procedure Run_Native is new Run_Lane (Flyology.Native_Task);
   procedure Run_Lightweight is new Run_Lane (Flyology.Lightweight_Task);
begin
   Run_Native;
   Run_Lightweight;
end HTTP_Client_Deadline_Matrix;
