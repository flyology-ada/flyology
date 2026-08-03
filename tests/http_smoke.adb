with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with GNAT.Sockets;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Connection_Handlers;
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
with Flyology.HTTP.Server.Middleware_Request_IDs;
with Flyology.HTTP.Server.Middleware_Rate_Limits;
with Flyology.HTTP.Server.Middleware_Security_Headers;
with Flyology.HTTP.Server.Routing;
with Flyology.IO;

procedure HTTP_Smoke is
   package HTTP_Server renames Flyology.HTTP.Server;

   use Ada.Strings.Unbounded;
   use type Ada.Exceptions.Exception_Id;
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

   procedure Check_Applications_And_Routing is
      package Applications renames Flyology.HTTP.Server.Applications;

      type Context is record
         Calls      : Natural := 0;
         Last_Value : Unbounded_String;
      end record;

      package Routing is new Flyology.HTTP.Server.Routing (Context);

      procedure Home
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
      begin
         State.Calls := State.Calls + 1;
         X.Text (200, "home");
      end Home;

      procedure User
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
      begin
         State.Calls := State.Calls + 1;
         State.Last_Value := To_Unbounded_String (X.Parameter ("id"));
         X.Text (200, "user " & X.Parameter ("id"));
      end User;

      procedure Asset
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
      begin
         State.Calls := State.Calls + 1;
         State.Last_Value := To_Unbounded_String (X.Parameter ("path"));
         X.Text (200, X.Parameter ("path"));
      end Asset;

      procedure Buffered
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
      begin
         State.Calls := State.Calls + 1;
         State.Last_Value := To_Unbounded_String (X.Content);
         X.Text (200, X.Content);
      end Buffered;

      procedure Streamed
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         Buffer   : Ada.Streams.Stream_Element_Array (1 .. 2);
         Last     : Ada.Streams.Stream_Element_Offset;
         Finished : Boolean;
         Value    : Unbounded_String;
      begin
         State.Calls := State.Calls + 1;
         loop
            X.Read_Body (Buffer, Last, Finished);
            for Index in Buffer'First .. Last loop
               Append (Value, Character'Val (Buffer (Index)));
            end loop;
            exit when Finished;
         end loop;
         State.Last_Value := Value;
         X.Text (200, To_String (Value));
      end Streamed;

      procedure Stream_Response
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
      begin
         State.Calls := State.Calls + 1;
         X.Begin_Stream (200, "text/plain");
         X.Write_Chunk ("one");
         X.Write_Chunk ("two");
         X.End_Stream;
      end Stream_Response;

      Routes : Routing.Router (Capacity => 12, Slashes => Routing.Strict_Slashes);
      Admin  : Routing.Router (Capacity => 2, Slashes => Routing.Strict_Slashes);
      State  : Context;
      Peer   : constant GNAT.Sockets.Sock_Addr_Type :=
        (Family => GNAT.Sockets.Family_Inet,
         Addr   => GNAT.Sockets.Loopback_Inet_Addr,
         Port   => 12_345);

      procedure Run
        (Input : String;
         Expected : String;
         Expected_Status : String := "200")
      is
         Wire : aliased Memory_Transport;
      begin
         Wire.Input := To_Unbounded_String (Input);
         declare
            Client : aliased HTTP_Server.Connection (Wire'Access);
         begin
            Routes.Serve (State, Client, Peer);
         end;
         declare
            Output : constant String := To_String (Wire.Output);
         begin
            pragma Assert
              (Ada.Strings.Fixed.Index
                 (Output, "HTTP/1.1 " & Expected_Status) /= 0);
            pragma Assert (Ada.Strings.Fixed.Index (Output, Expected) /= 0);
         end;
      end Run;
   begin
      Routes.Get ("/", Home'Access, Name => "home");
      Routes.Get ("/users/{id}", User'Access, Name => "users.show");
      Routes.Post
        ("/users/{id}", Buffered'Access, Name => "users.update",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Body_Handling => Applications.Buffer_Body,
              Max_Body      => 64));
      Routes.Get ("/assets/{*path}", Asset'Access, Name => "assets.show");
      Routes.Post
        ("/stream", Streamed'Access, Name => "stream",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Body_Handling => Applications.Stream_Body,
              Max_Body      => 64));
      Routes.Get
        ("/stream-response", Stream_Response'Access,
         Name => "stream.response");
      Admin.Get ("/", Home'Access, Name => "index");
      Routes.Mount ("/admin", Admin, Name_Prefix => "admin.");

      Run
        ("GET /users/%31 HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF & "Connection: close" & CRLF & CRLF,
         "user 1");
      pragma Assert (To_String (State.Last_Value) = "1");

      Run
        ("HEAD /users/9 HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF & "Connection: close" & CRLF & CRLF,
         "Content-Length: 6");

      Run
        ("GET /assets/css/site.css HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF & "Connection: close" & CRLF & CRLF,
         "css/site.css");
      pragma Assert (To_String (State.Last_Value) = "css/site.css");

      Run
        ("POST /users/2 HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF
         & "Expect: 100-continue" & CRLF
         & "Content-Length: 5" & CRLF
         & "Connection: close" & CRLF & CRLF & "hello",
         "100 Continue");
      pragma Assert (To_String (State.Last_Value) = "hello");

      Run
        ("POST /stream HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF
         & "Content-Length: 5" & CRLF
         & "Connection: close" & CRLF & CRLF & "world",
         "world");
      pragma Assert (To_String (State.Last_Value) = "world");

      Run
        ("GET /stream-response HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF & "Connection: close" & CRLF & CRLF,
         "3" & CRLF & "one" & CRLF & "3" & CRLF & "two" & CRLF);

      Run
        ("GET /admin HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF & "Connection: close" & CRLF & CRLF,
         "home");

      Run
        ("PUT /users/3 HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF & "Connection: close" & CRLF & CRLF,
         "Allow: GET, HEAD, POST", "405");

      Run
        ("GET /missing HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF & "Connection: close" & CRLF & CRLF,
         "not-found", "404");

      Run
        ("GET /users/3/ HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF & "Connection: close" & CRLF & CRLF,
         "not-found", "404");

      Run
        ("GET /users/a%2Fb HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF & "Connection: close" & CRLF & CRLF,
         "invalid-path", "400");

      declare
         Ambiguous : Routing.Router
           (Capacity => 2, Slashes => Routing.Strict_Slashes);
         Rejected  : Boolean := False;
      begin
         Ambiguous.Get ("/{left}/x", Home'Access);
         begin
            Ambiguous.Get ("/x/{right}", Home'Access);
         exception
            when Routing.Route_Error =>
               Rejected := True;
         end;
         pragma Assert (Rejected);
      end;
   end Check_Applications_And_Routing;

   procedure Check_Middleware is
      package Applications renames Flyology.HTTP.Server.Applications;

      type Context is record
         Trace : Unbounded_String;
      end record;

      package Routing is new Flyology.HTTP.Server.Routing (Context);

      Expected_Failure : exception;
      Logged           : Natural := 0;

      procedure Log
        (Kind  : Routing.Components.Failure_Kind;
         Error : Ada.Exceptions.Exception_Occurrence;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (Kind, Error, X);
      begin
         Logged := Logged + 1;
      end Log;

      procedure Map
        (State   : in out Context;
         X       : in out Applications.Exchange;
         Error   : Ada.Exceptions.Exception_Occurrence;
         Handled : in out Boolean)
      is
         pragma Unreferenced (State);
      begin
         if Ada.Exceptions.Exception_Identity (Error) =
           Expected_Failure'Identity
         then
            X.Problem (409, "expected", "Expected application failure");
            Handled := True;
         end if;
      end Map;

      package Errors is new Flyology.HTTP.Server.Middleware_Errors
        (Context, Routing.Components, Log, Map);

      procedure Outer
        (State : in out Context;
         X     : in out Applications.Exchange;
         Next  : in out Routing.Components.Next_Handler)
      is
      begin
         Append (State.Trace, "A");
         Next.Call (State, X);
         Append (State.Trace, "D");
      end Outer;

      procedure Inner
        (State : in out Context;
         X     : in out Applications.Exchange;
         Next  : in out Routing.Components.Next_Handler)
      is
      begin
         Append (State.Trace, "B");
         Next.Call (State, X);
         Append (State.Trace, "C");
      end Inner;

      procedure Short_Circuit
        (State : in out Context;
         X     : in out Applications.Exchange;
         Next  : in out Routing.Components.Next_Handler)
      is
         pragma Unreferenced (Next);
      begin
         Append (State.Trace, "S");
         X.Problem (403, "stopped", "Middleware stopped the request");
      end Short_Circuit;

      procedure Body_Aware
        (State : in out Context;
         X     : in out Applications.Exchange;
         Next  : in out Routing.Components.Next_Handler)
      is
      begin
         pragma Assert (X.Content = "hello");
         Append (State.Trace, "E");
         Next.Call (State, X);
         Append (State.Trace, "F");
      end Body_Aware;

      procedure Normal
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
      begin
         Append (State.Trace, "H");
         X.Text (200, "normal");
      end Normal;

      procedure Expected
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State, X);
      begin
         raise Expected_Failure;
      end Expected;

      procedure Unexpected
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State, X);
      begin
         raise Constraint_Error with "private application detail";
      end Unexpected;

      procedure Partial
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
      begin
         X.Begin_Stream (200, "text/plain");
         X.Write_Chunk ("partial");
         raise Constraint_Error with "failure after response start";
      end Partial;

      Routes : Routing.Router
        (Capacity => 7, Slashes => Routing.Strict_Slashes);
      State : Context;
      Peer  : constant GNAT.Sockets.Sock_Addr_Type :=
        (Family => GNAT.Sockets.Family_Inet,
         Addr   => GNAT.Sockets.Loopback_Inet_Addr,
         Port   => 12_345);

      function Run
        (Path    : String;
         Method  : String := "GET";
         Headers : String := "";
         Payload : String := "") return String
      is
         Wire : aliased Memory_Transport;
      begin
         State.Trace := Null_Unbounded_String;
         Wire.Input := To_Unbounded_String
           (Method & " " & Path & " HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & Headers
            & "Connection: close" & CRLF & CRLF & Payload);
         declare
            Client : aliased HTTP_Server.Connection (Wire'Access);
         begin
            Routes.Serve (State, Client, Peer);
         end;
         return To_String (Wire.Output);
      end Run;
   begin
      Routes.Get ("/normal", Normal'Access, Name => "normal");
      Routes.Get ("/short", Normal'Access, Name => "short");
      Routes.Get ("/expected", Expected'Access, Name => "expected");
      Routes.Get ("/unexpected", Unexpected'Access, Name => "unexpected");
      Routes.Get ("/partial", Partial'Access, Name => "partial");
      Routes.Post
        ("/body", Normal'Access, Name => "body",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Body_Handling => Applications.Buffer_Body,
              Max_Body      => 16));
      Routes.Post
        ("/deny-body", Normal'Access, Name => "deny.body",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Body_Handling => Applications.Buffer_Body,
              Max_Body      => 16));
      Routes.Add_Middleware (Errors.Call'Access);
      Routes.Add_Middleware (Outer'Access);
      Routes.Add_Route_Middleware ("normal", Inner'Access);
      Routes.Add_Route_Middleware ("short", Short_Circuit'Access);
      Routes.Add_Route_Middleware
        ("body", Body_Aware'Access, Stage => Routing.Application);
      Routes.Add_Route_Middleware ("deny.body", Short_Circuit'Access);

      declare
         Output : constant String := Run ("/normal");
      begin
         pragma Assert (To_String (State.Trace) = "ABHCD");
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "200 OK") /= 0);
      end;

      declare
         Output : constant String := Run ("/short");
      begin
         pragma Assert (To_String (State.Trace) = "ASD");
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "403 Forbidden") /= 0);
      end;

      declare
         Before : constant Natural := Logged;
         Output : constant String := Run ("/expected");
      begin
         pragma Assert (Logged = Before + 1);
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "409 Conflict") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "private application detail") = 0);
      end;

      declare
         Before : constant Natural := Logged;
         Output : constant String := Run ("/unexpected");
      begin
         pragma Assert (Logged = Before + 1);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Output, "500 Internal Server Error") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "private application detail") = 0);
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "Connection: close") /= 0);
      end;

      declare
         Before : constant Natural := Logged;
         Output : constant String := Run ("/partial");
      begin
         pragma Assert (Logged = Before + 1);
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "200 OK") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "partial") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Output, "500 Internal Server Error") = 0);
      end;

      declare
         Output : constant String := Run
           ("/body", "POST",
            "Expect: 100-continue" & CRLF &
            "Content-Length: 5" & CRLF,
            "hello");
      begin
         pragma Assert (To_String (State.Trace) = "AEHFD");
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "100 Continue") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "200 OK") /= 0);
      end;

      declare
         Output : constant String := Run
           ("/deny-body", "POST",
            "Expect: 100-continue" & CRLF &
            "Content-Length: 5" & CRLF,
            "hello");
      begin
         pragma Assert (To_String (State.Trace) = "ASD");
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "100 Continue") = 0);
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "403 Forbidden") /= 0);
      end;
   end Check_Middleware;

   procedure Check_Standard_Middleware is
      package Applications renames Flyology.HTTP.Server.Applications;

      type Context is record
         Principal : Unbounded_String;
      end record;

      package Routing is new Flyology.HTTP.Server.Routing (Context);

      type Test_Log is limited new Flyology.HTTP.Server.Logging.Sink with
        record
           Calls      : Natural := 0;
           Route      : Unbounded_String;
           Target     : Unbounded_String;
           Request_ID : Unbounded_String;
           Status     : Natural := 0;
        end record;

      overriding procedure Write
        (Item           : in out Test_Log;
         Method         : String;
         Route          : String;
         Target         : String;
         Status         : Natural;
         Request_ID     : String;
         Peer           : GNAT.Sockets.Sock_Addr_Type;
         Request_Bytes  : Natural;
         Response_Bytes : Natural;
         Elapsed        : Duration);

      overriding procedure Write
        (Item           : in out Test_Log;
         Method         : String;
         Route          : String;
         Target         : String;
         Status         : Natural;
         Request_ID     : String;
         Peer           : GNAT.Sockets.Sock_Addr_Type;
         Request_Bytes  : Natural;
         Response_Bytes : Natural;
         Elapsed        : Duration)
      is
         pragma Unreferenced
           (Method, Peer, Request_Bytes, Response_Bytes, Elapsed);
      begin
         Item.Calls := Item.Calls + 1;
         Item.Route := To_Unbounded_String (Route);
         Item.Target := To_Unbounded_String (Target);
         Item.Request_ID := To_Unbounded_String (Request_ID);
         Item.Status := Status;
      end Write;

      procedure Authenticate
        (Scheme        : String;
         Credential    : String;
         Authenticated : out Boolean;
         Principal     : out Unbounded_String)
      is
      begin
         Authenticated := Scheme = "Bearer" and then Credential = "secret";
         Principal :=
           (if Authenticated then To_Unbounded_String ("user-1")
            else Null_Unbounded_String);
      end Authenticate;

      Allowed : aliased constant Flyology.HTTP.Server.CORS.Policy :=
        Flyology.HTTP.Server.CORS.Create
          (Allowed_Origins   => "https://app.example",
           Allowed_Methods   => "GET, OPTIONS",
           Allowed_Headers   => "Content-Type",
           Exposed_Headers   => "X-Request-ID",
           Allow_Credentials => True,
           Max_Age           => 600.0);

      function Resolve (Slot : Positive)
        return access constant Flyology.HTTP.Server.CORS.Policy
      is
      begin
         return (if Slot = 1 then Allowed'Access else null);
      end Resolve;

      Log_Output    : aliased Test_Log;
      Metric_Output : aliased Flyology.HTTP.Server.Metrics.In_Memory
        (Capacity => 1);

      package IDs is new Flyology.HTTP.Server.Middleware_Request_IDs
        (Context, Routing.Components, Trust_Inbound => True);
      package Auth is new Flyology.HTTP.Server.Middleware_Authentication
        (Context, Routing.Components, Authenticate);
      package CORS_Layer is new Flyology.HTTP.Server.Middleware_CORS
        (Context, Routing.Components, Resolve);
      package Headers is new
        Flyology.HTTP.Server.Middleware_Security_Headers
          (Context, Routing.Components,
           Content_Security_Policy => "default-src 'self'",
           Permissions_Policy      => "camera=()",
           Enable_HSTS             => False);
      package Access_Logs is new Flyology.HTTP.Server.Middleware_Logging
        (Context, Routing.Components, Log_Output'Access);
      package Metric_Layer is new Flyology.HTTP.Server.Middleware_Metrics
        (Context, Routing.Components, Metric_Output'Access);

      procedure Private_Handler
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
      begin
         pragma Assert (X.Has_Principal);
         State.Principal := To_Unbounded_String (X.Principal);
         X.Text (200, "private");
      end Private_Handler;

      procedure Public_Handler
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
      begin
         X.Text (200, "public");
      end Public_Handler;

      Routes : Routing.Router
        (Capacity => 3, Slashes => Routing.Strict_Slashes);
      State : Context;
      Peer  : constant GNAT.Sockets.Sock_Addr_Type :=
        (Family => GNAT.Sockets.Family_Inet,
         Addr   => GNAT.Sockets.Loopback_Inet_Addr,
         Port   => 12_345);

      function Run
        (Method, Path : String;
         Headers      : String := "") return String
      is
         Wire : aliased Memory_Transport;
      begin
         Wire.Input := To_Unbounded_String
           (Method & " " & Path & " HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF & Headers
            & "Connection: close" & CRLF & CRLF);
         declare
            Client : aliased HTTP_Server.Connection (Wire'Access);
         begin
            Routes.Serve (State, Client, Peer);
         end;
         return To_String (Wire.Output);
      end Run;
   begin
      Routes.Get
        ("/private", Private_Handler'Access, Name => "private",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Authentication => Routing.Required_Authentication,
              CORS_Policy    => 1));
      Routes.Options
        ("/private", Public_Handler'Access, Name => "private.preflight",
         Policy =>
           (Routing.Default_Route_Policy with delta CORS_Policy => 1));
      Routes.Get ("/public", Public_Handler'Access, Name => "public");
      Routes.Add_Middleware (IDs.Call'Access);
      Routes.Add_Middleware (Access_Logs.Call'Access);
      Routes.Add_Middleware (Metric_Layer.Call'Access);
      Routes.Add_Middleware (Headers.Call'Access);
      Routes.Add_Middleware (CORS_Layer.Call'Access);
      Routes.Add_Middleware (Auth.Call'Access);

      declare
         Output : constant String := Run
           ("GET", "/private?token=must-not-be-logged",
            "Authorization: Bearer secret" & CRLF &
            "X-Request-ID: trusted-1" & CRLF &
            "Origin: https://app.example" & CRLF);
      begin
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "200 OK") /= 0);
         pragma Assert (To_String (State.Principal) = "user-1");
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Output, "X-Request-ID: trusted-1") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Output,
               "Access-Control-Allow-Origin: https://app.example") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "Vary: Origin") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Output, "X-Content-Type-Options: nosniff") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Output, "Strict-Transport-Security") = 0);
         pragma Assert (To_String (Log_Output.Route) = "private");
         pragma Assert (To_String (Log_Output.Target) = "");
         pragma Assert (To_String (Log_Output.Request_ID) = "trusted-1");
      end;

      declare
         Output : constant String := Run
           ("GET", "/private",
            "X-Request-ID: invalid value" & CRLF);
      begin
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "401 Unauthorized") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "invalid value") = 0);
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "X-Request-ID: fly-") /= 0);
      end;

      declare
         Output : constant String := Run
           ("OPTIONS", "/private",
            "Origin: https://app.example" & CRLF &
            "Access-Control-Request-Method: GET" & CRLF &
            "Access-Control-Request-Headers: Content-Type" & CRLF);
      begin
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "204 No Content") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Output, "Access-Control-Allow-Credentials: true") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Output, "Access-Control-Max-Age: 600") /= 0);
      end;

      declare
         Output : constant String := Run
           ("OPTIONS", "/private",
            "Origin: https://evil.example" & CRLF &
            "Access-Control-Request-Method: GET" & CRLF);
      begin
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "403 Forbidden") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Output, "Access-Control-Allow-Origin") = 0);
      end;

      declare
         Output : constant String := Run ("GET", "/public");
         Metrics : constant Flyology.HTTP.Server.Metrics.Snapshot :=
           Flyology.HTTP.Server.Metrics.Read (Metric_Output);
         Rejected : Boolean := False;
      begin
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "200 OK") /= 0);
         pragma Assert (Metrics.Active = 0);
         pragma Assert (Metrics.Requests >= 5);
         pragma Assert (Metrics.Series = 1);
         pragma Assert (Metrics.Dropped_Series > 0);
         begin
            declare
               Invalid : constant Flyology.HTTP.Server.CORS.Policy :=
                 Flyology.HTTP.Server.CORS.Create
                   (Allowed_Origins => "*", Allowed_Methods => "GET",
                    Allow_Credentials => True);
               pragma Unreferenced (Invalid);
            begin
               null;
            end;
         exception
            when Program_Error =>
               Rejected := True;
         end;
         pragma Assert (Rejected);
      end;
   end Check_Standard_Middleware;

   procedure Check_Admission_Middleware is
      use type Ada.Real_Time.Time;
      package Applications renames Flyology.HTTP.Server.Applications;

      type Context is record
         Calls : Natural := 0;
      end record;
      package Routing is new Flyology.HTTP.Server.Routing (Context);

      Clock_Value : Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Permit_Calls : Natural := 0;
      function Test_Clock return Ada.Real_Time.Time is (Clock_Value);
      function Client_Key (X : Applications.Exchange) return String is
        (X.Request_Header ("X-Client"));

      package Rates is new Flyology.HTTP.Server.Middleware_Rate_Limits
        (Context, Routing.Components, Client_Key,
         Capacity => 1, Clock => Test_Clock);
      package Bulkheads is new Flyology.HTTP.Server.Middleware_Bulkheads
        (Context, Routing.Components, Route_Capacity => 4);
      package Deadlines is new Flyology.HTTP.Server.Middleware_Deadlines
        (Context, Routing.Components, Maximum => 1.0, Clock => Test_Clock);

      procedure Limited_Handler
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
      begin
         State.Calls := State.Calls + 1;
         pragma Assert
           (X.Deadline <= Clock_Value + Ada.Real_Time.Seconds (1));
         X.Text (200, "limited");
      end Limited_Handler;

      procedure Fails_Once
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
      begin
         Permit_Calls := Permit_Calls + 1;
         if Permit_Calls = 1 then
            raise Constraint_Error with "first request fails";
         end if;
         X.Text (200, "recovered");
      end Fails_Once;

      Routes : Routing.Router
        (Capacity => 2, Slashes => Routing.Strict_Slashes);
      State : Context;
      Peer  : constant GNAT.Sockets.Sock_Addr_Type :=
        (Family => GNAT.Sockets.Family_Inet,
         Addr   => GNAT.Sockets.Loopback_Inet_Addr,
         Port   => 12_345);

      function Run (Path, Key : String) return String is
         Wire : aliased Memory_Transport;
      begin
         Wire.Input := To_Unbounded_String
           ("GET " & Path & " HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "X-Client: " & Key & CRLF
            & "Connection: close" & CRLF & CRLF);
         declare
            Client : aliased HTTP_Server.Connection (Wire'Access);
         begin
            begin
               Routes.Serve (State, Client, Peer);
            exception
               when Constraint_Error =>
                  null;
            end;
         end;
         return To_String (Wire.Output);
      end Run;
   begin
      Routes.Get
        ("/limited", Limited_Handler'Access, Name => "limited",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Rate_Per_Second => 2,
              Concurrency     => 1));
      Routes.Get
        ("/permit", Fails_Once'Access, Name => "permit",
         Policy =>
           (Routing.Default_Route_Policy with delta Concurrency => 1));
      Routes.Add_Middleware (Deadlines.Call'Access);
      Routes.Add_Middleware (Rates.Call'Access);
      Routes.Add_Middleware (Bulkheads.Call'Access);

      pragma Assert
        (Ada.Strings.Fixed.Index (Run ("/limited", "a"), "200 OK") /= 0);
      pragma Assert
        (Ada.Strings.Fixed.Index (Run ("/limited", "a"), "200 OK") /= 0);
      declare
         Output : constant String := Run ("/limited", "a");
      begin
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "429 Too Many Requests") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "Retry-After: 1") /= 0);
      end;
      Clock_Value := Clock_Value + Ada.Real_Time.Milliseconds (500);
      pragma Assert
        (Ada.Strings.Fixed.Index (Run ("/limited", "a"), "200 OK") /= 0);
      pragma Assert
        (Ada.Strings.Fixed.Index (Run ("/limited", "b"), "200 OK") /= 0);
      pragma Assert
        (Ada.Strings.Fixed.Index (Run ("/limited", "a"), "200 OK") /= 0);

      Permit_Calls := 0;
      declare
         Ignored : constant String := Run ("/permit", "a");
         pragma Unreferenced (Ignored);
      begin
         null;
      end;
      declare
         Output : constant String := Run ("/permit", "a");
      begin
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "200 OK") /= 0, Output);
      end;
   end Check_Admission_Middleware;

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
   Check_Applications_And_Routing;
   Check_Middleware;
   Check_Standard_Middleware;
   Check_Admission_Middleware;
end HTTP_Smoke;
