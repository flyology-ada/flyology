with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Task_Identification;
with Ada.Unchecked_Deallocation;
with Flyology.Cancellation;
with Flyology.Bounded_Channels;
with Flyology.Bytes;
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
with Flyology.HTTP.Server.Native_Routes;
with Flyology.HTTP.Server.Requests;
with Flyology.HTTP.Server.Request_Tasks;
with Flyology.HTTP.Server.Responses;
with Flyology.HTTP.Server.Routing;
with Flyology.HTTP.Server.SSE_Handlers;
with Flyology.HTTP.Server.WebSocket_Handlers;
with Flyology.HTTP.Server.WebSocket_Handlers.Lifecycle;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.Native_Executors;

procedure HTTP_Smoke is
   package HTTP_Server renames Flyology.HTTP.Server;
   package Bytes renames Flyology.Bytes;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Strings.Unbounded;
   use type Ada.Exceptions.Exception_Id;
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Array;
   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Task_Identification.Task_Id;
   use type Flyology.HTTP.HTTP_Version;
   use type HTTP_Server.WebSocket_Data_Kind;

   CRLF : constant String := Character'Val (13) & Character'Val (10);
   Test_Peer : constant Sockets.Endpoint :=
     Sockets.Network_Endpoint (Sockets.Loopback_IPv4, 12_345);

   type Memory_Transport is limited new HTTP_Server.Transport with record
      Input       : Unbounded_String;
      Output      : Unbounded_String;
      Slow        : Boolean := False;
      Slow_After  : Natural := Natural'Last;
      Receive_Calls : Natural := 0;
      Timeout_On_Call : Natural := 0;
      First_Receive_Max : Natural := Natural'Last;
      Receive_Max : Natural := Natural'Last;
      Send_Calls : Natural := 0;
      Timeout_On_Send_Call : Natural := 0;
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
      if Item.Timeout_On_Call = Item.Receive_Calls then
         Item.Timeout_On_Call := 0;
         raise Flyology.IO.Timeout_Error;
      end if;
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
      Item.Send_Calls := Item.Send_Calls + 1;
      if Item.Timeout_On_Send_Call = Item.Send_Calls then
         Item.Timeout_On_Send_Call := 0;
         if Data'Length > 0 then
            Append (Item.Output, Character'Val (Data (Data'First)));
         end if;
         raise Flyology.IO.Timeout_Error;
      end if;
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

      Wire.Input := To_Unbounded_String
        ("POST /quoted HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF
         & "Transfer-Encoding: chunked" & CRLF & CRLF
         & "1;note=""a;b"";escaped=""a" & Character'Val (92)
         & """b""" & CRLF
         & "x" & CRLF & "0" & CRLF & CRLF);
      declare
         Client  : HTTP_Server.Connection (Wire'Access);
         Request : HTTP_Server.Request;
         Closed  : Boolean;
      begin
         HTTP_Server.Read_Request (Client, Request, Closed);
         pragma Assert (HTTP_Server.Content (Request) = "x");
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
      Duplicate_Date_Rejected : Boolean := False;
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
      Wire.Input := To_Unbounded_String
        ("GET /date HTTP/1.1" & CRLF & "Host: localhost" & CRLF & CRLF);
      declare
         Client  : HTTP_Server.Connection (Wire'Access);
         Request : HTTP_Server.Request;
         Closed  : Boolean;
      begin
         HTTP_Server.Read_Request_Head (Client, Request, Closed);
         begin
            HTTP_Server.Respond
              (Client, 200, "text/plain", "x",
               "Date: Thu, 01 Jan 1970 00:00:00 GMT" & CRLF);
         exception
            when Program_Error => Duplicate_Date_Rejected := True;
         end;
      end;
      pragma Assert (Duplicate_Date_Rejected);

      Wire.Input := To_Unbounded_String
        ("GET /binary HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF & "Connection: close" & CRLF & CRLF);
      Wire.Output := Null_Unbounded_String;
      declare
         Client  : HTTP_Server.Connection (Wire'Access);
         Request : HTTP_Server.Request;
         Closed  : Boolean;
         Data    : constant Ada.Streams.Stream_Element_Array :=
           (1 => 0, 2 => 128, 3 => 255);
      begin
         HTTP_Server.Read_Request_Head (Client, Request, Closed);
         HTTP_Server.Begin_Response_Stream
           (Client, 200, "application/octet-stream");
         HTTP_Server.Write_Response_Chunk (Client, Data);
         HTTP_Server.End_Response_Stream (Client);
      end;
      pragma Assert
        (Ada.Strings.Fixed.Index
           (To_String (Wire.Output),
            "3" & CRLF & Character'Val (0) & Character'Val (128)
            & Character'Val (255) & CRLF) /= 0);
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
         HTTP_Server.Send_Event
           (Client, "reset", Id => "", Retry => 0,
            Include_Id => True, Include_Retry => True);
         HTTP_Server.Send_SSE_Comment (Client, "heartbeat");
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
           (Ada.Strings.Fixed.Index
              (Result, "id: " & Character'Val (10)
               & "retry: 0" & Character'Val (10)) /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Result, ": heartbeat" & Character'Val (10)) /= 0);
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
         Message : Bytes.Unbounded_Bytes;
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
         pragma Assert (Bytes.To_Byte_String (Message) = "Hi");
         declare
            Calls_Before : constant Natural := Wire.Send_Calls;
         begin
            HTTP_Server.Send_WebSocket
              (Client, Kind, Bytes.To_Array (Message));
            pragma Assert (Wire.Send_Calls = Calls_Before + 1);
         end;
         declare
            Large : constant Ada.Streams.Stream_Element_Array
              (1 .. 4 * 1_024 + 1) := (others => 42);
            Calls_Before : constant Natural := Wire.Send_Calls;
         begin
            HTTP_Server.Send_WebSocket
              (Client, HTTP_Server.Binary_Frame, Large);
            pragma Assert (Wire.Send_Calls = Calls_Before + 2);
         end;
         HTTP_Server.Close_WebSocket (Client);
      end;
      pragma Assert (HTTP_Server.Current (Budget).Current = 0);
      pragma Assert
        (HTTP_Server.Current (Budget).Peak in 1 .. 32);
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
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Result,
               Character'Val (16#82#) & Character'Val (126)
               & Character'Val (16#10#) & Character'Val (1)
               & Character'Val (42) & Character'Val (42)) /= 0);
      end;
   end Check_WebSocket;

   procedure Check_WebSocket_Binary_Bytes is
      Payload : constant String :=
        Character'Val (0) & Character'Val (128) & Character'Val (255);

      function Frame return String is
         Mask   : constant String := "mask";
         Result : Unbounded_String;
      begin
         Append (Result, Character'Val (16#82#));
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
   begin
      Wire.Input := To_Unbounded_String
        ("GET /binary HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF
         & "Upgrade: websocket" & CRLF
         & "Connection: Upgrade" & CRLF
         & "Sec-WebSocket-Version: 13" & CRLF
         & "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" & CRLF & CRLF
         & Frame);
      declare
         Client   : HTTP_Server.Connection (Wire'Access);
         Request  : HTTP_Server.Request;
         Message  : Bytes.Unbounded_Bytes;
         Kind     : HTTP_Server.WebSocket_Data_Kind;
         Closed   : Boolean;
         Expected : constant Ada.Streams.Stream_Element_Array :=
           (1 => 0, 2 => 128, 3 => 255);
      begin
         HTTP_Server.Read_Request (Client, Request, Closed);
         HTTP_Server.Accept_WebSocket (Client, Request);
         HTTP_Server.Receive_WebSocket (Client, Kind, Message, Closed);
         pragma Assert (not Closed);
         pragma Assert (Kind = HTTP_Server.Binary_Frame);
         pragma Assert (Bytes.To_Array (Message) = Expected);
         HTTP_Server.Send_WebSocket
           (Client, HTTP_Server.Binary_Frame, Bytes.To_Array (Message));
         HTTP_Server.Close_WebSocket (Client);
      end;
      pragma Assert
        (Ada.Strings.Fixed.Index
           (To_String (Wire.Output),
            Character'Val (16#82#) & Character'Val (3) & Payload) /= 0);
   end Check_WebSocket_Binary_Bytes;

   procedure Check_Idle_WebSocket_Budget is
      Count : constant := 65;
      Head  : constant String :=
        "GET /chat HTTP/1.1" & CRLF
        & "Host: localhost" & CRLF
        & "Upgrade: websocket" & CRLF
        & "Connection: Upgrade" & CRLF
        & "Sec-WebSocket-Version: 13" & CRLF
        & "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" & CRLF & CRLF;
      Budget : aliased HTTP_Server.Ingress_Budget (Limit => 64 * 1_024);
      type Wire_Access is access all Memory_Transport;
      type Connection_Access is access all HTTP_Server.Connection;
      type Wire_Array is array (Positive range <>) of Wire_Access;
      type Connection_Array is array (Positive range <>) of Connection_Access;
      Wires   : Wire_Array (1 .. Count) := (others => null);
      Clients : Connection_Array (1 .. Count) := (others => null);
      procedure Free_Wire is new Ada.Unchecked_Deallocation
        (Memory_Transport, Wire_Access);
      procedure Free_Connection is new Ada.Unchecked_Deallocation
        (HTTP_Server.Connection, Connection_Access);
   begin
      for Index in Clients'Range loop
         Wires (Index) := new Memory_Transport;
         Wires (Index).Input := To_Unbounded_String (Head);
         Clients (Index) := new HTTP_Server.Connection (Wires (Index));
         HTTP_Server.Configure_Ingress_Budget
           (Clients (Index).all, Budget'Access);
         declare
            Request : HTTP_Server.Request;
            Closed  : Boolean;
            Kind    : HTTP_Server.WebSocket_Data_Kind;
            Data    : Bytes.Unbounded_Bytes;
            Timed_Out : Boolean := False;
         begin
            HTTP_Server.Read_Request_Head
              (Clients (Index).all, Request, Closed, Timeout => 1.0);
            HTTP_Server.Accept_WebSocket
              (Clients (Index).all, Request, Timeout => 1.0);
            Wires (Index).Slow := True;
            begin
               HTTP_Server.Receive_WebSocket
                 (Clients (Index).all, Kind, Data, Closed,
                  Timeout => 0.001, Message_Timeout => 1.0);
            exception
               when Flyology.IO.Timeout_Error => Timed_Out := True;
            end;
            pragma Assert (Timed_Out);
            pragma Assert (HTTP_Server.Current (Budget).Current = 0);
         end;
      end loop;
      for Index in Clients'Range loop
         Free_Connection (Clients (Index));
         Free_Wire (Wires (Index));
      end loop;
   end Check_Idle_WebSocket_Budget;

   procedure Check_Periodic_WebSocket_Pings is
      function Ping return String is
         Mask : constant String := "mask";
      begin
         return Character'Val (16#89#) & Character'Val (16#80#)
           & Mask;
      end Ping;
      Head : constant String :=
        "GET /chat HTTP/1.1" & CRLF
        & "Host: localhost" & CRLF
        & "Upgrade: websocket" & CRLF
        & "Connection: Upgrade" & CRLF
        & "Sec-WebSocket-Version: 13" & CRLF
        & "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" & CRLF & CRLF;
      Wire : aliased Memory_Transport;
   begin
      Wire.Input := To_Unbounded_String (Head);
      declare
         Client  : HTTP_Server.Connection (Wire'Access);
         Request : HTTP_Server.Request;
         Kind    : HTTP_Server.WebSocket_Data_Kind;
         Data    : Bytes.Unbounded_Bytes;
         Closed  : Boolean;
      begin
         HTTP_Server.Read_Request_Head (Client, Request, Closed);
         HTTP_Server.Accept_WebSocket (Client, Request);
         for Iteration in 1 .. 40 loop
            Append (Wire.Input, Ping);
            Wire.Slow_After := Wire.Receive_Calls + 1;
            begin
               HTTP_Server.Receive_WebSocket
                 (Client, Kind, Data, Closed,
                  Timeout => 0.001, Message_Timeout => 1.0);
            exception
               when Flyology.IO.Timeout_Error => null;
            end;
         end loop;
         HTTP_Server.Send_WebSocket (Client, "ok");
         HTTP_Server.Close_WebSocket (Client);
      end;
   end Check_Periodic_WebSocket_Pings;

   procedure Check_WebSocket_Control_Write_Timeout is
      function Ping return String is
         Mask : constant String := "mask";
         Value : Unbounded_String;
      begin
         Append (Value, Character'Val (16#89#));
         Append (Value, Character'Val (16#81#));
         Append (Value, Mask);
         Append
           (Value,
            Character'Val
              (Natural
                 (Ada.Streams.Stream_Element (Character'Pos ('?'))
                  xor Ada.Streams.Stream_Element
                    (Character'Pos (Mask (1))))));
         return To_String (Value);
      end Ping;
      Wire : aliased Memory_Transport;
      Request : HTTP_Server.Request;
      Closed : Boolean;
      Kind : HTTP_Server.WebSocket_Data_Kind;
      Data : Bytes.Unbounded_Bytes;
      Timed_Out : Boolean := False;
      Terminal : Boolean := False;
   begin
      Wire.Input := To_Unbounded_String
        ("GET /chat HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF
         & "Upgrade: websocket" & CRLF
         & "Connection: Upgrade" & CRLF
         & "Sec-WebSocket-Version: 13" & CRLF
         & "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" & CRLF & CRLF
         & Ping);
      declare
         Client : HTTP_Server.Connection (Wire'Access);
      begin
         HTTP_Server.Read_Request_Head (Client, Request, Closed);
         HTTP_Server.Accept_WebSocket (Client, Request);
         Wire.Timeout_On_Send_Call := 2;
         begin
            HTTP_Server.Receive_WebSocket
              (Client, Kind, Data, Closed, Timeout => 1.0);
         exception
            when Flyology.IO.Timeout_Error => Timed_Out := True;
         end;
         begin
            HTTP_Server.Send_WebSocket (Client, "x");
         exception
            when Program_Error => Terminal := True;
         end;
      end;
      pragma Assert (Timed_Out and Terminal);
   end Check_WebSocket_Control_Write_Timeout;

   procedure Check_WebSocket_Data_Write_Timeout is
      Wire : aliased Memory_Transport;
      Budget : aliased HTTP_Server.Ingress_Budget (Limit => 1_024);
      Payload : constant Ada.Streams.Stream_Element_Array
        (1 .. 4 * 1_024 + 1) := (others => 42);
      Terminal : Boolean := False;
      Timed_Out : Boolean := False;
   begin
      Wire.Input := To_Unbounded_String
        ("GET /chat HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF
         & "Upgrade: websocket" & CRLF
         & "Connection: Upgrade" & CRLF
         & "Sec-WebSocket-Version: 13" & CRLF
         & "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" & CRLF & CRLF);
      declare
         Client  : HTTP_Server.Connection (Wire'Access);
         Request : HTTP_Server.Request;
         Closed  : Boolean;
      begin
         HTTP_Server.Configure_Ingress_Budget (Client, Budget'Access);
         HTTP_Server.Read_Request_Head (Client, Request, Closed);
         HTTP_Server.Accept_WebSocket (Client, Request);
         --  Exercise failure after the frame header has been written but the
         --  borrowed payload is still in its original storage.
         Wire.Timeout_On_Send_Call := Wire.Send_Calls + 2;
         begin
            HTTP_Server.Send_WebSocket
              (Client, HTTP_Server.Binary_Frame, Payload, Timeout => 0.001);
         exception
            when Flyology.IO.Timeout_Error => Timed_Out := True;
         end;
         begin
            HTTP_Server.Send_WebSocket (Client, "again");
         exception
            when Program_Error => Terminal := True;
         end;
      end;
      pragma Assert (Timed_Out and Terminal);
      pragma Assert (HTTP_Server.Current (Budget).Current = 0);
   end Check_WebSocket_Data_Write_Timeout;

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
         Message : Bytes.Unbounded_Bytes;
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
      declare
         Version_Wire : aliased Memory_Transport;
         Version_Failed : Boolean := False;
      begin
         Version_Wire.Input := To_Unbounded_String
           ("GET /chat HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Upgrade: websocket" & CRLF
            & "Connection: Upgrade" & CRLF
            & "Sec-WebSocket-Version: 12" & CRLF
            & "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="
            & CRLF & CRLF);
         declare
            Client  : HTTP_Server.Connection (Version_Wire'Access);
            Request : HTTP_Server.Request;
            Closed  : Boolean;
         begin
            HTTP_Server.Read_Request_Head (Client, Request, Closed);
            begin
               HTTP_Server.Accept_WebSocket (Client, Request);
            exception
               when Flyology.HTTP.Protocol_Error => Version_Failed := True;
            end;
         end;
         pragma Assert (Version_Failed);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (To_String (Version_Wire.Output), "426 Upgrade Required") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (To_String (Version_Wire.Output),
               "Sec-WebSocket-Version: 13") /= 0);
      end;
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
            HTTP_Server.Read_Request_Head
              (Client, Request, Closed,
               Header_Timeout  => 0.016,
               Request_Timeout => 1.0);
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

   procedure Check_Separate_Header_Deadline is
      use type Ada.Real_Time.Time;
      Wire : aliased Memory_Transport;
      Left : Duration;
   begin
      Wire.Input := To_Unbounded_String
        ("GET / HTTP/1.1" & CRLF & "Host: localhost" & CRLF & CRLF);
      declare
         Client  : HTTP_Server.Connection (Wire'Access);
         Request : HTTP_Server.Request;
         Closed  : Boolean;
      begin
         HTTP_Server.Read_Request_Head
           (Client, Request, Closed,
            Header_Timeout  => 0.05,
            Request_Timeout => 1.0);
         Left := Ada.Real_Time.To_Duration
           (HTTP_Server.Request_Deadline (Client) - Ada.Real_Time.Clock);
      end;
      pragma Assert (Left > 0.8);
   end Check_Separate_Header_Deadline;

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

   procedure Check_Handler_Streamed_Limit is
      procedure Route
        (Item  : in out HTTP_Server.Connection;
         Value : HTTP_Server.Request)
      is
         pragma Unreferenced (Value);
         Data     : Ada.Streams.Stream_Element_Array (1 .. 2);
         Last     : Ada.Streams.Stream_Element_Offset;
         Finished : Boolean;
      begin
         loop
            HTTP_Server.Read_Body (Item, Data, Last, Finished);
            exit when Finished;
         end loop;
      end Route;

      package Handler is new
        Flyology.HTTP.Server.Connection_Handlers (Route);

      Wire : aliased Memory_Transport;
   begin
      Wire.Input := To_Unbounded_String
        ("POST /stream HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF
         & "Transfer-Encoding: chunked" & CRLF & CRLF
         & "5" & CRLF & "hello" & CRLF
         & "0" & CRLF & CRLF);
      declare
         Client : HTTP_Server.Connection (Wire'Access);
      begin
         Handler.Serve (Client, Buffer_Body => False, Max_Body => 4);
      end;
      pragma Assert
        (Ada.Strings.Fixed.Index
           (To_String (Wire.Output), "413 Content Too Large") /= 0);
   end Check_Handler_Streamed_Limit;

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
           ("GET /known?x=%ZZ HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF & CRLF));
      pragma Assert
        (Is_Rejected
           ("GET / HTTP/1.1" & CRLF
            & "Host: [1:::2]" & CRLF & CRLF));
      pragma Assert
        (Is_Rejected
           ("POST / HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Transfer-Encoding: chunked" & CRLF & CRLF
            & "2" & CRLF & "x" & CRLF & "0" & CRLF & CRLF));
      pragma Assert
        (Is_Rejected
           ("POST / HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Transfer-Encoding: chunked" & CRLF & CRLF
            & "1;=x" & CRLF & "x" & CRLF & "0" & CRLF & CRLF));
      pragma Assert
        (Is_Rejected
           ("POST / HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Transfer-Encoding: chunked" & CRLF & CRLF
            & "1;note=""a" & Character'Val (92) & Character'Val (0)
            & """" & CRLF
            & "x" & CRLF & "0" & CRLF & CRLF));
      pragma Assert
        (Is_Rejected
           ("GET /bad{path HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF & CRLF));
      pragma Assert
        (Is_Rejected
           ("GET /?bad=| HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF & CRLF));
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

      procedure Explode
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State, X);
      begin
         raise Constraint_Error with "expected application failure";
      end Explode;

      procedure Stamp_Global
        (State : in out Context;
         X     : in out Applications.Exchange;
         Next  : in out Routing.Components.Next_Handler)
      is
      begin
         X.Add_Header ("X-Global-Middleware", "yes");
         Next.Call (State, X);
      end Stamp_Global;

      procedure Pass
        (State : in out Context;
         X     : in out Applications.Exchange;
         Next  : in out Routing.Components.Next_Handler) is
      begin
         Next.Call (State, X);
      end Pass;

      procedure Bypass_Authentication
        (State : in out Context;
         X     : in out Applications.Exchange;
         Next  : in out Routing.Components.Next_Handler)
      is
         pragma Unreferenced (State, Next);
      begin
         X.Text (200, "must-not-bypass-authentication");
      end Bypass_Authentication;

      Routes : Routing.Router (Capacity => 12, Slashes => Routing.Strict_Slashes);
      Admin  : Routing.Router (Capacity => 2, Slashes => Routing.Strict_Slashes);
      State  : Context;
      Peer   : constant Sockets.Endpoint := Test_Peer;

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
            pragma Assert (Ada.Strings.Fixed.Index (Output, "Date: ") /= 0);
            pragma Assert (Ada.Strings.Fixed.Index (Output, Expected) /= 0);
         end;
      end Run;
   begin
      Routes.Add_Middleware
        (Stamp_Global'Access, Name => "response-stamp");
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
      Routes.Get
        ("/private", Home'Access, Name => "private",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Authentication => Routing.Required_Authentication));
      Routes.Get ("/explode", Explode'Access, Name => "explode");
      Admin.Get ("/", Home'Access, Name => "index");
      Admin.Add_Middleware
        (Pass'Access, Stage => Routing.Application,
         Name => "admin-security");
      Routes.Mount ("/admin", Admin, Name_Prefix => "admin.");

      pragma Assert (Routes.Route_Count = 9);
      pragma Assert (Routes.Global_Middleware_Count = 1);
      declare
         Home_Route : constant Routing.Route_Description :=
           Routes.Describe_Route (1);
         Admin_Route : constant Routing.Route_Description :=
           Routes.Describe_Route (9);
         Global_Component : constant Routing.Middleware_Description :=
           Routes.Describe_Global_Middleware (1);
         Mounted_Component : constant Routing.Middleware_Description :=
           Routes.Describe_Route_Middleware (9, 1);
      begin
         pragma Assert (To_String (Home_Route.Method) = "GET");
         pragma Assert (To_String (Home_Route.Pattern) = "/");
         pragma Assert (To_String (Home_Route.Name) = "home");
         pragma Assert (Home_Route.Middleware_Count = 0);
         pragma Assert (To_String (Admin_Route.Pattern) = "/admin");
         pragma Assert (To_String (Admin_Route.Name) = "admin.index");
         pragma Assert (Routes.Route_Middleware_Count (9) = 1);
         pragma Assert
           (To_String (Global_Component.Name) = "response-stamp");
         pragma Assert
           (To_String (Mounted_Component.Name) = "admin-security");
         pragma Assert
           (Routing.Middleware_Stage'Pos (Mounted_Component.Stage) =
              Routing.Middleware_Stage'Pos (Routing.Application));
      end;
      declare
         Rejected : Boolean := False;
      begin
         begin
            declare
               Invalid : constant Routing.Route_Description :=
                 Routes.Describe_Route (10);
            begin
               pragma Unreferenced (Invalid);
            end;
         exception
            when Constraint_Error =>
               Rejected := True;
         end;
         pragma Assert (Rejected);
      end;

      Run
        ("GET /users/%31 HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF & "Connection: close" & CRLF & CRLF,
         "user 1");
      pragma Assert (To_String (State.Last_Value) = "1");

      Run
        ("GET / HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF & "Connection: close" & CRLF & CRLF,
         "home");

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
        ("GET /missing HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF & "Connection: close" & CRLF & CRLF,
         "X-Global-Middleware: yes", "404");

      Run
        ("OPTIONS * HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF & "Connection: close" & CRLF & CRLF,
         "Allow: OPTIONS, GET, HEAD, POST", "204");

      Run
        ("GET /private HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF & "Connection: close" & CRLF & CRLF,
         "WWW-Authenticate: Bearer", "401");

      Run
        ("GET /explode HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF & "Connection: close" & CRLF & CRLF,
         "internal server error", "500");

      Run
        ("GET /users/3/ HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF & "Connection: close" & CRLF & CRLF,
         "not-found", "404");

      Run
        ("GET /users/a%2Fb HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF & "Connection: close" & CRLF & CRLF,
         "invalid-path", "400");

      declare
         Target : Unbounded_String;
      begin
         for Index in 1 .. 65 loop
            pragma Unreferenced (Index);
            Append (Target, "/x");
         end loop;
         Run
           ("GET " & To_String (Target) & " HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Connection: close" & CRLF & CRLF,
            "invalid-path", "400");
      end;

      declare
         Ignored : Routing.Router
           (Capacity => 1, Slashes => Routing.Ignore_Slashes);
         Wire : aliased Memory_Transport;
         Local_State : Context;
      begin
         Ignored.Get ("/users/{id}", User'Access, Name => "ignored.user");
         Wire.Input := To_Unbounded_String
           ("GET /users/7/ HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Connection: close" & CRLF & CRLF);
         declare
            Client : aliased HTTP_Server.Connection (Wire'Access);
         begin
            Ignored.Serve (Local_State, Client, Peer);
         end;
         pragma Assert
           (Ada.Strings.Fixed.Index (To_String (Wire.Output), "200 OK") /= 0);
         pragma Assert (To_String (Local_State.Last_Value) = "7");
      end;

      declare
         Redirected : Routing.Router
           (Capacity => 1, Slashes => Routing.Redirect_Slashes);
         Wire : aliased Memory_Transport;
         Local_State : Context;
      begin
         Redirected.Get
           ("/users/{id}", User'Access, Name => "redirected.user");
         Wire.Input := To_Unbounded_String
           ("GET /users/7/ HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Connection: close" & CRLF & CRLF);
         declare
            Client : aliased HTTP_Server.Connection (Wire'Access);
         begin
            Redirected.Serve (Local_State, Client, Peer);
         end;
         pragma Assert
           (Ada.Strings.Fixed.Index
              (To_String (Wire.Output), "308 Permanent Redirect") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (To_String (Wire.Output), "Location: /users/7") /= 0);
      end;

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

      declare
         Full : Routing.Router
           (Capacity => 1, Slashes => Routing.Strict_Slashes);
         Wire : aliased Memory_Transport;
         Local_State : Context;
      begin
         Full.Get ("/full", Home'Access, Name => "full");
         for Index in 1 .. 16 loop
            Full.Add_Middleware (Pass'Access);
            Full.Add_Route_Middleware ("full", Pass'Access);
         end loop;
         Wire.Input := To_Unbounded_String
           ("GET /full HTTP/1.1" & CRLF & "Host: localhost" & CRLF
            & "Connection: close" & CRLF & CRLF);
         declare
            Client : aliased HTTP_Server.Connection (Wire'Access);
         begin
            Full.Serve (Local_State, Client, Peer);
         end;
         pragma Assert
           (Ada.Strings.Fixed.Index (To_String (Wire.Output), "200 OK") /= 0);
      end;

      declare
         Protected_Routes : Routing.Router
           (Capacity => 1, Slashes => Routing.Strict_Slashes);
         Wire : aliased Memory_Transport;
         Local_State : Context;
      begin
         Protected_Routes.Add_Middleware (Bypass_Authentication'Access);
         Protected_Routes.Get
           ("/protected", Home'Access, Name => "protected",
            Policy =>
              (Routing.Default_Route_Policy with delta
                 Authentication => Routing.Required_Authentication));
         Wire.Input := To_Unbounded_String
           ("GET /protected HTTP/1.1" & CRLF & "Host: localhost" & CRLF
            & "Connection: close" & CRLF & CRLF);
         declare
            Client : aliased HTTP_Server.Connection (Wire'Access);
         begin
            Protected_Routes.Serve (Local_State, Client, Peer);
         end;
         pragma Assert
           (Ada.Strings.Fixed.Index
              (To_String (Wire.Output), "500 Internal Server Error") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (To_String (Wire.Output), "must-not-bypass") = 0);
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
      Peer  : constant Sockets.Endpoint := Test_Peer;

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

      type Generated_ID_Mode is (Valid_ID, Invalid_ID, Oversized_ID);

      type Context is record
         Principal          : Unbounded_String;
         Generated_ID_Count : Natural := 0;
         Generated_ID       : Generated_ID_Mode := Valid_ID;
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
         Peer           : Sockets.Endpoint;
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
         Peer           : Sockets.Endpoint;
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

      procedure Generate_Request_ID
        (State : in out Context;
         X     : Applications.Exchange;
         Value : out Unbounded_String)
      is
      begin
         State.Generated_ID_Count := State.Generated_ID_Count + 1;
         case State.Generated_ID is
            when Valid_ID =>
               Value := To_Unbounded_String
                 ("custom-" & X.Request_Method & "-"
                  & Ada.Strings.Fixed.Trim
                      (Natural'Image (State.Generated_ID_Count),
                       Ada.Strings.Both));
            when Invalid_ID =>
               Value := To_Unbounded_String ("invalid generated value");
            when Oversized_ID =>
               Value := To_Unbounded_String (String'(1 .. 129 => 'a'));
         end case;
      end Generate_Request_ID;

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
      package Generated_IDs is new
        Flyology.HTTP.Server.Middleware_Request_IDs
          (Context, Routing.Components,
           Trust_Inbound => False,
           Header_Name   => "X-Trace-ID",
           Generate      => Generate_Request_ID'Access);
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
      Generated_ID_Routes : Routing.Router
        (Capacity => 1, Slashes => Routing.Strict_Slashes);
      State : Context;
      Peer  : constant Sockets.Endpoint := Test_Peer;

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

      function Run_With_Generated_ID
        (Headers : String := "") return String
      is
         Wire : aliased Memory_Transport;
      begin
         Wire.Input := To_Unbounded_String
           ("GET /public HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF & Headers
            & "Connection: close" & CRLF & CRLF);
         declare
            Client : aliased HTTP_Server.Connection (Wire'Access);
         begin
            Generated_ID_Routes.Serve (State, Client, Peer);
         exception
            when Constraint_Error =>
               --  Invalid generator output is rejected before any response
               --  header or downstream handler can observe the value.
               null;
         end;
         return To_String (Wire.Output);
      end Run_With_Generated_ID;
   begin
      Routes.Get
        ("/private", Private_Handler'Access, Name => "private",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Authentication => Routing.Required_Authentication,
              CORS_Policy    => 1));
      Routes.Get ("/public", Public_Handler'Access, Name => "public");
      Routes.Add_Middleware (IDs.Call'Access);
      Routes.Add_Middleware (Access_Logs.Call'Access);
      Routes.Add_Middleware (Metric_Layer.Call'Access);
      Routes.Add_Middleware (Headers.Call'Access);
      Routes.Add_Middleware (CORS_Layer.Call'Access);
      Routes.Add_Middleware (Auth.Call'Access);
      Generated_ID_Routes.Get
        ("/public", Public_Handler'Access, Name => "generated-id");
      Generated_ID_Routes.Add_Middleware (Generated_IDs.Call'Access);

      declare
         Output : constant String := Run_With_Generated_ID
           ("X-Trace-ID: ignored-inbound" & CRLF);
      begin
         pragma Assert (State.Generated_ID_Count = 1);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Output, "X-Trace-ID: custom-GET-1") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "ignored-inbound") = 0);
      end;

      State.Generated_ID := Invalid_ID;
      declare
         Output : constant String := Run_With_Generated_ID;
      begin
         pragma Assert (State.Generated_ID_Count = 2);
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "500 Internal Server Error") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "X-Trace-ID:") = 0);
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "invalid generated value") = 0);
      end;
      State.Generated_ID := Oversized_ID;
      declare
         Output : constant String := Run_With_Generated_ID;
      begin
         pragma Assert (State.Generated_ID_Count = 3);
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "500 Internal Server Error") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "X-Trace-ID:") = 0);
      end;
      State.Generated_ID := Valid_ID;

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

      declare
         Saturating : Flyology.HTTP.Server.Metrics.In_Memory (Capacity => 1);
      begin
         Saturating.End_Request
           (Method => "GET", Route => "bounded", Status => 200,
            Elapsed => Duration'Last,
            Request_Bytes => Natural'Last,
            Response_Bytes => Natural'Last);
         Saturating.End_Request
           (Method => "GET", Route => "bounded", Status => 200,
            Elapsed => 1.0, Request_Bytes => 1, Response_Bytes => 1);
         declare
            Values : constant Flyology.HTTP.Server.Metrics.Snapshot :=
              Saturating.Read;
         begin
            pragma Assert (Values.Request_Bytes = Natural'Last);
            pragma Assert (Values.Response_Bytes = Natural'Last);
            pragma Assert (Values.Latency_Total = Duration'Last);
            pragma Assert (Values.Requests = 2);
         end;
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
      Peer  : constant Sockets.Endpoint := Test_Peer;

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

   procedure Check_Request_Response_Helpers is
      package Applications renames Flyology.HTTP.Server.Applications;
      package Requests renames Flyology.HTTP.Server.Requests;
      package Responses renames Flyology.HTTP.Server.Responses;
      type Context is null record;
      package Routing is new Flyology.HTTP.Server.Routing (Context);

      procedure Helpers
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
         Builder : Responses.Builder;
         Options : Responses.Cookie_Options;
         Rejected : Boolean := False;
      begin
         pragma Assert (Requests.Query (X, "q", 1) = "a b");
         pragma Assert (Requests.Query (X, "q", 2) = "2");
         pragma Assert (Requests.Has_Query (X, "empty"));
         pragma Assert (Requests.Cookie (X, "session") = "first");
         pragma Assert (Requests.Media_Type (X) = "text/plain");
         pragma Assert
           (Requests.Content_Type_Parameter (X, "charset") = "UTF-8");
         pragma Assert (Requests.Authority (X) = "example.test");
         Options.Path := To_Unbounded_String ("/; Secure");
         begin
            Responses.Set_Cookie (X, "bad", "value", Options);
         exception
            when Program_Error => Rejected := True;
         end;
         pragma Assert (Rejected);
         Options.Path := To_Unbounded_String ("/");
         Responses.Set_Cookie (X, "result", "ok", Options);
         Builder.Initialize (201, "text/plain");
         Builder.Add_Header ("X-Helper", "yes");
         Builder.Set_Payload ("built");
         Builder.Send (X);
      end Helpers;

      Routes : Routing.Router
        (Capacity => 1, Slashes => Routing.Strict_Slashes);
      State : Context;
      Peer  : constant Sockets.Endpoint := Test_Peer;
      Wire : aliased Memory_Transport;
   begin
      Routes.Get ("/helpers", Helpers'Access, Name => "helpers");
      Wire.Input := To_Unbounded_String
        ("GET /helpers?q=a+b&q=%32&empty HTTP/1.1" & CRLF
         & "Host: example.test" & CRLF
         & "Cookie: session=first; session=second" & CRLF
         & "Content-Type: Text/Plain; charset=""UTF-8""" & CRLF
         & "Connection: close" & CRLF & CRLF);
      declare
         Client : aliased HTTP_Server.Connection (Wire'Access);
      begin
         Routes.Serve (State, Client, Peer);
      end;
      declare
         Output : constant String := To_String (Wire.Output);
      begin
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "201 Created") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "X-Helper: yes") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Output,
               "Set-Cookie: result=ok; Path=/; Secure; HttpOnly; " &
               "SameSite=Lax") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "built") /= 0);
      end;
   end Check_Request_Response_Helpers;

   procedure Check_Bounded_Channels is
      package Channels is new Flyology.Bounded_Channels (Integer, 0);
      Item : Channels.Channel (Capacity => 1);
      Value : Integer;
      Available : Boolean;
      Accepted  : Boolean;
      Timed_Out : Boolean;
   begin
      Item.Try_Send (1, Accepted);
      pragma Assert (Accepted);
      Item.Try_Send (2, Accepted);
      pragma Assert (not Accepted);
      Item.Send_For (2, Accepted, 0.0, Timed_Out);
      pragma Assert (not Accepted and Timed_Out);
      Item.Receive (Value, Available);
      pragma Assert (Available and then Value = 1);
      Item.Send (2, Accepted);
      pragma Assert (Accepted and then Item.Length = 1);
      Item.Close;
      Item.Receive (Value, Available);
      pragma Assert (Available and then Value = 2);
      Item.Receive (Value, Available);
      pragma Assert (not Available and then Item.Is_Closed);
      Item.Receive_For (Value, Available, 0.0, Timed_Out);
      pragma Assert (not Available and then not Timed_Out);
      Item.Try_Send (3, Accepted);
      pragma Assert (not Accepted);
   end Check_Bounded_Channels;

   procedure Check_Outbound_Budgets is
      package SSE renames Flyology.HTTP.Server.SSE_Handlers;
      package WS renames Flyology.HTTP.Server.WebSocket_Handlers;
      Budget : aliased HTTP_Server.Outbound_Budget (Limit => 6);
      Accepted : Boolean;
   begin
      declare
         Item : SSE.Session
           (Capacity => 4, Byte_Limit => 5, Budget => Budget'Access);
         Event : SSE.Event_Value;
      begin
         Event.Data := To_Unbounded_String ("12345");
         SSE.Try_Publish (Item, Event, Accepted);
         pragma Assert (Accepted);
         Event.Data := To_Unbounded_String ("x");
         SSE.Try_Publish (Item, Event, Accepted);
         pragma Assert (not Accepted);
         pragma Assert (HTTP_Server.Current (Budget).Current = 5);
      end;
      pragma Assert (HTTP_Server.Current (Budget).Current = 0);
      declare
         Item : WS.Session
           (Capacity => 4, Byte_Limit => 6, Budget => Budget'Access,
            Buffer_Pool => null);
         Other : WS.Session
           (Capacity => 1, Byte_Limit => 6, Budget => Budget'Access,
            Buffer_Pool => null);
         Message : WS.Outgoing_Message;
      begin
         Message.Data := Bytes.From_Byte_String ("123456");
         WS.Try_Publish (Item, Message, Accepted);
         pragma Assert (Accepted);
         Message.Data := Bytes.From_Byte_String ("x");
         WS.Try_Publish (Other, Message, Accepted);
         pragma Assert (not Accepted);
         pragma Assert (HTTP_Server.Current (Budget).Current = 6);
      end;
      pragma Assert (HTTP_Server.Current (Budget).Current = 0);
      pragma Assert (HTTP_Server.Current (Budget).Denials = 1);
   end Check_Outbound_Budgets;

   procedure Check_High_Level_SSE is
      package Applications renames Flyology.HTTP.Server.Applications;
      package Routing is new Flyology.HTTP.Server.Routing (Boolean);
      package SSE renames Flyology.HTTP.Server.SSE_Handlers;

      Metrics : aliased Flyology.HTTP.Server.Metrics.In_Memory (4);

      procedure Events
        (State : in out Boolean;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
         Item     : SSE.Session
           (Capacity => 1, Byte_Limit => 1_024, Budget => null);
         Event    : SSE.Event_Value;
         Accepted : Boolean;
         Timed_Out : Boolean;
         Stop : aliased Flyology.Cancellation.Token;
         Cancelled : Boolean := False;
      begin
         Event.Data := To_Unbounded_String ("first");
         Event.Event := To_Unbounded_String ("update");
         SSE.Try_Publish (Item, Event, Accepted);
         pragma Assert (Accepted);
         Event.Data := To_Unbounded_String ("overflow");
         SSE.Try_Publish (Item, Event, Accepted);
         pragma Assert (not Accepted);
         SSE.Publish_For
           (Item, Event, Accepted, Timeout => 0.0,
            Timed_Out => Timed_Out);
         pragma Assert (not Accepted and then Timed_Out);
         Stop.Request;
         begin
            SSE.Publish_For
              (Item, Event, Accepted, Timeout => 1.0,
               Timed_Out => Timed_Out, Token => Stop'Access);
         exception
            when Flyology.Cancellation.Operation_Cancelled =>
               Cancelled := True;
         end;
         pragma Assert (Cancelled);
         Event.Data := To_Unbounded_String
           (String'(1 .. SSE.Max_Queued_Message_Bytes + 1 => 'x'));
         SSE.Try_Publish (Item, Event, Accepted);
         pragma Assert (not Accepted);
         SSE.Close (Item);
         SSE.Run (X, Item, Metrics'Access);
      end Events;

      Routes : Routing.Router
        (Capacity => 1, Slashes => Routing.Strict_Slashes);
      State  : Boolean := False;
      Peer   : constant Sockets.Endpoint := Test_Peer;
      Wire : aliased Memory_Transport;
   begin
      Routing.Get
        (Routes,
         "/events", Events'Access, Name => "events",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Upgrade => Routing.Allow_SSE));
      Wire.Input := To_Unbounded_String
        ("GET /events HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF & "Connection: close" & CRLF & CRLF);
      declare
         Client : aliased HTTP_Server.Connection (Wire'Access);
      begin
         Routing.Serve (Routes, State, Client, Peer);
      end;
      declare
         Output : constant String := To_String (Wire.Output);
         Values : constant Flyology.HTTP.Server.Metrics.Snapshot :=
           Metrics.Read;
      begin
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "text/event-stream") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "event: update") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "data: first") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "overflow") = 0);
         pragma Assert
           (Values.Events
              (Flyology.HTTP.Server.Metrics.SSE_Connection) = 1);
      end;
      declare
         Head_Wire : aliased Memory_Transport;
      begin
         Head_Wire.Input := To_Unbounded_String
           ("HEAD /events HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Connection: close" & CRLF & CRLF);
         declare
            Client : aliased HTTP_Server.Connection (Head_Wire'Access);
         begin
            Routing.Serve (Routes, State, Client, Peer);
         end;
         pragma Assert
           (Ada.Strings.Fixed.Index
              (To_String (Head_Wire.Output), "405 Method Not Allowed") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (To_String (Head_Wire.Output), "Allow: GET") /= 0);
      end;
   end Check_High_Level_SSE;

   procedure Check_Idle_SSE_Deadline is
      package Applications renames Flyology.HTTP.Server.Applications;
      package Routing is new Flyology.HTTP.Server.Routing (Boolean);
      package SSE renames Flyology.HTTP.Server.SSE_Handlers;

      procedure Events
        (Cancelled : in out Boolean;
         X         : in out Applications.Exchange)
      is
         Item : SSE.Session
           (Capacity => 1, Byte_Limit => 1_024, Budget => null);
      begin
         begin
            SSE.Run
              (X, Item, Idle_Quantum => 0.001, Heartbeat => 0.0);
         exception
            when others =>
               Cancelled := SSE.Cancelled (Item);
         end;
      end Events;

      Routes : Routing.Router
        (Capacity => 1, Slashes => Routing.Strict_Slashes);
      Cancelled : Boolean := False;
      Peer : constant Sockets.Endpoint := Test_Peer;
      Wire : aliased Memory_Transport;
   begin
      Routes.Get
        ("/idle", Events'Access, Name => "idle",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Timeout => 0.01, Upgrade => Routing.Allow_SSE));
      Wire.Input := To_Unbounded_String
        ("GET /idle HTTP/1.1" & CRLF & "Host: localhost" & CRLF
         & "Connection: close" & CRLF & CRLF);
      declare
         Client : aliased HTTP_Server.Connection (Wire'Access);
      begin
         Routing.Serve (Routes, Cancelled, Client, Peer);
      end;
      pragma Assert (Cancelled, To_String (Wire.Output));
   end Check_Idle_SSE_Deadline;

   procedure Check_High_Level_WebSocket is
      package Applications renames Flyology.HTTP.Server.Applications;
      package Routing is new Flyology.HTTP.Server.Routing (Boolean);
      package WebSockets renames
        Flyology.HTTP.Server.WebSocket_Handlers;

      Metrics : aliased Flyology.HTTP.Server.Metrics.In_Memory (4);
      Close_Calls : Natural := 0;

      function Frame (Opcode : Natural; Payload : String) return String is
         Mask : constant String := "mask";
         Result : Unbounded_String;
      begin
         Append (Result, Character'Val (16#80# + Opcode));
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

      procedure On_Open
        (X    : in out Applications.Exchange;
         Item : in out WebSockets.Session)
      is
         pragma Unreferenced (X);
         Accepted : Boolean;
      begin
         WebSockets.Try_Publish
           (Item,
            (Kind => HTTP_Server.Text_Frame,
             Data => Bytes.From_Byte_String
               (String'
                  (1 .. WebSockets.Max_Queued_Message_Bytes + 1 => 'x'))),
            Accepted);
         pragma Assert (not Accepted);
         WebSockets.Try_Publish
           (Item,
            (Kind => HTTP_Server.Text_Frame,
             Data => Bytes.From_Byte_String ("open")), Accepted);
         pragma Assert (Accepted);
      end On_Open;

      procedure On_Message
        (X    : in out Applications.Exchange;
         Item : in out WebSockets.Session;
         Kind : HTTP_Server.WebSocket_Data_Kind;
         Data : Bytes.Unbounded_Bytes)
      is
         pragma Unreferenced (X);
         Accepted : Boolean;
      begin
         WebSockets.Try_Publish
           (Item,
            (Kind => Kind,
             Data => Bytes.From_Byte_String
               ("echo:" & Bytes.To_Byte_String (Data))),
            Accepted);
         pragma Assert (Accepted);
      end On_Message;

      procedure On_Close
        (X    : in out Applications.Exchange;
         Item : in out WebSockets.Session)
      is
         pragma Unreferenced (X, Item);
      begin
         Close_Calls := Close_Calls + 1;
      end On_Close;

      procedure Chat
        (State : in out Boolean;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
         Item : WebSockets.Session
           (Capacity => 2, Byte_Limit => 1_024, Budget => null,
            Buffer_Pool => null);
         package Chat_Lifecycle is new
           WebSockets.Lifecycle (On_Open, On_Message, On_Close);
      begin
         Chat_Lifecycle.Run (X, Item, Metric_Output => Metrics'Access);
      end Chat;

      Routes : Routing.Router
        (Capacity => 1, Slashes => Routing.Strict_Slashes);
      State  : Boolean := False;
      Peer   : constant Sockets.Endpoint := Test_Peer;
      Wire : aliased Memory_Transport;
   begin
      Routing.Get
        (Routes,
         "/chat", Chat'Access, Name => "chat",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Upgrade => Routing.Allow_WebSocket));
      Wire.Input := To_Unbounded_String
        ("GET /chat HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF
         & "Upgrade: websocket" & CRLF
         & "Connection: Upgrade" & CRLF
         & "Sec-WebSocket-Version: 13" & CRLF
         & "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" & CRLF & CRLF
         & Frame (1, "hi") & Frame (8, ""));
      declare
         Client : aliased HTTP_Server.Connection (Wire'Access);
      begin
         Routing.Serve (Routes, State, Client, Peer);
      end;
      declare
         Output : constant String := To_String (Wire.Output);
         Values : constant Flyology.HTTP.Server.Metrics.Snapshot :=
           Metrics.Read;
      begin
         pragma Assert
           (Ada.Strings.Fixed.Index (Output, "101 Switching Protocols") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Output, Character'Val (16#81#) & Character'Val (4) & "open")
            /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Output,
               Character'Val (16#81#) & Character'Val (7) & "echo:hi") /= 0);
         pragma Assert (Close_Calls = 1);
         pragma Assert
           (Values.Events
              (Flyology.HTTP.Server.Metrics.WebSocket_Connection) = 1);
         pragma Assert
           (Values.Events
              (Flyology.HTTP.Server.Metrics.WebSocket_Message) = 3);
      end;
      declare
         Version_Wire : aliased Memory_Transport;
      begin
         Version_Wire.Input := To_Unbounded_String
           ("GET /chat HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Upgrade: websocket" & CRLF
            & "Connection: Upgrade" & CRLF
            & "Sec-WebSocket-Version: 12" & CRLF
            & "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" & CRLF
            & "Connection: close" & CRLF & CRLF);
         declare
            Client : aliased HTTP_Server.Connection (Version_Wire'Access);
         begin
            Routing.Serve (Routes, State, Client, Peer);
         end;
         pragma Assert
           (Ada.Strings.Fixed.Index
              (To_String (Version_Wire.Output),
               "426 Upgrade Required") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (To_String (Version_Wire.Output),
               "Sec-WebSocket-Version: 13") /= 0);
      end;
   end Check_High_Level_WebSocket;

   procedure Check_Fragmented_WebSocket_Timeout is
      function Frame
        (Final : Boolean; Opcode : Natural; Payload : String) return String
      is
         Mask : constant String := "mask";
         Value : Unbounded_String;
      begin
         Append
           (Value,
            Character'Val ((if Final then 16#80# else 0) + Opcode));
         Append (Value, Character'Val (16#80# + Payload'Length));
         Append (Value, Mask);
         for Index in Payload'Range loop
            Append
              (Value,
               Character'Val
                 (Natural
                    (Ada.Streams.Stream_Element
                       (Character'Pos (Payload (Index)))
                     xor Ada.Streams.Stream_Element
                       (Character'Pos
                          (Mask ((Index - Payload'First) mod 4 + 1))))));
         end loop;
         return To_String (Value);
      end Frame;

      Head : constant String :=
        "GET /chat HTTP/1.1" & CRLF
        & "Host: localhost" & CRLF
        & "Upgrade: websocket" & CRLF
        & "Connection: Upgrade" & CRLF
        & "Sec-WebSocket-Version: 13" & CRLF
        & "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" & CRLF & CRLF;
      First : constant String := Frame (False, 1, "hel");
      Last  : constant String := Frame (True, 0, "lo");
      Wire  : aliased Memory_Transport;
      Value : HTTP_Server.Request;
      Closed : Boolean;
      Timed_Out : Boolean := False;
      Kind : HTTP_Server.WebSocket_Data_Kind;
      Data : Bytes.Unbounded_Bytes;
      Budget : aliased HTTP_Server.Ingress_Budget (Limit => 100);
   begin
      Wire.Input := To_Unbounded_String (Head & First & Last);
      Wire.First_Receive_Max := Head'Length + First'Length;
      Wire.Timeout_On_Call := 2;
      declare
         Client : HTTP_Server.Connection (Wire'Access);
      begin
         HTTP_Server.Configure_Ingress_Budget (Client, Budget'Access);
         HTTP_Server.Read_Request_Head
           (Client, Value, Closed, Timeout => 1.0);
         pragma Assert (not Closed);
         HTTP_Server.Accept_WebSocket (Client, Value, Timeout => 1.0);
         begin
            HTTP_Server.Receive_WebSocket
              (Client, Kind, Data, Closed, Timeout => 0.001,
               Message_Timeout => 1.0);
         exception
            when Flyology.IO.Timeout_Error => Timed_Out := True;
         end;
         pragma Assert (Timed_Out);
         pragma Assert (HTTP_Server.Current (Budget).Current = 3);
         HTTP_Server.Receive_WebSocket
           (Client, Kind, Data, Closed, Timeout => 1.0,
            Message_Timeout => 1.0);
         pragma Assert (not Closed);
         pragma Assert (Kind = HTTP_Server.Text_Frame);
         pragma Assert (Bytes.To_Byte_String (Data) = "hello");
         pragma Assert (HTTP_Server.Current (Budget).Current = 0);
         HTTP_Server.Close_WebSocket (Client, Timeout => 1.0);
      end;
   end Check_Fragmented_WebSocket_Timeout;

   procedure Check_Request_Task_Integration is
      package Applications renames Flyology.HTTP.Server.Applications;

      procedure Double
        (Input    : Integer;
         Token    : access Flyology.Cancellation.Token;
         Deadline : Ada.Real_Time.Time;
         Result   : out Integer)
      is
         use type Ada.Real_Time.Time;
      begin
         pragma Assert (Token /= null);
         pragma Assert (Deadline /= Ada.Real_Time.Time_Last);
         Result := Input * 2;
      end Double;

      package Request_Work is new
        Flyology.HTTP.Server.Request_Tasks (Integer, Integer, Double);
      package Operations renames Request_Work.Operations;
      package Routing is new Flyology.HTTP.Server.Routing (Boolean);

      procedure Parallel
        (State : in out Boolean;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
         Item : Operations.Scope
           (Capacity => 2, Parent => X.Cancellation);
         First, Second : Operations.Operation_Handle;
      begin
         Request_Work.Configure (Item, X);
         Operations.Spawn (Item, 20, First);
         Operations.Spawn (Item, 1, Second);
         Operations.Join (Item);
         X.Text
           (200, Integer'Image (Operations.Result (Item, First)
                                + Operations.Result (Item, Second)));
      end Parallel;

      Routes : Routing.Router
        (Capacity => 1, Slashes => Routing.Strict_Slashes);
      State : Boolean := False;
      Peer  : constant Sockets.Endpoint := Test_Peer;
      Wire : aliased Memory_Transport;
   begin
      Routing.Get
        (Routes, "/parallel", Parallel'Access, Name => "parallel");
      Wire.Input := To_Unbounded_String
        ("GET /parallel HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF & "Connection: close" & CRLF & CRLF);
      declare
         Client : aliased HTTP_Server.Connection (Wire'Access);
      begin
         Routing.Serve (Routes, State, Client, Peer);
      end;
      pragma Assert
        (Ada.Strings.Fixed.Index (To_String (Wire.Output), " 42") /= 0);
   end Check_Request_Task_Integration;

   procedure Check_Native_Route_Integration is
      package Applications renames Flyology.HTTP.Server.Applications;

      Native_Failure : exception;
      type Work_Input is record
         Value : Integer := 0;
      end record;

      protected Trace is
         procedure Prepared;
         procedure Executed;
         procedure Rendered;
         procedure Release;
         entry Await_Release;
         function Ownership_Preserved return Boolean;
         function Worker_Was_Native return Boolean;
      private
         Prepare_Task : Ada.Task_Identification.Task_Id :=
           Ada.Task_Identification.Null_Task_Id;
         Execute_Task : Ada.Task_Identification.Task_Id :=
           Ada.Task_Identification.Null_Task_Id;
         Render_Task : Ada.Task_Identification.Task_Id :=
           Ada.Task_Identification.Null_Task_Id;
         Native_Worker : Boolean := False;
         Released : Boolean := False;
      end Trace;

      protected body Trace is
         procedure Prepared is
         begin
            Prepare_Task := Ada.Task_Identification.Current_Task;
         end Prepared;

         procedure Executed is
         begin
            Execute_Task := Ada.Task_Identification.Current_Task;
            Native_Worker := not Flyology.IO.Is_Lightweight_Task;
         end Executed;

         procedure Rendered is
         begin
            Render_Task := Ada.Task_Identification.Current_Task;
         end Rendered;

         procedure Release is
         begin
            Released := True;
         end Release;

         entry Await_Release when Released is
         begin
            null;
         end Await_Release;

         function Ownership_Preserved return Boolean is
           (Prepare_Task /= Ada.Task_Identification.Null_Task_Id
            and then Prepare_Task = Render_Task
            and then Prepare_Task /= Execute_Task);

         function Worker_Was_Native return Boolean is (Native_Worker);
      end Trace;

      procedure Execute
        (Input    : Work_Input;
         Token    : access Flyology.Cancellation.Token;
         Deadline : Ada.Real_Time.Time;
         Result   : out Integer)
      is
         pragma Unreferenced (Deadline);
      begin
         Trace.Executed;
         if Input.Value = -1 then
            raise Native_Failure with "mapped native failure";
         elsif Input.Value = 0 then
            Trace.Await_Release;
         end if;
         if Token.Requested then
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
         Result := Input.Value * Input.Value + 17;
      end Execute;

      package Native_Work is new Flyology.Native_Executors
        (Work_Input, Integer, Execute);
      Pool : aliased Native_Work.Executor (Workers => 1, Capacity => 1);

      type Context is record
         Prepare_Calls : Natural := 0;
         Render_Calls  : Natural := 0;
      end record;

      package Routing is new Flyology.HTTP.Server.Routing (Context);

      procedure Prepare
        (State : in out Context;
         X     : in out Applications.Exchange;
         Input : out Work_Input)
      is
      begin
         State.Prepare_Calls := State.Prepare_Calls + 1;
         Trace.Prepared;
         Input.Value := Integer'Value (X.Parameter ("value"));
      end Prepare;

      procedure Render
        (State  : in out Context;
         X      : in out Applications.Exchange;
         Result : Integer)
      is
      begin
         State.Render_Calls := State.Render_Calls + 1;
         Trace.Rendered;
         X.Text (200, Integer'Image (Result));
      end Render;

      package Native_Route is new Flyology.HTTP.Server.Native_Routes
        (App_Context => Context,
         Input_Type  => Work_Input,
         Result_Type => Integer,
         Operations  => Native_Work,
         Executor    => Pool'Access,
         Prepare     => Prepare,
         Render      => Render);

      procedure Inline
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         Input : Work_Input;
         Result : Integer;
      begin
         State.Prepare_Calls := State.Prepare_Calls + 1;
         Input.Value := Integer'Value (X.Parameter ("value"));
         Result := Input.Value * Input.Value + 17;
         State.Render_Calls := State.Render_Calls + 1;
         X.Text (200, Integer'Image (Result));
      end Inline;

      procedure Map
        (State   : in out Context;
         X       : in out Applications.Exchange;
         Error   : Ada.Exceptions.Exception_Occurrence;
         Handled : in out Boolean)
      is
         pragma Unreferenced (State);
      begin
         if Ada.Exceptions.Exception_Identity (Error) =
           Native_Failure'Identity
         then
            X.Problem (409, "native-mapped", "Mapped native failure");
            Handled := True;
         end if;
      end Map;

      package Errors is new Flyology.HTTP.Server.Middleware_Errors
        (Context, Routing.Components, Map => Map);

      Routes : Routing.Router
        (Capacity => 2, Slashes => Routing.Strict_Slashes);
      State : Context;
      Peer  : constant Sockets.Endpoint := Test_Peer;

      function Run (Path : String) return String is
         Wire : aliased Memory_Transport;
      begin
         Wire.Input := To_Unbounded_String
           ("GET " & Path & " HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Connection: close" & CRLF & CRLF);
         declare
            Client : aliased HTTP_Server.Connection (Wire'Access);
         begin
            Routes.Serve (State, Client, Peer);
         end;
         return To_String (Wire.Output);
      end Run;

      function Response_Body (Response : String) return String is
         Boundary : constant Natural :=
           Ada.Strings.Fixed.Index (Response, CRLF & CRLF);
      begin
         pragma Assert (Boundary > 0);
         return Response (Boundary + 4 .. Response'Last);
      end Response_Body;
   begin
      Native_Work.Start (Pool);
      Routes.Get
        ("/native/{value}", Native_Route.Handle'Access, Name => "native");
      Routes.Get ("/inline/{value}", Inline'Access, Name => "inline");
      Routes.Add_Middleware (Errors.Call'Access);

      declare
         Native_Response : constant String := Run ("/native/7");
         Inline_Response : constant String := Run ("/inline/7");
      begin
         pragma Assert
           (Response_Body (Native_Response) =
              Response_Body (Inline_Response));
         pragma Assert (Trace.Ownership_Preserved);
         pragma Assert (Trace.Worker_Was_Native);
      end;

      declare
         Occupied : Native_Work.Operation_Handle (Pool'Access);
         Accepted : Boolean;
         Value    : Integer;
      begin
         Native_Work.Submit
           (Pool, (Value => 0), null, Ada.Real_Time.Time_Last,
            Occupied, Accepted);
         pragma Assert (Accepted);
         declare
            Response : constant String := Run ("/native/8");
         begin
            pragma Assert
              (Ada.Strings.Fixed.Index
                 (Response, "503 Service Unavailable") /= 0);
            pragma Assert
              (Ada.Strings.Fixed.Index
                 (Response, "native-executor-full") /= 0);
         end;
         Trace.Release;
         Native_Work.Await (Pool, Occupied, Value);
      end;

      declare
         Response : constant String := Run ("/native/-1");
      begin
         pragma Assert
           (Ada.Strings.Fixed.Index (Response, "409 Conflict") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index (Response, "native-mapped") /= 0);
      end;
      Native_Work.Shutdown (Pool);
   end Check_Native_Route_Integration;

begin
   Check_HTTP;
   Check_Chunked_And_Expect;
   Check_Streaming_Body;
   Check_Ingress_Budget;
   Check_Response_Framing;
   Check_SSE;
   Check_WebSocket;
   Check_WebSocket_Binary_Bytes;
   Check_Idle_WebSocket_Budget;
   Check_Periodic_WebSocket_Pings;
   Check_WebSocket_Control_Write_Timeout;
   Check_WebSocket_Data_Write_Timeout;
   Check_WebSocket_Failures;
   Check_WebSocket_Origin;
   Check_Slow_Request_Deadline;
   Check_Slow_Body_Deadline;
   Check_Separate_Header_Deadline;
   Check_Handler_Isolation;
   Check_Handler_Streamed_Limit;
   Check_Application_Failure_Propagates;
   Check_Handler_Limits;
   Check_Rejections;
   Check_Applications_And_Routing;
   Check_Middleware;
   Check_Standard_Middleware;
   Check_Admission_Middleware;
   Check_Request_Response_Helpers;
   Check_Bounded_Channels;
   Check_Outbound_Budgets;
   Check_High_Level_SSE;
   Check_Idle_SSE_Deadline;
   Check_High_Level_WebSocket;
   Check_Fragmented_WebSocket_Timeout;
   Check_Request_Task_Integration;
   Check_Native_Route_Integration;
end HTTP_Smoke;
