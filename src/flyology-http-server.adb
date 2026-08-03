with Ada.Characters.Handling;
with Ada.Real_Time;
with Ada.Strings.Fixed;
with Interfaces;

package body Flyology.HTTP.Server is
   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Real_Time.Time;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   CRLF : constant String := Character'Val (13) & Character'Val (10);

   function Bytes (Text : String) return Ada.Streams.Stream_Element_Array is
      Result : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Text'Length));
   begin
      for Index in Text'Range loop
         Result
           (Ada.Streams.Stream_Element_Offset (Index - Text'First + 1)) :=
             Ada.Streams.Stream_Element (Character'Pos (Text (Index)));
      end loop;
      return Result;
   end Bytes;

   function Text
     (Data : Ada.Streams.Stream_Element_Array) return String
   is
      Result : String (1 .. Natural (Data'Length));
      Cursor : Positive := Result'First;
   begin
      for Value of Data loop
         Result (Cursor) := Character'Val (Value);
         Cursor := Cursor + 1;
      end loop;
      return Result;
   end Text;

   function Lower (Value : String) return String is
     (Ada.Characters.Handling.To_Lower (Value));

   function Trim (Value : String) return String is
      First : Integer := Value'First;
      Last  : Integer := Value'Last;
   begin
      while First <= Last and then Value (First) in ' ' | Character'Val (9)
      loop
         First := First + 1;
      end loop;
      while Last >= First and then Value (Last) in ' ' | Character'Val (9)
      loop
         Last := Last - 1;
      end loop;
      return (if First > Last then "" else Value (First .. Last));
   end Trim;

   function Is_Token_Character (Value : Character) return Boolean is
     (Value in 'a' .. 'z'
        or else Value in 'A' .. 'Z'
        or else Value in '0' .. '9'
        or else Value in '!' | '#' | '$' | '%' | '&' | ''' | '*'
                     | '+' | '-' | '.' | '^' | '_' | '`' | '|' | '~');

   procedure Validate_Token (Value : String; Description : String) is
   begin
      if Value'Length = 0 then
         raise Protocol_Error with Description & " is empty";
      end if;
      for Item of Value loop
         if not Is_Token_Character (Item) then
            raise Protocol_Error with "invalid " & Description;
         end if;
      end loop;
   end Validate_Token;

   function Method (Item : Request) return String is
     (To_String (Item.Method_Value));

   function Target (Item : Request) return String is
     (To_String (Item.Target_Value));

   function Version (Item : Request) return HTTP_Version is
     (Item.Version_Value);

   function Header_Field_Count
     (Item : Request; Name : String) return Natural
   is
      Block  : constant String := To_String (Item.Header_Block);
      Wanted : constant String := Lower (Name);
      Result : Natural := 0;
      First  : Positive := 1;
   begin
      Validate_Token (Name, "header name");
      while First <= Block'Length loop
         declare
            Relative_Last : constant Natural :=
              Ada.Strings.Fixed.Index (Block (First .. Block'Last), CRLF);
            Last : constant Natural :=
              (if Relative_Last = 0 then Block'Last else Relative_Last - 1);
            Line : constant String := Block (First .. Last);
            Colon : constant Natural := Ada.Strings.Fixed.Index (Line, ":");
         begin
            if Colon > Line'First
              and then Lower (Line (Line'First .. Colon - 1)) = Wanted
            then
               Result := Result + 1;
            end if;
            exit when Relative_Last = 0;
            First := Relative_Last + CRLF'Length;
         end;
      end loop;
      return Result;
   end Header_Field_Count;

   function Header (Item : Request; Name : String) return String is
      Block  : constant String := To_String (Item.Header_Block);
      Wanted : constant String := Lower (Name);
      Result : Unbounded_String;
      First  : Positive := 1;
   begin
      Validate_Token (Name, "header name");
      while First <= Block'Length loop
         declare
            Relative_Last : constant Natural :=
              Ada.Strings.Fixed.Index (Block (First .. Block'Last), CRLF);
            Last : constant Natural :=
              (if Relative_Last = 0 then Block'Last else Relative_Last - 1);
            Line : constant String := Block (First .. Last);
            Colon : constant Natural := Ada.Strings.Fixed.Index (Line, ":");
         begin
            if Colon > Line'First
              and then Lower (Line (Line'First .. Colon - 1)) = Wanted
            then
               if Length (Result) > 0 then
                  Append (Result, ", ");
               end if;
               Append (Result, Trim (Line (Colon + 1 .. Line'Last)));
            end if;
            exit when Relative_Last = 0;
            First := Relative_Last + CRLF'Length;
         end;
      end loop;
      return To_String (Result);
   end Header;

   function Header_Has_Token
     (Item : Request; Name : String; Value : String) return Boolean
   is
      List  : constant String := Header (Item, Name);
      Match : constant String := Lower (Value);
      First : Positive := 1;
   begin
      Validate_Token (Value, "header token");
      while First <= List'Length loop
         declare
            Comma : constant Natural :=
              Ada.Strings.Fixed.Index (List (First .. List'Last), ",");
            Last : constant Natural :=
              (if Comma = 0 then List'Last else Comma - 1);
         begin
            if Lower (Trim (List (First .. Last))) = Match then
               return True;
            end if;
            exit when Comma = 0;
            First := Comma + 1;
         end;
      end loop;
      return False;
   end Header_Has_Token;

   function Content (Item : Request) return String is
     (To_String (Item.Body_Value));

   procedure Receive_More
     (Item    : in out Connection;
      Closed  : out Boolean;
      Started : Ada.Real_Time.Time;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token;
      Maximum : Natural := Natural'Last)
   is
      Current : constant Natural := Length (Item.Pending);
      Room    : constant Natural :=
        (if Current >= Maximum then 0 else Maximum - Current);
      Chunk   : constant Natural := Natural'Min (8 * 1_024, Room);
      Elapsed : constant Duration :=
        Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
      Left : constant Duration :=
        (if Timeout < 0.0 then -1.0
         elsif Elapsed >= Timeout then 0.0
         else Timeout - Elapsed);
   begin
      if Chunk = 0 then
         raise Protocol_Error with "HTTP protocol buffer limit exceeded";
      end if;
      declare
         Buffer : Ada.Streams.Stream_Element_Array
           (1 .. Ada.Streams.Stream_Element_Offset (Chunk));
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Item.Channel.Receive (Buffer, Last, Left, Token);
         Closed := Last < Buffer'First;
         if not Closed then
            Append (Item.Pending, Text (Buffer (Buffer'First .. Last)));
         end if;
      end;
   end Receive_More;

   procedure Consume (Item : in out Connection; Count : Natural) is
      Value : constant String := To_String (Item.Pending);
   begin
      if Count >= Value'Length then
         Item.Pending := Null_Unbounded_String;
      else
         Item.Pending := To_Unbounded_String
           (Value (Value'First + Count .. Value'Last));
      end if;
   end Consume;

   procedure Validate_Header_Block (Block : String) is
      First : Positive := Block'First;
   begin
      while First <= Block'Last loop
         declare
            Marker : constant Natural :=
              Ada.Strings.Fixed.Index (Block (First .. Block'Last), CRLF);
            Last : constant Natural :=
              (if Marker = 0 then Block'Last else Marker - 1);
            Line : constant String := Block (First .. Last);
            Colon : constant Natural := Ada.Strings.Fixed.Index (Line, ":");
         begin
            if Line'Length = 0
              or else Line (Line'First) in ' ' | Character'Val (9)
              or else Colon <= Line'First
            then
               raise Protocol_Error with "malformed HTTP header field";
            end if;
            Validate_Token (Line (Line'First .. Colon - 1), "header name");
            for Index in Colon + 1 .. Line'Last loop
               if Character'Pos (Line (Index)) < 32
                 and then Line (Index) /= Character'Val (9)
               then
                  raise Protocol_Error with "control byte in HTTP header";
               elsif Character'Pos (Line (Index)) = 127
               then
                  raise Protocol_Error with "control byte in HTTP header";
               end if;
            end loop;
            exit when Marker = 0;
            First := Marker + CRLF'Length;
         end;
      end loop;
   end Validate_Header_Block;

   procedure Read_Request
     (Item        : in out Connection;
      Value       : out Request;
      Peer_Closed : out Boolean;
      Timeout     : Duration := 30.0;
      Token       : access Flyology.Cancellation.Token := null)
   is
      Header_End : Natural := 0;
      Closed     : Boolean;
      Body_Size  : Natural := 0;
      Started    : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   begin
      if Item.State /= Reading_HTTP then
         raise Program_Error with "HTTP connection is not reading requests";
      end if;
      Item.Response_Begun := False;
      Peer_Closed := False;

      loop
         declare
            Available : constant String := To_String (Item.Pending);
         begin
            Header_End := Ada.Strings.Fixed.Index (Available, CRLF & CRLF);
            exit when Header_End /= 0;
            if Available'Length > Max_Header_Bytes then
               raise Protocol_Error with "HTTP request headers are too large";
            end if;
         end;
         Receive_More
           (Item, Closed, Started, Timeout, Token,
            Maximum => Max_Header_Bytes + 4);
         if Closed then
            if Length (Item.Pending) = 0 then
               Peer_Closed := True;
               Item.State := Terminal;
               return;
            end if;
            raise Protocol_Error with "peer closed inside HTTP headers";
         end if;
      end loop;

      if Header_End - 1 > Max_Header_Bytes then
         raise Protocol_Error with "HTTP request headers are too large";
      end if;

      declare
         Available : constant String := To_String (Item.Pending);
         Head      : constant String := Available (1 .. Header_End - 1);
         Line_End  : constant Natural := Ada.Strings.Fixed.Index (Head, CRLF);
         Request_Line : constant String :=
           (if Line_End = 0 then Head else Head (Head'First .. Line_End - 1));
         Header_First : constant Natural :=
           (if Line_End = 0 then Head'Last + 1 else Line_End + CRLF'Length);
         First_Space : constant Natural :=
           Ada.Strings.Fixed.Index (Request_Line, " ");
         Second_Space : constant Natural :=
           (if First_Space = 0 or else First_Space = Request_Line'Last
            then 0
            else Ada.Strings.Fixed.Index
              (Request_Line (First_Space + 1 .. Request_Line'Last), " "));
      begin
         if First_Space <= Request_Line'First
           or else Second_Space = 0
           or else Second_Space = First_Space + 1
           or else Second_Space = Request_Line'Last
           or else Ada.Strings.Fixed.Index
             (Request_Line (Second_Space + 1 .. Request_Line'Last), " ") /= 0
         then
            raise Protocol_Error with "malformed HTTP request line";
         end if;
         Validate_Token
           (Request_Line (Request_Line'First .. First_Space - 1),
            "HTTP method");
         Value.Method_Value := To_Unbounded_String
           (Request_Line (Request_Line'First .. First_Space - 1));
         Value.Target_Value := To_Unbounded_String
           (Request_Line (First_Space + 1 .. Second_Space - 1));
         for Item of To_String (Value.Target_Value) loop
            if Character'Pos (Item) <= 32 or else Character'Pos (Item) = 127
            then
               raise Protocol_Error with "control byte in request target";
            end if;
         end loop;
         declare
            Wire_Version : constant String :=
              Request_Line (Second_Space + 1 .. Request_Line'Last);
         begin
            if Wire_Version = "HTTP/1.1" then
               Value.Version_Value := HTTP_1_1;
            elsif Wire_Version = "HTTP/1.0" then
               Value.Version_Value := HTTP_1_0;
            else
               raise Protocol_Error with "unsupported HTTP version";
            end if;
         end;
         Value.Header_Block :=
           (if Header_First > Head'Last
            then Null_Unbounded_String
            else To_Unbounded_String (Head (Header_First .. Head'Last)));
         Validate_Header_Block (To_String (Value.Header_Block));
      end;

      declare
         Host_Count : constant Natural := Header_Field_Count (Value, "Host");
         Host       : constant String := Header (Value, "Host");
      begin
         if Host_Count > 1 then
            raise Protocol_Error with "HTTP request has repeated Host";
         elsif Value.Version_Value = HTTP_1_1
           and then (Host_Count = 0 or else Host = "")
         then
            raise Protocol_Error with "HTTP/1.1 request has no Host header";
         end if;
      end;
      if Header_Field_Count (Value, "Transfer-Encoding") /= 0 then
         raise Protocol_Error with
           "request Transfer-Encoding is not supported";
      end if;

      declare
         Length_Field : constant String := Header (Value, "Content-Length");
         Length_Count : constant Natural :=
           Header_Field_Count (Value, "Content-Length");
      begin
         if Length_Count /= 0 then
            if Length_Count > 1
              or else Ada.Strings.Fixed.Index (Length_Field, ",") /= 0
            then
               raise Protocol_Error with "repeated Content-Length";
            elsif Length_Field = "" then
               raise Protocol_Error with "invalid Content-Length";
            end if;
            for Item of Length_Field loop
               if Item not in '0' .. '9' then
                  raise Protocol_Error with "invalid Content-Length";
               end if;
            end loop;
            begin
               Body_Size := Natural'Value (Length_Field);
            exception
               when Constraint_Error =>
                  raise Protocol_Error with "invalid Content-Length";
            end;
            if Body_Size > Max_Request_Body then
               raise Protocol_Error with "HTTP request body is too large";
            end if;
         end if;
      end;

      while Length (Item.Pending) < Header_End + 3 + Body_Size loop
         Receive_More
           (Item, Closed, Started, Timeout, Token,
            Maximum => Header_End + 3 + Body_Size);
         if Closed then
            raise Protocol_Error with "peer closed inside HTTP request body";
         end if;
      end loop;

      declare
         Available : constant String := To_String (Item.Pending);
         Body_First : constant Natural := Header_End + 4;
      begin
         Value.Body_Value :=
           (if Body_Size = 0
            then Null_Unbounded_String
            else To_Unbounded_String
              (Available (Body_First .. Body_First + Body_Size - 1)));
      end;
      Consume (Item, Header_End + 3 + Body_Size);

      Value.Keep_Alive :=
        (if Value.Version_Value = HTTP_1_1
         then not Header_Has_Token (Value, "Connection", "close")
         else Header_Has_Token (Value, "Connection", "keep-alive"));
      Item.Request_Close := not Value.Keep_Alive;
      Item.Current_Is_Head := Lower (Method (Value)) = "head";
   end Read_Request;

   function Reason (Status : Positive) return String is
   begin
      case Status is
         when 101 => return "Switching Protocols";
         when 200 => return "OK";
         when 201 => return "Created";
         when 202 => return "Accepted";
         when 204 => return "No Content";
         when 400 => return "Bad Request";
         when 401 => return "Unauthorized";
         when 403 => return "Forbidden";
         when 404 => return "Not Found";
         when 405 => return "Method Not Allowed";
         when 408 => return "Request Timeout";
         when 413 => return "Content Too Large";
         when 426 => return "Upgrade Required";
         when 500 => return "Internal Server Error";
         when 501 => return "Not Implemented";
         when 503 => return "Service Unavailable";
         when others => return "Status";
      end case;
   end Reason;

   function Decimal (Value : Natural) return String is
     (Trim (Natural'Image (Value)));

   procedure Validate_Extra_Headers (Value : String) is
      Position : Natural := Value'First;
   begin
      if Value'Length = 0 then
         return;
      end if;
      if Value'Length < 2
        or else Value (Value'Last - 1 .. Value'Last) /= CRLF
        or else Ada.Strings.Fixed.Index (Value, CRLF & CRLF) /= 0
      then
         raise Program_Error with
           "extra HTTP headers must be CRLF-terminated nonempty fields";
      end if;
      while Position <= Value'Last loop
         declare
            Marker : constant Natural :=
              Ada.Strings.Fixed.Index (Value (Position .. Value'Last), CRLF);
            Line_Last : constant Natural := Marker - 1;
            Colon : constant Natural := Ada.Strings.Fixed.Index
              (Value (Position .. Line_Last), ":");
         begin
            if Marker = 0 or else Colon <= Position then
               raise Program_Error with "malformed extra HTTP header";
            end if;
            Validate_Token
              (Value (Position .. Colon - 1), "extra header name");
            declare
               Name : constant String :=
                 Lower (Value (Position .. Colon - 1));
            begin
               if Name in "connection" | "content-length" | "content-type"
                            | "transfer-encoding" | "upgrade"
               then
                  raise Program_Error with
                    "extra HTTP header conflicts with a managed field";
               end if;
            end;
            for Index in Colon + 1 .. Line_Last loop
               if (Character'Pos (Value (Index)) < 32
                   and then Value (Index) /= Character'Val (9))
                 or else Character'Pos (Value (Index)) = 127
               then
                  raise Program_Error with
                    "control byte in extra HTTP header";
               end if;
            end loop;
            Position := Marker + 2;
         end;
      end loop;
   end Validate_Extra_Headers;

   procedure Write
     (Item    : in out Connection;
      Value   : String;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token) is
   begin
      if Value'Length > 0 then
         Item.Channel.Send_All (Bytes (Value), Timeout, Token);
      end if;
   end Write;

   procedure Respond
     (Item          : in out Connection;
      Status        : Positive;
      Content_Type  : String;
      Payload       : String;
      Extra_Headers : String := "";
      Close         : Boolean := False;
      Timeout       : Duration := 30.0;
      Token         : access Flyology.Cancellation.Token := null)
   is
      Must_Close : constant Boolean := Close or else Item.Request_Close;
      Head : Unbounded_String;
   begin
      if Item.State /= Reading_HTTP or else Item.Response_Begun then
         raise Program_Error with "HTTP response already started";
      end if;
      if Status not in 100 .. 999 then
         raise Constraint_Error with "HTTP status must have three digits";
      end if;
      Validate_Extra_Headers (Extra_Headers);
      Append
        (Head,
         "HTTP/1.1 " & Decimal (Status) & " " & Reason (Status) & CRLF);
      Append (Head, "Content-Length: " & Decimal (Payload'Length) & CRLF);
      if Content_Type'Length > 0 then
         for Item of Content_Type loop
            if Character'Pos (Item) < 32 or else Character'Pos (Item) = 127
            then
               raise Program_Error with "invalid HTTP content type";
            end if;
         end loop;
         if Ada.Strings.Fixed.Index (Content_Type, CRLF) /= 0 then
            raise Program_Error with "invalid HTTP content type";
         end if;
         Append (Head, "Content-Type: " & Content_Type & CRLF);
      end if;
      Append (Head, Extra_Headers);
      Append
        (Head,
         "Connection: " & (if Must_Close then "close" else "keep-alive")
         & CRLF & CRLF);
      Write (Item, To_String (Head), Timeout, Token);
      if not Item.Current_Is_Head and then Payload'Length > 0 then
         Write (Item, Payload, Timeout, Token);
      end if;
      Item.Response_Begun := True;
      if Must_Close then
         Item.State := Terminal;
      end if;
   end Respond;

   function Should_Close (Item : Connection) return Boolean is
     (Item.State = Terminal or else Item.Request_Close);

   function Response_Started (Item : Connection) return Boolean is
     (Item.Response_Begun);

   function Hex (Value : Natural) return String is
      Hex_Digits : constant String := "0123456789ABCDEF";
      Buffer : String (1 .. 2 * Natural'Size / 8);
      Cursor : Natural := Buffer'Last;
      Rest   : Natural := Value;
   begin
      loop
         Buffer (Cursor) := Hex_Digits (Rest mod 16 + 1);
         Rest := Rest / 16;
         exit when Rest = 0;
         Cursor := Cursor - 1;
      end loop;
      return Buffer (Cursor .. Buffer'Last);
   end Hex;

   procedure Begin_SSE
     (Item          : in out Connection;
      Extra_Headers : String := "";
      Timeout       : Duration := 30.0;
      Token         : access Flyology.Cancellation.Token := null)
   is
   begin
      if Item.State /= Reading_HTTP or else Item.Response_Begun then
         raise Program_Error with "HTTP response already started";
      end if;
      Validate_Extra_Headers (Extra_Headers);
      Write
        (Item,
         "HTTP/1.1 200 OK" & CRLF
         & "Content-Type: text/event-stream" & CRLF
         & "Cache-Control: no-cache" & CRLF
         & "Transfer-Encoding: chunked" & CRLF
         & Extra_Headers
         & "Connection: "
         & (if Item.Request_Close then "close" else "keep-alive")
         & CRLF & CRLF,
         Timeout, Token);
      Item.Response_Begun := True;
      Item.State := Streaming_SSE;
   end Begin_SSE;

   procedure Validate_SSE_Field (Value : String; Name : String) is
   begin
      if Ada.Strings.Fixed.Index (Value, String'(1 => Character'Val (10))) /= 0
        or else Ada.Strings.Fixed.Index
          (Value, String'(1 => Character'Val (13))) /= 0
      then
         raise Program_Error with Name & " contains a newline";
      end if;
   end Validate_SSE_Field;

   procedure Send_Event
     (Item    : in out Connection;
      Data    : String;
      Event   : String := "";
      Id      : String := "";
      Retry   : Natural := 0;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null)
   is
      Payload : Unbounded_String;
      First   : Integer := Data'First;
   begin
      if Item.State /= Streaming_SSE then
         raise Program_Error with "SSE response is not active";
      end if;
      Validate_SSE_Field (Event, "SSE event name");
      Validate_SSE_Field (Id, "SSE id");
      if Event'Length > 0 then
         Append (Payload, "event: " & Event & Character'Val (10));
      end if;
      if Id'Length > 0 then
         Append (Payload, "id: " & Id & Character'Val (10));
      end if;
      if Retry > 0 then
         Append (Payload, "retry: " & Decimal (Retry) & Character'Val (10));
      end if;
      if Data'Length = 0 then
         Append (Payload, "data:" & Character'Val (10));
      else
         while First <= Data'Last loop
            declare
               LF : constant Natural := Ada.Strings.Fixed.Index
                 (Data (First .. Data'Last), String'(1 => Character'Val (10)));
               Last : Integer := (if LF = 0 then Data'Last else LF - 1);
            begin
               if Last >= First and then Data (Last) = Character'Val (13) then
                  Last := Last - 1;
               end if;
               Append (Payload, "data:");
               if Last >= First then
                  Append (Payload, " " & Data (First .. Last));
               end if;
               Append (Payload, Character'Val (10));
               exit when LF = 0;
               First := LF + 1;
               if First > Data'Last then
                  Append (Payload, "data:" & Character'Val (10));
               end if;
            end;
         end loop;
      end if;
      Append (Payload, Character'Val (10));
      declare
         Value : constant String := To_String (Payload);
      begin
         Write
           (Item, Hex (Value'Length) & CRLF & Value & CRLF, Timeout, Token);
      end;
   end Send_Event;

   procedure End_SSE
     (Item    : in out Connection;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null) is
   begin
      if Item.State /= Streaming_SSE then
         raise Program_Error with "SSE response is not active";
      end if;
      Write (Item, "0" & CRLF & CRLF, Timeout, Token);
      Item.State := (if Item.Request_Close then Terminal else Reading_HTTP);
   end End_SSE;

   subtype Word is Interfaces.Unsigned_32;
   type Word_Array is array (Natural range <>) of Word;
   type Byte_Array is array (Natural range <>) of Interfaces.Unsigned_8;

   function Rotate_Left (Value : Word; Amount : Natural) return Word is
     (Interfaces.Shift_Left (Value, Amount)
      or Interfaces.Shift_Right (Value, 32 - Amount));

   function SHA1 (Value : String) return String is
      Padded_Length : constant Natural := ((Value'Length + 9 + 63) / 64) * 64;
      Data : Byte_Array (0 .. Padded_Length - 1) := (others => 0);
      Bits : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Value'Length) * 8;
      H0 : Word := 16#67452301#;
      H1 : Word := 16#EFCDAB89#;
      H2 : Word := 16#98BADCFE#;
      H3 : Word := 16#10325476#;
      H4 : Word := 16#C3D2E1F0#;
   begin
      for Index in Value'Range loop
         Data (Index - Value'First) :=
           Interfaces.Unsigned_8 (Character'Pos (Value (Index)));
      end loop;
      Data (Value'Length) := 16#80#;
      for Offset in 0 .. 7 loop
         Data (Padded_Length - 1 - Offset) := Interfaces.Unsigned_8
           (Interfaces.Shift_Right (Bits, Offset * 8) and 16#FF#);
      end loop;

      for Block in 0 .. Padded_Length / 64 - 1 loop
         declare
            W : Word_Array (0 .. 79) := (others => 0);
            A : Word := H0;
            B : Word := H1;
            C : Word := H2;
            D : Word := H3;
            E : Word := H4;
         begin
            for Index in 0 .. 15 loop
               declare
                  Base : constant Natural := Block * 64 + Index * 4;
               begin
                  W (Index) :=
                    Interfaces.Shift_Left (Word (Data (Base)), 24)
                    or Interfaces.Shift_Left (Word (Data (Base + 1)), 16)
                    or Interfaces.Shift_Left (Word (Data (Base + 2)), 8)
                    or Word (Data (Base + 3));
               end;
            end loop;
            for Index in 16 .. 79 loop
               W (Index) := Rotate_Left
                 (W (Index - 3) xor W (Index - 8) xor W (Index - 14)
                  xor W (Index - 16), 1);
            end loop;
            for Index in 0 .. 79 loop
               declare
                  F : Word;
                  K : Word;
                  Temp : Word;
               begin
                  if Index <= 19 then
                     F := (B and C) or ((not B) and D);
                     K := 16#5A827999#;
                  elsif Index <= 39 then
                     F := B xor C xor D;
                     K := 16#6ED9EBA1#;
                  elsif Index <= 59 then
                     F := (B and C) or (B and D) or (C and D);
                     K := 16#8F1BBCDC#;
                  else
                     F := B xor C xor D;
                     K := 16#CA62C1D6#;
                  end if;
                  Temp := Rotate_Left (A, 5) + F + E + K + W (Index);
                  E := D;
                  D := C;
                  C := Rotate_Left (B, 30);
                  B := A;
                  A := Temp;
               end;
            end loop;
            H0 := H0 + A;
            H1 := H1 + B;
            H2 := H2 + C;
            H3 := H3 + D;
            H4 := H4 + E;
         end;
      end loop;

      declare
         Hash : constant Word_Array (0 .. 4) := (H0, H1, H2, H3, H4);
         Result : String (1 .. 20);
      begin
         for Index in Hash'Range loop
            for Offset in 0 .. 3 loop
               Result (Index * 4 + Offset + 1) := Character'Val
                 (Interfaces.Shift_Right (Hash (Index), (3 - Offset) * 8)
                  and 16#FF#);
            end loop;
         end loop;
         return Result;
      end;
   end SHA1;

   function Base64 (Value : String) return String is
      Alphabet : constant String :=
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
      Result : String (1 .. 4 * ((Value'Length + 2) / 3));
      Input  : Natural := Value'First;
      Output : Natural := Result'First;
   begin
      while Input <= Value'Last loop
         declare
            Remaining : constant Natural := Value'Last - Input + 1;
            A : constant Natural := Character'Pos (Value (Input));
            B : constant Natural :=
              (if Remaining >= 2
               then Character'Pos (Value (Input + 1)) else 0);
            C : constant Natural :=
              (if Remaining >= 3
               then Character'Pos (Value (Input + 2)) else 0);
         begin
            Result (Output) := Alphabet (A / 4 + 1);
            Result (Output + 1) := Alphabet ((A mod 4) * 16 + B / 16 + 1);
            Result (Output + 2) :=
              (if Remaining >= 2
               then Alphabet ((B mod 16) * 4 + C / 64 + 1) else '=');
            Result (Output + 3) :=
              (if Remaining >= 3 then Alphabet (C mod 64 + 1) else '=');
            Input := Input + 3;
            Output := Output + 4;
         end;
      end loop;
      return Result;
   end Base64;

   function Valid_WebSocket_Key (Value : String) return Boolean is
      function Is_Base64 (Item : Character) return Boolean is
        (Item in 'a' .. 'z' or else Item in 'A' .. 'Z'
         or else Item in '0' .. '9' or else Item in '+' | '/');
   begin
      if Value'Length /= 24
        or else Value (Value'Last - 1 .. Value'Last) /= "=="
      then
         return False;
      end if;
      for Index in Value'First .. Value'Last - 2 loop
         if not Is_Base64 (Value (Index)) then
            return False;
         end if;
      end loop;
      return True;
   end Valid_WebSocket_Key;

   procedure Accept_WebSocket
     (Item     : in out Connection;
      Value    : Request;
      Protocol : String := "";
      Timeout  : Duration := 30.0;
      Token    : access Flyology.Cancellation.Token := null)
   is
      Key : constant String := Header (Value, "Sec-WebSocket-Key");
      GUID : constant String := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
   begin
      if Item.State /= Reading_HTTP or else Item.Response_Begun then
         raise Program_Error with "HTTP response already started";
      end if;
      if Method (Value) /= "GET"
        or else Version (Value) /= HTTP_1_1
        or else not Header_Has_Token (Value, "Connection", "upgrade")
        or else not Header_Has_Token (Value, "Upgrade", "websocket")
        or else Trim (Header (Value, "Sec-WebSocket-Version")) /= "13"
        or else not Valid_WebSocket_Key (Key)
      then
         raise Protocol_Error with "invalid WebSocket upgrade request";
      end if;
      if Protocol'Length > 0 then
         Validate_Token (Protocol, "WebSocket subprotocol");
         if not Header_Has_Token
           (Value, "Sec-WebSocket-Protocol", Protocol)
         then
            raise Protocol_Error with "WebSocket subprotocol was not offered";
         end if;
      end if;
      Write
        (Item,
         "HTTP/1.1 101 Switching Protocols" & CRLF
         & "Upgrade: websocket" & CRLF
         & "Connection: Upgrade" & CRLF
         & "Sec-WebSocket-Accept: " & Base64 (SHA1 (Key & GUID)) & CRLF
         & (if Protocol'Length = 0 then ""
            else "Sec-WebSocket-Protocol: " & Protocol & CRLF)
         & CRLF,
         Timeout, Token);
      Item.Response_Begun := True;
      Item.State := WebSocket;
   end Accept_WebSocket;

   procedure Ensure_Pending
     (Item    : in out Connection;
      Count   : Natural;
      Started : Ada.Real_Time.Time;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      Closed : Boolean;
   begin
      while Length (Item.Pending) < Count loop
         Receive_More
           (Item, Closed, Started, Timeout, Token,
            Maximum => Max_WebSocket_Frame + 14);
         if Closed then
            Item.State := Terminal;
            raise Protocol_Error with "peer closed inside WebSocket frame";
         end if;
      end loop;
   end Ensure_Pending;

   procedure Send_Frame
     (Item    : in out Connection;
      Opcode  : Natural;
      Data    : String;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      Header : Unbounded_String;
      Size   : constant Natural := Data'Length;
   begin
      Append (Header, Character'Val (16#80# + Opcode));
      if Size <= 125 then
         Append (Header, Character'Val (Size));
      elsif Size <= 65_535 then
         Append (Header, Character'Val (126));
         Append (Header, Character'Val (Size / 256));
         Append (Header, Character'Val (Size mod 256));
      else
         Append (Header, Character'Val (127));
         for Shift in reverse 0 .. 7 loop
            Append
              (Header,
               Character'Val
                 (Natural
                    (Interfaces.Shift_Right
                       (Interfaces.Unsigned_64 (Size), Shift * 8)
                     and 16#FF#)));
         end loop;
      end if;
      Write (Item, To_String (Header) & Data, Timeout, Token);
   end Send_Frame;

   procedure Receive_WebSocket
     (Item    : in out Connection;
      Kind    : out WebSocket_Data_Kind;
      Data    : out Unbounded_String;
      Closed  : out Boolean;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null)
   is
      Opcode : Natural;
      Size   : Interfaces.Unsigned_64;
      Header_Size : Natural := 2;
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   begin
      if Item.State /= WebSocket then
         raise Program_Error with "WebSocket connection is not active";
      end if;
      Kind := Text_Frame;
      Data := Null_Unbounded_String;
      Closed := False;
      loop
         Ensure_Pending (Item, 2, Started, Timeout, Token);
         declare
            Buffer : constant String := To_String (Item.Pending);
            First  : constant Natural := Character'Pos (Buffer (1));
            Second : constant Natural := Character'Pos (Buffer (2));
         begin
            if First / 128 /= 1 then
               raise Protocol_Error with
                 "fragmented WebSocket messages are not supported";
            end if;
            if (First / 16) mod 8 /= 0 or else Second / 128 /= 1 then
               raise Protocol_Error with "invalid WebSocket frame flags";
            end if;
            Opcode := First mod 16;
            Size := Interfaces.Unsigned_64 (Second mod 128);
         end;
         if Size = 126 then
            Ensure_Pending (Item, 4, Started, Timeout, Token);
            declare
               Buffer : constant String := To_String (Item.Pending);
            begin
               Size := Interfaces.Unsigned_64
                 (Character'Pos (Buffer (3)) * 256
                  + Character'Pos (Buffer (4)));
            end;
            Header_Size := 4;
            if Size < 126 then
               raise Protocol_Error with
                 "noncanonical WebSocket frame length";
            end if;
         elsif Size = 127 then
            Ensure_Pending (Item, 10, Started, Timeout, Token);
            Size := 0;
            declare
               Buffer : constant String := To_String (Item.Pending);
            begin
               for Index in 3 .. 10 loop
                  Size := Interfaces.Shift_Left (Size, 8)
                    or Interfaces.Unsigned_64 (Character'Pos (Buffer (Index)));
               end loop;
            end;
            Header_Size := 10;
            if Size <= 65_535 then
               raise Protocol_Error with
                 "noncanonical WebSocket frame length";
            end if;
         else
            Header_Size := 2;
         end if;
         if Size > Interfaces.Unsigned_64 (Max_WebSocket_Frame) then
            raise Protocol_Error with "WebSocket frame is too large";
         end if;
         if Opcode >= 8 and then Size > 125 then
            raise Protocol_Error with "oversized WebSocket control frame";
         end if;
         Ensure_Pending
           (Item, Header_Size + 4 + Natural (Size), Started, Timeout, Token);
         declare
            Buffer : constant String := To_String (Item.Pending);
            Mask_First : constant Natural := Header_Size + 1;
            Payload_First : constant Natural := Header_Size + 5;
            Payload : String (1 .. Natural (Size));
         begin
            for Index in Payload'Range loop
               Payload (Index) := Character'Val
                 (Interfaces.Unsigned_8
                    (Character'Pos (Buffer (Payload_First + Index - 1)))
                  xor Interfaces.Unsigned_8
                    (Character'Pos
                       (Buffer (Mask_First + ((Index - 1) mod 4)))));
            end loop;
            Consume (Item, Header_Size + 4 + Natural (Size));
            case Opcode is
               when 1 =>
                  Kind := Text_Frame;
                  Data := To_Unbounded_String (Payload);
                  return;
               when 2 =>
                  Kind := Binary_Frame;
                  Data := To_Unbounded_String (Payload);
                  return;
               when 8 =>
                  if Payload'Length = 1 then
                     raise Protocol_Error with "invalid WebSocket close frame";
                  end if;
                  Send_Frame (Item, 8, Payload, Timeout, Token);
                  Item.State := Terminal;
                  Closed := True;
                  return;
               when 9 =>
                  Send_Frame (Item, 10, Payload, Timeout, Token);
               when 10 =>
                  null;
               when others =>
                  raise Protocol_Error with "unsupported WebSocket opcode";
            end case;
         end;
      end loop;
   end Receive_WebSocket;

   procedure Send_WebSocket
     (Item    : in out Connection;
      Kind    : WebSocket_Data_Kind;
      Data    : String;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null) is
   begin
      if Item.State /= WebSocket then
         raise Program_Error with "WebSocket connection is not active";
      end if;
      if Data'Length > Max_WebSocket_Frame then
         raise Constraint_Error with "WebSocket frame is too large";
      end if;
      Send_Frame
        (Item, (if Kind = Text_Frame then 1 else 2), Data, Timeout, Token);
   end Send_WebSocket;

   procedure Close_WebSocket
     (Item    : in out Connection;
      Code    : Positive := 1_000;
      Reason  : String := "";
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null)
   is
      Payload : constant String :=
        Character'Val (Code / 256) & Character'Val (Code mod 256) & Reason;
   begin
      if Item.State /= WebSocket then
         raise Program_Error with "WebSocket connection is not active";
      end if;
      if Code > 65_535 or else Payload'Length > 125 then
         raise Constraint_Error with "invalid WebSocket close payload";
      end if;
      Send_Frame (Item, 8, Payload, Timeout, Token);
      Item.State := Terminal;
   end Close_WebSocket;

end Flyology.HTTP.Server;
