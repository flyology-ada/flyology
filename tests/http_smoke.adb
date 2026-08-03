with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Connection_Handlers;
with Flyology.IO;

procedure HTTP_Smoke is
   package HTTP_Server renames Flyology.HTTP.Server;

   use Ada.Strings.Unbounded;
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Flyology.HTTP.HTTP_Version;
   use type HTTP_Server.WebSocket_Data_Kind;

   CRLF : constant String := Character'Val (13) & Character'Val (10);

   type Memory_Transport is limited new HTTP_Server.Transport with record
      Input       : Unbounded_String;
      Output      : Unbounded_String;
      Slow        : Boolean := False;
      Slow_After  : Natural := Natural'Last;
      Receive_Calls : Natural := 0;
      First_Receive_Max : Natural := Natural'Last;
      Receive_Max : Natural := Natural'Last;
   end record;

   overriding procedure Receive
     (Item    : in out Memory_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);

   overriding procedure Send_All
     (Item    : in out Memory_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);

   overriding procedure Receive
     (Item    : in out Memory_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Token);
      Available : constant String := To_String (Item.Input);
      Count : Natural;
      Limit : Natural;
   begin
      Data := (others => 0);
      Last := Data'First - 1;
      Item.Receive_Calls := Item.Receive_Calls + 1;
      if Item.Slow or else Item.Receive_Calls > Item.Slow_After then
         if Timeout >= 0.0 and then Timeout < 0.005 then
            raise Flyology.IO.Timeout_Error;
         end if;
         delay 0.005;
      end if;
      if Available'Length = 0 then
         return;
      end if;
      Limit :=
        (if Item.Receive_Calls = 1
         then Item.First_Receive_Max else Item.Receive_Max);
      Count := Natural'Min
        (Natural (Data'Length),
         Natural'Min (Available'Length, Limit));
      for Index in 1 .. Count loop
         Data (Data'First + Ada.Streams.Stream_Element_Offset (Index - 1)) :=
           Ada.Streams.Stream_Element (Character'Pos (Available (Index)));
      end loop;
      Last := Data'First + Ada.Streams.Stream_Element_Offset (Count - 1);
      Item.Input :=
        (if Count = Available'Length then Null_Unbounded_String
         else To_Unbounded_String (Available (Count + 1 .. Available'Last)));
   end Receive;

   overriding procedure Send_All
     (Item    : in out Memory_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
   begin
      for Value of Data loop
         Append (Item.Output, Character'Val (Value));
      end loop;
   end Send_All;

   procedure Check_HTTP is
      Wire : aliased Memory_Transport;
   begin
      Wire.Input := To_Unbounded_String
        ("POST /echo HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF
         & "Content-Length: 5" & CRLF
         & "Connection: keep-alive" & CRLF & CRLF
         & "hello"
         & "HEAD /next HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF
         & "Connection: close" & CRLF & CRLF);
      declare
         Client : HTTP_Server.Connection (Wire'Access);
         Request : HTTP_Server.Request;
         Closed : Boolean;
      begin
         HTTP_Server.Read_Request (Client, Request, Closed);
         pragma Assert (not Closed);
         pragma Assert (HTTP_Server.Method (Request) = "POST");
         pragma Assert (HTTP_Server.Target (Request) = "/echo");
         pragma Assert (HTTP_Server.Content (Request) = "hello");
         pragma Assert
           (HTTP_Server.Version (Request) = Flyology.HTTP.HTTP_1_1);
         HTTP_Server.Respond
           (Client, 200, "text/plain", HTTP_Server.Content (Request));

         HTTP_Server.Read_Request (Client, Request, Closed);
         pragma Assert (HTTP_Server.Method (Request) = "HEAD");
         HTTP_Server.Respond (Client, 200, "text/plain", "hidden");
         pragma Assert (HTTP_Server.Should_Close (Client));
      end;
      declare
         Result : constant String := To_String (Wire.Output);
      begin
         pragma Assert
           (Ada.Strings.Fixed.Index (Result, "Content-Length: 5") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index (Result, "helloHTTP/1.1") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index (Result, "hidden") = 0);
      end;
   end Check_HTTP;

   procedure Check_Chunked_And_Expect is
      Wire : aliased Memory_Transport;
   begin
      Wire.Input := To_Unbounded_String
        ("POST /chunks HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF
         & "Transfer-Encoding: chunked" & CRLF
         & "Expect: 100-continue" & CRLF & CRLF
         & "4" & CRLF & "Wiki" & CRLF
         & "5;note=yes" & CRLF & "pedia" & CRLF
         & "0" & CRLF & "X-Trace: ok" & CRLF & CRLF
         & "GET /next HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF & "Connection: close" & CRLF & CRLF);
      declare
         Client  : HTTP_Server.Connection (Wire'Access);
         Request : HTTP_Server.Request;
         Closed  : Boolean;
      begin
         HTTP_Server.Read_Request (Client, Request, Closed);
         pragma Assert (HTTP_Server.Content (Request) = "Wikipedia");
         pragma Assert
           (Ada.Strings.Fixed.Index
              (To_String (Wire.Output), "100 Continue") /= 0);
         HTTP_Server.Respond (Client, 200, "text/plain", "ok");
         HTTP_Server.Read_Request (Client, Request, Closed);
         pragma Assert (HTTP_Server.Target (Request) = "/next");
      end;
   end Check_Chunked_And_Expect;

   procedure Check_Streaming_Body is
      Wire : aliased Memory_Transport;
      Data : Unbounded_String;
   begin
      Wire.Input := To_Unbounded_String
        ("POST /stream HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF
         & "Transfer-Encoding: chunked" & CRLF
         & "Expect: 100-continue" & CRLF & CRLF
         & "4" & CRLF & "Wiki" & CRLF
         & "5" & CRLF & "pedia" & CRLF
         & "0" & CRLF & "X-Trace: ok" & CRLF & CRLF
         & "GET /next HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF & "Connection: close" & CRLF & CRLF);
      declare
         Client   : HTTP_Server.Connection (Wire'Access);
         Request  : HTTP_Server.Request;
         Closed   : Boolean;
         Buffer   : Ada.Streams.Stream_Element_Array (1 .. 3);
         Last     : Ada.Streams.Stream_Element_Offset;
         Finished : Boolean;
      begin
         HTTP_Server.Read_Request_Head (Client, Request, Closed);
         pragma Assert (not Closed);
         pragma Assert (HTTP_Server.Content (Request) = "");
         pragma Assert (not HTTP_Server.Body_Complete (Client));
         pragma Assert
           (Ada.Strings.Fixed.Index
              (To_String (Wire.Output), "100 Continue") = 0);
         HTTP_Server.Accept_Body (Client);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (To_String (Wire.Output), "100 Continue") /= 0);
         loop
            HTTP_Server.Read_Body
              (Client, Buffer, Last, Finished);
            for Index in Buffer'First .. Last loop
               Append (Data, Character'Val (Buffer (Index)));
            end loop;
            exit when Finished;
         end loop;
         pragma Assert (To_String (Data) = "Wikipedia");
         pragma Assert (HTTP_Server.Body_Complete (Client));
         HTTP_Server.Respond (Client, 200, "text/plain", "ok");
         HTTP_Server.Read_Request_Head (Client, Request, Closed);
         pragma Assert (HTTP_Server.Target (Request) = "/next");
      end;

      Wire.Input := To_Unbounded_String
        ("POST /unread HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF
         & "Content-Length: 4" & CRLF & CRLF & "body");
      declare
         Client  : HTTP_Server.Connection (Wire'Access);
         Request : HTTP_Server.Request;
         Closed  : Boolean;
      begin
         HTTP_Server.Read_Request_Head (Client, Request, Closed);
         HTTP_Server.Respond (Client, 403, "text/plain", "rejected");
         pragma Assert (HTTP_Server.Should_Close (Client));
      end;

      Wire.Input := To_Unbounded_String
        ("POST /expired HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF
         & "Content-Length: 4" & CRLF & CRLF & "body");
      declare
         Client    : HTTP_Server.Connection (Wire'Access);
         Request   : HTTP_Server.Request;
         Closed    : Boolean;
         Buffer    : Ada.Streams.Stream_Element_Array (1 .. 4);
         Last      : Ada.Streams.Stream_Element_Offset;
         Finished  : Boolean;
         Timed_Out : Boolean := False;
      begin
         HTTP_Server.Read_Request_Head
           (Client, Request, Closed, Timeout => 0.01);
         delay 0.02;
         begin
            HTTP_Server.Read_Body (Client, Buffer, Last, Finished);
         exception
            when Flyology.IO.Timeout_Error =>
               Timed_Out := True;
         end;
         pragma Assert (Timed_Out);
      end;
   end Check_Streaming_Body;

   procedure Check_Ingress_Budget is
      Budget : aliased HTTP_Server.Ingress_Budget (Limit => 8);
      Wire_1 : aliased Memory_Transport;
      Wire_2 : aliased Memory_Transport;
   begin
      Wire_1.Input := To_Unbounded_String
        ("POST /one HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF
         & "Content-Length: 5" & CRLF & CRLF & "hello");
      Wire_2.Input := To_Unbounded_String
        ("POST /two HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF
         & "Content-Length: 5" & CRLF & CRLF & "world");
      declare
         Client_1  : HTTP_Server.Connection (Wire_1'Access);
         Request_1 : HTTP_Server.Request;
         Closed    : Boolean;
      begin
         HTTP_Server.Configure_Ingress_Budget (Client_1, Budget'Access);
         HTTP_Server.Read_Request (Client_1, Request_1, Closed);
         pragma Assert (HTTP_Server.Content (Request_1) = "hello");
         pragma Assert (HTTP_Server.Current (Budget).Current = 5);
         declare
            Client_2  : HTTP_Server.Connection (Wire_2'Access);
            Request_2 : HTTP_Server.Request;
            Denied    : Boolean := False;
         begin
            HTTP_Server.Configure_Ingress_Budget (Client_2, Budget'Access);
            begin
               HTTP_Server.Read_Request (Client_2, Request_2, Closed);
            exception
               when HTTP_Server.Resource_Exhausted =>
                  Denied := True;
            end;
            pragma Assert (Denied);
            pragma Assert (HTTP_Server.Current (Budget).Current = 5);
            pragma Assert (HTTP_Server.Current (Budget).Denials = 1);
         end;
      end;
      pragma Assert (HTTP_Server.Current (Budget).Current = 0);
      pragma Assert (HTTP_Server.Current (Budget).Peak = 5);

      declare
         Timeout_Budget : aliased HTTP_Server.Ingress_Budget (Limit => 8);
         Wire           : aliased Memory_Transport;
         Head           : constant String :=
           "POST /slow HTTP/1.1" & CRLF
           & "Host: localhost" & CRLF
           & "Content-Length: 5" & CRLF & CRLF;
         Timed_Out      : Boolean := False;
      begin
         Wire.Input := To_Unbounded_String (Head & "hello");
         Wire.First_Receive_Max := Head'Length;
         Wire.Slow_After := 1;
         Wire.Receive_Max := 1;
         declare
            Client  : HTTP_Server.Connection (Wire'Access);
            Request : HTTP_Server.Request;
            Closed  : Boolean;
         begin
            HTTP_Server.Configure_Ingress_Budget
              (Client, Timeout_Budget'Access);
            begin
               HTTP_Server.Read_Request
                 (Client, Request, Closed, Timeout => 0.001);
            exception
               when Flyology.IO.Timeout_Error =>
                  Timed_Out := True;
            end;
            pragma Assert (Timed_Out);
            pragma Assert
              (HTTP_Server.Current (Timeout_Budget).Current = 0);
         end;
      end;

      declare
         Small_Budget : aliased HTTP_Server.Ingress_Budget (Limit => 4);
         Wire         : aliased Memory_Transport;

         procedure Route
           (Item  : in out HTTP_Server.Connection;
            Value : HTTP_Server.Request)
         is
            pragma Unreferenced (Item, Value);
         begin
            raise Program_Error with "budget denial reached application";
         end Route;

         package Handler is new
           Flyology.HTTP.Server.Connection_Handlers (Route);
      begin
         Wire.Input := To_Unbounded_String
           ("POST /overloaded HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Content-Length: 5" & CRLF & CRLF & "hello");
         declare
            Client : HTTP_Server.Connection (Wire'Access);
         begin
            HTTP_Server.Configure_Ingress_Budget
              (Client, Small_Budget'Access);
            Handler.Serve (Client);
         end;
         pragma Assert
           (Ada.Strings.Fixed.Index
              (To_String (Wire.Output), "503 Service Unavailable") /= 0);
         pragma Assert (HTTP_Server.Current (Small_Budget).Denials = 1);
         pragma Assert (HTTP_Server.Current (Small_Budget).Current = 0);
      end;
   end Check_Ingress_Budget;

   procedure Check_Response_Framing is
      Wire : aliased Memory_Transport;
   begin
      Wire.Input := To_Unbounded_String
        ("head /extension HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF & CRLF
         & "GET /empty HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF & "Connection: close" & CRLF & CRLF);
      declare
         Client  : HTTP_Server.Connection (Wire'Access);
         Request : HTTP_Server.Request;
         Closed  : Boolean;
      begin
         HTTP_Server.Read_Request (Client, Request, Closed);
         HTTP_Server.Respond (Client, 200, "text/plain", "extension-body");
         HTTP_Server.Read_Request (Client, Request, Closed);
         HTTP_Server.Respond (Client, 204, "", "");
      end;
      declare
         Result      : constant String := To_String (Wire.Output);
         Second_HTTP : constant Natural := Ada.Strings.Fixed.Index
           (Result (Result'First + 1 .. Result'Last), "HTTP/1.1 204");
      begin
         pragma Assert
           (Ada.Strings.Fixed.Index (Result, "extension-body") /= 0);
         pragma Assert (Second_HTTP /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Result (Second_HTTP .. Result'Last), "Content-Length") = 0);
      end;
   end Check_Response_Framing;

   procedure Check_SSE is
      Wire : aliased Memory_Transport;
   begin
      Wire.Input := To_Unbounded_String
        ("GET /events HTTP/1.1" & CRLF & "Host: localhost" & CRLF & CRLF);
      declare
         Client : HTTP_Server.Connection (Wire'Access);
         Request : HTTP_Server.Request;
         Closed : Boolean;
      begin
         HTTP_Server.Read_Request (Client, Request, Closed);
         HTTP_Server.Begin_SSE (Client);
         HTTP_Server.Send_Event
           (Client, "first" & Character'Val (10) & "second",
            Event => "update", Id => "42", Retry => 1_000);
         HTTP_Server.Send_Event
           (Client, "safe" & Character'Val (13) & "event: privileged");
         HTTP_Server.End_SSE (Client);
      end;
      declare
         Result : constant String := To_String (Wire.Output);
      begin
         pragma Assert
           (Ada.Strings.Fixed.Index (Result, "text/event-stream") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Result, "event: update" & Character'Val (10)) /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Result, "data: second" & Character'Val (10)) /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Result,
               "data: safe" & Character'Val (10)
               & "data: event: privileged" & Character'Val (10)) /= 0);
         pragma Assert
           (Result (Result'Last - 6 .. Result'Last) =
              CRLF & "0" & CRLF & CRLF);
      end;
   end Check_SSE;

   procedure Check_WebSocket is
      Wire   : aliased Memory_Transport;
      Budget : aliased HTTP_Server.Ingress_Budget
        (Limit => HTTP_Server.Max_WebSocket_Frame);
      function Frame (First : Natural; Payload : String) return String is
         Mask : constant String :=
           Character'Val (16#37#) & Character'Val (16#FA#)
           & Character'Val (16#21#) & Character'Val (16#3D#);
         Result : Unbounded_String;
      begin
         Append (Result, Character'Val (First));
         Append (Result, Character'Val (16#80# + Payload'Length));
         Append (Result, Mask);
         for Index in Payload'Range loop
            Append
              (Result,
               Character'Val
                 (Natural
                    (Ada.Streams.Stream_Element
                       (Character'Pos (Payload (Index)))
                     xor Ada.Streams.Stream_Element
                       (Character'Pos
                          (Mask ((Index - Payload'First) mod 4 + 1))))));
         end loop;
         return To_String (Result);
      end Frame;
   begin
      Wire.Input := To_Unbounded_String
        ("GET /chat HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF
         & "Upgrade: websocket" & CRLF
         & "Connection: Upgrade" & CRLF
         & "Sec-WebSocket-Version: 13" & CRLF
         & "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" & CRLF & CRLF
         & Frame (16#01#, "H")
         & Frame (16#89#, "?")
         & Frame (16#80#, "i"));
      declare
         Client : HTTP_Server.Connection (Wire'Access);
         Request : HTTP_Server.Request;
         Message : Unbounded_String;
         Kind : HTTP_Server.WebSocket_Data_Kind;
         Closed : Boolean;
      begin
         HTTP_Server.Configure_Ingress_Budget (Client, Budget'Access);
         HTTP_Server.Read_Request (Client, Request, Closed);
         HTTP_Server.Accept_WebSocket (Client, Request);
         HTTP_Server.Receive_WebSocket
           (Client, Kind, Message, Closed);
         pragma Assert (not Closed);
         pragma Assert (Kind = HTTP_Server.Text_Frame);
         pragma Assert (To_String (Message) = "Hi");
         HTTP_Server.Send_WebSocket (Client, Kind, To_String (Message));
         HTTP_Server.Close_WebSocket (Client);
      end;
      pragma Assert (HTTP_Server.Current (Budget).Current = 0);
      pragma Assert
        (HTTP_Server.Current (Budget).Peak =
           HTTP_Server.Max_WebSocket_Frame);
      declare
         Result : constant String := To_String (Wire.Output);
      begin
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Result,
               "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Result,
               Character'Val (16#81#) & Character'Val (2) & "Hi") /= 0);
      end;
   end Check_WebSocket;

   procedure Check_WebSocket_Failures is
      function Frame (Payload : String) return String is
         Mask : constant String := "mask";
         Result : Unbounded_String;
      begin
         Append (Result, Character'Val (16#81#));
         Append (Result, Character'Val (16#80# + Payload'Length));
         Append (Result, Mask);
         for Index in Payload'Range loop
            Append
              (Result,
               Character'Val
                 (Natural
                    (Ada.Streams.Stream_Element
                       (Character'Pos (Payload (Index)))
                     xor Ada.Streams.Stream_Element
                       (Character'Pos
                          (Mask ((Index - Payload'First) mod 4 + 1))))));
         end loop;
         return To_String (Result);
      end Frame;

      Wire : aliased Memory_Transport;
      Failed : Boolean := False;
      Terminal : Boolean := False;
   begin
      Wire.Input := To_Unbounded_String
        ("GET /chat HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF
         & "Upgrade: websocket" & CRLF
         & "Connection: Upgrade" & CRLF
         & "Sec-WebSocket-Version: 13" & CRLF
         & "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" & CRLF & CRLF
         & Frame (String'(1 => Character'Val (16#FF#))));
      declare
         Client  : HTTP_Server.Connection (Wire'Access);
         Request : HTTP_Server.Request;
         Message : Unbounded_String;
         Kind    : HTTP_Server.WebSocket_Data_Kind;
         Closed  : Boolean;
      begin
         HTTP_Server.Read_Request (Client, Request, Closed);
         HTTP_Server.Accept_WebSocket (Client, Request);
         begin
            HTTP_Server.Receive_WebSocket
              (Client, Kind, Message, Closed);
         exception
            when Flyology.HTTP.Protocol_Error =>
               Failed := True;
         end;
         pragma Assert (HTTP_Server.Should_Close (Client));
         begin
            HTTP_Server.Receive_WebSocket
              (Client, Kind, Message, Closed);
         exception
            when Program_Error =>
               Terminal := True;
         end;
      end;
      pragma Assert (Failed and Terminal);
   end Check_WebSocket_Failures;

   procedure Check_WebSocket_Origin is
      Wire : aliased Memory_Transport;
      Rejected : Boolean := False;
   begin
      Wire.Input := To_Unbounded_String
        ("GET /chat HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF
         & "Origin: https://hostile.example" & CRLF
         & "Upgrade: websocket" & CRLF
         & "Connection: Upgrade" & CRLF
         & "Sec-WebSocket-Version: 13" & CRLF
         & "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" & CRLF & CRLF);
      declare
         Client  : HTTP_Server.Connection (Wire'Access);
         Request : HTTP_Server.Request;
         Closed  : Boolean;
      begin
         HTTP_Server.Read_Request (Client, Request, Closed);
         begin
            HTTP_Server.Accept_WebSocket (Client, Request);
         exception
            when Flyology.HTTP.Protocol_Error =>
               Rejected := True;
         end;
      end;
      pragma Assert (Rejected);
   end Check_WebSocket_Origin;

   procedure Check_Slow_Request_Deadline is
      Wire : aliased Memory_Transport;
      Timed_Out : Boolean := False;
   begin
      Wire.Input := To_Unbounded_String
        ("GET / HTTP/1.1" & CRLF & "Host: localhost" & CRLF & CRLF);
      Wire.Slow := True;
      Wire.First_Receive_Max := 1;
      Wire.Receive_Max := 1;
      declare
         Client : HTTP_Server.Connection (Wire'Access);
         Request : HTTP_Server.Request;
         Closed : Boolean;
      begin
         begin
            HTTP_Server.Read_Request
              (Client, Request, Closed, Timeout => 0.016);
         exception
            when Flyology.IO.Timeout_Error =>
               Timed_Out := True;
         end;
      end;
      pragma Assert (Timed_Out);
      pragma Assert (Length (Wire.Input) > 0);
   end Check_Slow_Request_Deadline;

   procedure Check_Slow_Body_Deadline is
      Wire : aliased Memory_Transport;
      Timed_Out : Boolean := False;
      Head : constant String :=
        "POST / HTTP/1.1" & CRLF
        & "Host: localhost" & CRLF
        & "Content-Length: 20" & CRLF & CRLF;
   begin
      Wire.Input := To_Unbounded_String (Head & "01234567890123456789");
      Wire.Slow_After := 1;
      Wire.First_Receive_Max := Head'Length;
      Wire.Receive_Max := 1;
      declare
         Client : HTTP_Server.Connection (Wire'Access);
         Request : HTTP_Server.Request;
         Closed : Boolean;
      begin
         begin
            HTTP_Server.Read_Request
              (Client, Request, Closed, Timeout => 0.016);
         exception
            when Flyology.IO.Timeout_Error =>
               Timed_Out := True;
         end;
      end;
      pragma Assert (Timed_Out);
      pragma Assert (Length (Wire.Input) > 0);
   end Check_Slow_Body_Deadline;

   procedure Check_Handler_Isolation is
      procedure Route
        (Item  : in out HTTP_Server.Connection;
         Value : HTTP_Server.Request)
      is
         pragma Unreferenced (Value);
      begin
         HTTP_Server.Respond (Item, 200, "text/plain", "ok");
      end Route;

      package Handler is new
        Flyology.HTTP.Server.Connection_Handlers (Route);

      Bad_Wire  : aliased Memory_Transport;
      Slow_Wire : aliased Memory_Transport;
   begin
      Bad_Wire.Input := To_Unbounded_String ("not HTTP" & CRLF & CRLF);
      declare
         Client : HTTP_Server.Connection (Bad_Wire'Access);
      begin
         Handler.Serve (Client);
      end;
      pragma Assert
        (Ada.Strings.Fixed.Index
           (To_String (Bad_Wire.Output), "400 Bad Request") /= 0);

      Slow_Wire.Input := To_Unbounded_String
        ("GET / HTTP/1.1" & CRLF & "Host: localhost" & CRLF & CRLF);
      Slow_Wire.Slow := True;
      declare
         Client : HTTP_Server.Connection (Slow_Wire'Access);
      begin
         Handler.Serve (Client, Timeout => 0.001);
      end;
   end Check_Handler_Isolation;

   procedure Check_Application_Failure_Propagates is
      procedure Broken_Route
        (Item  : in out HTTP_Server.Connection;
         Value : HTTP_Server.Request)
      is
         pragma Unreferenced (Item, Value);
      begin
         raise Constraint_Error with "application failure";
      end Broken_Route;

      package Handler is new
        Flyology.HTTP.Server.Connection_Handlers (Broken_Route);

      Wire   : aliased Memory_Transport;
      Raised : Boolean := False;
   begin
      Wire.Input := To_Unbounded_String
        ("GET / HTTP/1.1" & CRLF & "Host: localhost" & CRLF & CRLF);
      declare
         Client : HTTP_Server.Connection (Wire'Access);
      begin
         begin
            Handler.Serve (Client);
         exception
            when Constraint_Error =>
               Raised := True;
         end;
      end;
      pragma Assert (Raised);
   end Check_Application_Failure_Propagates;

   procedure Check_Handler_Limits is
      Count : Natural := 0;

      procedure Route
        (Item  : in out HTTP_Server.Connection;
         Value : HTTP_Server.Request)
      is
         pragma Unreferenced (Value);
      begin
         Count := Count + 1;
         HTTP_Server.Respond (Item, 200, "text/plain", "ok");
      end Route;

      package Handler is new
        Flyology.HTTP.Server.Connection_Handlers (Route);

      Wire : aliased Memory_Transport;
   begin
      Wire.Input := To_Unbounded_String
        ("GET /one HTTP/1.1" & CRLF & "Host: localhost" & CRLF & CRLF
         & "GET /two HTTP/1.1" & CRLF & "Host: localhost" & CRLF & CRLF);
      declare
         Client : HTTP_Server.Connection (Wire'Access);
      begin
         Handler.Serve (Client, Max_Requests => 1);
      end;
      pragma Assert (Count = 1);
      pragma Assert
        (Ada.Strings.Fixed.Index
           (To_String (Wire.Output), "Connection: close") /= 0);
   end Check_Handler_Limits;

   procedure Check_Rejections is
      function Is_Rejected (Input : String) return Boolean is
         Wire : aliased Memory_Transport;
      begin
         Wire.Input := To_Unbounded_String (Input);
         declare
            Client : HTTP_Server.Connection (Wire'Access);
            Request : HTTP_Server.Request;
            Closed : Boolean;
         begin
            begin
               HTTP_Server.Read_Request (Client, Request, Closed);
            exception
               when Flyology.HTTP.Protocol_Error =>
                  return True;
            end;
         end;
         return False;
      end Is_Rejected;

      Oversized_Header : constant String :=
        "GET / HTTP/1.1" & CRLF & "Host: localhost" & CRLF & "X-Fill: "
        & String'(1 .. HTTP_Server.Max_Header_Bytes => 'x');
   begin
      pragma Assert
        (Is_Rejected
           ("POST / HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Content-Length: 1" & CRLF
            & "Content-Length: 1" & CRLF & CRLF & "x"));
      pragma Assert
        (Is_Rejected
           ("POST / HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Transfer-Encoding: chunked" & CRLF
            & "Content-Length: 4" & CRLF & CRLF & "0" & CRLF & CRLF));
      pragma Assert
        (Is_Rejected
           ("POST / HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Content-Length: +1" & CRLF & CRLF & "x"));
      pragma Assert
        (Is_Rejected
           ("POST / HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Content-Length:" & CRLF & CRLF));
      pragma Assert
        (Is_Rejected
           ("GET / HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Transfer-Encoding:" & CRLF & CRLF));
      pragma Assert
        (Is_Rejected
           ("GET / HTTP/1.1" & CRLF
            & "Host: good, evil" & CRLF & CRLF));
      pragma Assert
        (Is_Rejected
           ("GET http://example.test/ HTTP/1.1" & CRLF
            & "Host: other.test" & CRLF & CRLF));
      pragma Assert
        (Is_Rejected
           ("CONNECT example.test:443 HTTP/1.1" & CRLF
            & "Host: example.test:443" & CRLF & CRLF));
      pragma Assert
        (Is_Rejected
           ("POST / HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Transfer-Encoding: chunked" & CRLF & CRLF
            & "2" & CRLF & "x" & CRLF & "0" & CRLF & CRLF));
      pragma Assert (Is_Rejected (Oversized_Header));
   end Check_Rejections;

begin
   Check_HTTP;
   Check_Chunked_And_Expect;
   Check_Streaming_Body;
   Check_Ingress_Budget;
   Check_Response_Framing;
   Check_SSE;
   Check_WebSocket;
   Check_WebSocket_Failures;
   Check_WebSocket_Origin;
   Check_Slow_Request_Deadline;
   Check_Slow_Body_Deadline;
   Check_Handler_Isolation;
   Check_Application_Failure_Propagates;
   Check_Handler_Limits;
   Check_Rejections;
end HTTP_Smoke;
