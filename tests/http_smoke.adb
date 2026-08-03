with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Server;
with Flyology.IO;

procedure HTTP_Smoke is
   package HTTP_Server renames Flyology.HTTP.Server;

   use Ada.Strings.Unbounded;
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
           (Result (Result'Last - 6 .. Result'Last) =
              CRLF & "0" & CRLF & CRLF);
      end;
   end Check_SSE;

   procedure Check_WebSocket is
      Wire : aliased Memory_Transport;
      Mask : constant String :=
        Character'Val (16#37#) & Character'Val (16#FA#)
        & Character'Val (16#21#) & Character'Val (16#3D#);
      Masked_Hi : constant String :=
        Character'Val (16#7F#) & Character'Val (16#93#);
   begin
      Wire.Input := To_Unbounded_String
        ("GET /chat HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF
         & "Upgrade: websocket" & CRLF
         & "Connection: Upgrade" & CRLF
         & "Sec-WebSocket-Version: 13" & CRLF
         & "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" & CRLF & CRLF
         & Character'Val (16#81#) & Character'Val (16#82#)
         & Mask & Masked_Hi);
      declare
         Client : HTTP_Server.Connection (Wire'Access);
         Request : HTTP_Server.Request;
         Message : Unbounded_String;
         Kind : HTTP_Server.WebSocket_Data_Kind;
         Closed : Boolean;
      begin
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
      pragma Assert (Is_Rejected (Oversized_Header));
   end Check_Rejections;

begin
   Check_HTTP;
   Check_SSE;
   Check_WebSocket;
   Check_Slow_Request_Deadline;
   Check_Slow_Body_Deadline;
   Check_Rejections;
end HTTP_Smoke;
