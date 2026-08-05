with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.Bytes;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Headers;
with Flyology.HTTP.Methods;
with Flyology.IO;
with Flyology.IO.Sockets;

procedure HTTP_Client_Smoke is
   package Client renames Flyology.HTTP.Client;
   package Headers renames Flyology.HTTP.Headers;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use type Flyology.HTTP.Method;
   use type Flyology.HTTP.Origin_Scheme;
   use type Flyology.HTTP.Port_Number;
   use type Flyology.HTTP.Protocol;
   use type Sockets.Port;
   use type Sockets.Selector_Status;

   CRLF : constant String := Character'Val (13) & Character'Val (10);

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

   procedure Exercise_Client (Port : Sockets.Port) is
      Origin : constant Flyology.HTTP.Origin := Flyology.HTTP.Parse_Origin
        ("http://127.0.0.1:" & Decimal (Natural (Port)));
      Item   : aliased Client.Client (Capacity => 1);
      Value  : Client.Request;
   begin
      Client.Configure
        (Item, Origin,
         (Max_Idle                    => 1,
          Idle_Timeout                => 10.0,
          Max_Connection_Age          => 60.0,
          Max_Requests_Per_Connection => 0));

      Client.Set_Method (Value, Flyology.HTTP.Methods.CONNECT);
      declare
         Rejected : Boolean := False;
      begin
         begin
            declare
               Unexpected : Client.Response := Client.Execute (Item, Value);
               pragma Unreferenced (Unexpected);
            begin
               null;
            end;
         exception
            when Constraint_Error =>
               Rejected := True;
         end;
         pragma Assert (Rejected);
      end;
      Client.Set_Method (Value, Flyology.HTTP.Methods.GET);

      Client.Set_Target (Value, "/fixed");
      Client.Add_Header (Value, "X-Order", "first");
      Client.Add_Header (Value, "X-Order", "second");
      declare
         Response : Client.Response := Client.Execute (Item, Value);
         Timed_Out : Boolean := False;
      begin
         pragma Assert (Client.Status (Response) = 200);
         pragma Assert
           (Client.Negotiated_Protocol (Response) =
              Flyology.HTTP.HTTP_1_1_Protocol);
         pragma Assert (Client.Header_Count (Response, "x-repeat") = 2);
         pragma Assert (Client.Header (Response, "X-Repeat", 2) = "second");
         begin
            declare
               Unexpected : Client.Response :=
                 Client.Execute (Item, Value, Timeout => 0.02);
               pragma Unreferenced (Unexpected);
            begin
               null;
            end;
         exception
            when Flyology.IO.Timeout_Error =>
               Timed_Out := True;
         end;
         pragma Assert (Timed_Out);
         pragma Assert
           (Flyology.Bytes.To_Byte_String (Client.Read_All (Response)) =
              "hello");
      end;

      Client.Set_Target (Value, "/chunked");
      declare
         Response : Client.Response := Client.Execute (Item, Value);
      begin
         pragma Assert
           (Flyology.Bytes.To_Byte_String (Client.Read_All (Response)) =
              "Wikipedia");
         pragma Assert (Client.Trailer (Response, "x-trailer") = "done");
      end;

      Client.Set_Target (Value, "/abandon");
      declare
         Response : constant Client.Response := Client.Execute (Item, Value);
      begin
         pragma Assert (not Client.Body_Complete (Response));
      end;

      Client.Set_Target (Value, "/new-connection");
      declare
         Response : Client.Response := Client.Execute (Item, Value);
      begin
         pragma Assert
           (Flyology.Bytes.To_Byte_String (Client.Read_All (Response)) = "ok");
      end;

      declare
         State : constant Client.Client_Diagnostics :=
           Client.Diagnostics (Item);
      begin
         pragma Assert (State.Transports_Created = 2);
         pragma Assert (State.Transport_Reuses = 2);
         pragma Assert (State.Admission_Timeouts = 1);
         pragma Assert
           (State.Active_Exchanges = 0
              and then State.Reusable_Transports = 0);
      end;
      Client.Shutdown (Item);
   end Exercise_Client;

   procedure Exercise_Invalid_Responses (Port : Sockets.Port) is
      Origin : constant Flyology.HTTP.Origin := Flyology.HTTP.Parse_Origin
        ("http://127.0.0.1:" & Decimal (Natural (Port)));
      Item  : aliased Client.Client (Capacity => 1);
      Value : Client.Request;

      procedure Expect_Head_Error (Target : String) is
         Raised : Boolean := False;
      begin
         Client.Set_Target (Value, Target);
         begin
            declare
               Unexpected : Client.Response := Client.Execute (Item, Value);
               pragma Unreferenced (Unexpected);
            begin
               null;
            end;
         exception
            when Flyology.HTTP.Protocol_Error =>
               Raised := True;
         end;
         pragma Assert (Raised);
      end Expect_Head_Error;

      procedure Expect_Body_Error (Target : String) is
         Raised : Boolean := False;
      begin
         Client.Set_Target (Value, Target);
         declare
            Response : Client.Response := Client.Execute (Item, Value);
         begin
            begin
               declare
                  Payload : constant Flyology.Bytes.Unbounded_Bytes :=
                    Client.Read_All (Response);
                  pragma Unreferenced (Payload);
               begin
                  null;
               end;
            exception
               when Flyology.HTTP.Protocol_Error =>
                  Raised := True;
            end;
         end;
         pragma Assert (Raised);
      end Expect_Body_Error;
   begin
      Client.Configure (Item, Origin);
      Client.Set_Target (Value, "/informational");
      declare
         Response : constant Client.Response := Client.Execute (Item, Value);
      begin
         pragma Assert (Client.Status (Response) = 204);
         pragma Assert (Client.Body_Complete (Response));
      end;
      Expect_Head_Error ("/conflicting-length");
      Expect_Head_Error ("/te-and-length");
      Expect_Head_Error ("/folded-field");
      Expect_Head_Error ("/bad-status");
      Expect_Body_Error ("/short-body");
      Expect_Body_Error ("/bad-chunk");
      Client.Shutdown (Item);
   end Exercise_Invalid_Responses;

   protected Coordination is
      procedure Publish (Value : Sockets.Port);
      procedure Finish (Passed : Boolean);
      entry Wait_Ready (Value : out Sockets.Port; Passed : out Boolean);
      entry Wait_Done (Passed : out Boolean);
   private
      Port_Value : Sockets.Port := Sockets.Any_Port;
      Ready      : Boolean := False;
      Done       : Boolean := False;
      OK         : Boolean := True;
   end Coordination;

   protected body Coordination is
      procedure Publish (Value : Sockets.Port) is
      begin
         Port_Value := Value;
         Ready := True;
      end Publish;

      procedure Finish (Passed : Boolean) is
      begin
         OK := OK and Passed;
         Done := True;
      end Finish;

      entry Wait_Ready
        (Value : out Sockets.Port; Passed : out Boolean)
        when Ready or Done
      is
      begin
         Value := Port_Value;
         Passed := OK;
      end Wait_Ready;

      entry Wait_Done (Passed : out Boolean) when Done is
      begin
         Passed := OK;
      end Wait_Done;
   end Coordination;

   task Raw_Server is
      pragma Task_Info (Flyology.Native_Task);
   end Raw_Server;

   task body Raw_Server is
      Listener : Sockets.Socket_Type;
      Peer     : Sockets.Socket_Type;
      Address  : Sockets.Endpoint;
      Status   : Sockets.Selector_Status;

      function Receive_Head return String is
         Buffer : Stream_Element_Array (1 .. 2_048);
         Last   : Stream_Element_Offset;
         Result : Unbounded_String;
      begin
         loop
            Sockets.Receive (Peer, Buffer, Last, Timeout => 2.0);
            pragma Assert (Last >= Buffer'First);
            for Index in Buffer'First .. Last loop
               Append (Result, Character'Val (Buffer (Index)));
            end loop;
            exit when Ada.Strings.Fixed.Index
              (To_String (Result), CRLF & CRLF) /= 0;
         end loop;
         return To_String (Result);
      end Receive_Head;

      procedure Send (Value : String) is
      begin
         Sockets.Send_All (Peer, Bytes (Value), Timeout => 2.0);
      end Send;

      procedure Accept_Peer is
      begin
         Sockets.Accept_Socket
           (Listener, Peer, Address, Timeout => 2.0, Status => Status);
         pragma Assert (Status = Sockets.Completed);
      end Accept_Peer;

      procedure Expect_Target (Value : String) is
         Head : constant String := Receive_Head;
      begin
         pragma Assert
           (Ada.Strings.Fixed.Index (Head, " " & Value & " HTTP/1.1") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index (Head, "Host: 127.0.0.1:") /= 0);
         if Value = "/fixed" then
            pragma Assert
              (Ada.Strings.Fixed.Index (Head, "X-Order: first" & CRLF) /= 0
               and then
                 Ada.Strings.Fixed.Index (Head, "X-Order: first" & CRLF) <
                   Ada.Strings.Fixed.Index
                     (Head, "X-Order: second" & CRLF));
         end if;
      end Expect_Target;
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint
           (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener);
      Coordination.Publish (Sockets.Get_Socket_Name (Listener).Port);

      Accept_Peer;
      Expect_Target ("/fixed");
      Send
        ("HTTP/1.1 200 OK" & CRLF &
         "Content-Length: 5" & CRLF &
         "X-Repeat: first" & CRLF &
         "X-Repeat: second" & CRLF & CRLF & "hello");

      Expect_Target ("/chunked");
      Send
        ("HTTP/1.1 103 Early Hints" & CRLF &
         "Link: </style.css>; rel=preload" & CRLF & CRLF &
         "HTTP/1.1 200 OK" & CRLF &
         "Transfer-Encoding: chunked" & CRLF & CRLF &
         "4" & CRLF & "Wiki" & CRLF &
         "5;note=yes" & CRLF & "pedia" & CRLF &
         "0" & CRLF & "X-Trailer: done" & CRLF & CRLF);

      Expect_Target ("/abandon");
      Send
        ("HTTP/1.1 200 OK" & CRLF &
         "Content-Length: 4" & CRLF & CRLF & "drop");
      declare
         Buffer : Stream_Element_Array (1 .. 1);
         Last   : Stream_Element_Offset;
      begin
         Sockets.Receive (Peer, Buffer, Last, Timeout => 2.0);
         pragma Assert (Last < Buffer'First);
      end;
      Sockets.Close_Socket (Peer);

      Accept_Peer;
      Expect_Target ("/new-connection");
      Send
        ("HTTP/1.0 200 OK" & CRLF & CRLF & "ok");
      Sockets.Close_Socket (Peer);

      Accept_Peer;
      Expect_Target ("/fixed");
      Send
        ("HTTP/1.1 200 OK" & CRLF &
         "Content-Length: 5" & CRLF &
         "X-Repeat: first" & CRLF &
         "X-Repeat: second" & CRLF & CRLF & "hello");
      Expect_Target ("/chunked");
      Send
        ("HTTP/1.1 103 Early Hints" & CRLF &
         "Link: </style.css>; rel=preload" & CRLF & CRLF &
         "HTTP/1.1 200 OK" & CRLF &
         "Transfer-Encoding: chunked" & CRLF & CRLF &
         "4" & CRLF & "Wiki" & CRLF &
         "5;note=yes" & CRLF & "pedia" & CRLF &
         "0" & CRLF & "X-Trailer: done" & CRLF & CRLF);
      Expect_Target ("/abandon");
      Send
        ("HTTP/1.1 200 OK" & CRLF &
         "Content-Length: 4" & CRLF & CRLF & "drop");
      declare
         Buffer : Stream_Element_Array (1 .. 1);
         Last   : Stream_Element_Offset;
      begin
         Sockets.Receive (Peer, Buffer, Last, Timeout => 2.0);
         pragma Assert (Last < Buffer'First);
      end;
      Sockets.Close_Socket (Peer);
      Accept_Peer;
      Expect_Target ("/new-connection");
      Send
        ("HTTP/1.0 200 OK" & CRLF & CRLF & "ok");
      Sockets.Close_Socket (Peer);

      Accept_Peer;
      Expect_Target ("/informational");
      Send
        ("HTTP/1.1 103 Early Hints" & CRLF &
         "Link: </style.css>; rel=preload" & CRLF & CRLF &
         "HTTP/1.1 204 No Content" & CRLF &
         "Connection: close" & CRLF & CRLF);
      Sockets.Close_Socket (Peer);

      Accept_Peer;
      Expect_Target ("/conflicting-length");
      Send
        ("HTTP/1.1 200 OK" & CRLF &
         "Content-Length: 1, 2" & CRLF & CRLF & "x");
      Sockets.Close_Socket (Peer);

      Accept_Peer;
      Expect_Target ("/te-and-length");
      Send
        ("HTTP/1.1 200 OK" & CRLF &
         "Transfer-Encoding: chunked" & CRLF &
         "Content-Length: 1" & CRLF & CRLF &
         "0" & CRLF & CRLF);
      Sockets.Close_Socket (Peer);

      Accept_Peer;
      Expect_Target ("/folded-field");
      Send
        ("HTTP/1.1 200 OK" & CRLF &
         "X-Test: first" & CRLF &
         " continuation" & CRLF &
         "Content-Length: 0" & CRLF & CRLF);
      Sockets.Close_Socket (Peer);

      Accept_Peer;
      Expect_Target ("/bad-status");
      Send
        ("HTTP/1.1 999 Invalid" & CRLF &
         "Content-Length: 0" & CRLF & CRLF);
      Sockets.Close_Socket (Peer);

      Accept_Peer;
      Expect_Target ("/short-body");
      Send
        ("HTTP/1.1 200 OK" & CRLF &
         "Content-Length: 4" & CRLF & CRLF & "x");
      Sockets.Close_Socket (Peer);

      Accept_Peer;
      Expect_Target ("/bad-chunk");
      Send
        ("HTTP/1.1 200 OK" & CRLF &
         "Transfer-Encoding: chunked" & CRLF & CRLF &
         "Z" & CRLF);
      Sockets.Close_Socket (Peer);
      Sockets.Close_Socket (Listener);
      Coordination.Finish (True);
   exception
      when Occurrence : others =>
         Ada.Text_IO.Put_Line
           ("raw HTTP server failed: " &
            Ada.Exceptions.Exception_Information (Occurrence));
         if Sockets.Is_Open (Peer) then
            Sockets.Close_Socket (Peer);
         end if;
         if Sockets.Is_Open (Listener) then
            Sockets.Close_Socket (Listener);
         end if;
         Coordination.Finish (False);
   end Raw_Server;

   Port      : Sockets.Port;
   Server_OK : Boolean;
begin
   pragma Assert (Flyology.HTTP.Methods.GET = Flyology.HTTP.To_Method ("GET"));
   pragma Assert (Flyology.HTTP.Is_Safe (Flyology.HTTP.Methods.GET));
   pragma Assert (Flyology.HTTP.Is_Idempotent (Flyology.HTTP.Methods.PUT));
   pragma Assert (not Flyology.HTTP.Is_Idempotent (Flyology.HTTP.Methods.POST));
   pragma Assert
     (Flyology.HTTP.Image (Flyology.HTTP.HTTP_1_1_Protocol) = "HTTP/1.1");

   declare
      Origin : constant Flyology.HTTP.Origin :=
        Flyology.HTTP.Parse_Origin ("HTTPS://Example.COM/");
      Extension : constant Flyology.HTTP.Method :=
        Flyology.HTTP.To_Method ("PURGE");
      Options : Client.Request;
      Rejected : Boolean := False;
   begin
      pragma Assert
        (Flyology.HTTP.Scheme (Origin) = Flyology.HTTP.Secure_HTTPS);
      pragma Assert (Flyology.HTTP.Host (Origin) = "example.com");
      pragma Assert (Flyology.HTTP.Port (Origin) = 443);
      pragma Assert (Flyology.HTTP.Image (Origin) = "https://example.com");
      pragma Assert (Flyology.HTTP.Image (Extension) = "PURGE");
      pragma Assert (not Flyology.HTTP.Is_Idempotent (Extension));
      Client.Set_Target (Options, "*");
      Client.Set_Method (Options, Flyology.HTTP.Methods.OPTIONS);
      begin
         Client.Add_Header (Options, "Connection", "close");
      exception
         when Constraint_Error =>
            Rejected := True;
      end;
      pragma Assert (Rejected);
   end;

   declare
      Fields : Headers.List;
   begin
      Headers.Add (Fields, "Example", "one");
      Headers.Add (Fields, "example", "two");
      pragma Assert (Headers.Count (Fields, "EXAMPLE") = 2);
      pragma Assert (Headers.Value (Fields, "example", 2) = "two");
   end;

   Coordination.Wait_Ready (Port, Server_OK);
   pragma Assert (Server_OK and then Port /= Sockets.Any_Port);
   Exercise_Client (Port);
   declare
      protected Lightweight_Result is
         procedure Finish (Passed : Boolean);
         entry Wait (Passed : out Boolean);
      private
         Done : Boolean := False;
         OK   : Boolean := False;
      end Lightweight_Result;

      protected body Lightweight_Result is
         procedure Finish (Passed : Boolean) is
         begin
            OK := Passed;
            Done := True;
         end Finish;

         entry Wait (Passed : out Boolean) when Done is
         begin
            Passed := OK;
         end Wait;
      end Lightweight_Result;

      task Lightweight_Caller is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Lightweight_Caller;

      task body Lightweight_Caller is
      begin
         Exercise_Client (Port);
         Lightweight_Result.Finish (True);
      exception
         when Occurrence : others =>
            Ada.Text_IO.Put_Line
              ("lightweight HTTP client failed: " &
               Ada.Exceptions.Exception_Information (Occurrence));
            Lightweight_Result.Finish (False);
      end Lightweight_Caller;

      pragma Unreferenced (Lightweight_Caller);
      Passed : Boolean;
   begin
      select
         Lightweight_Result.Wait (Passed);
      or
         delay 10.0;
         raise Program_Error with "lightweight HTTP client did not finish";
      end select;
      pragma Assert (Passed);
   end;

   Exercise_Invalid_Responses (Port);
   Coordination.Wait_Done (Server_OK);
   pragma Assert (Server_OK);
end HTTP_Client_Smoke;
