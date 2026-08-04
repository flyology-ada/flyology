with Ada.Characters.Handling;
with Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Strings.Fixed;
with Interfaces;
with Flyology.IO;
with GNAT.Sockets;

package body Flyology.HTTP.Server is
   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Real_Time.Time;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   CRLF : constant String := Character'Val (13) & Character'Val (10);
   WebSocket_Peer_EOF : exception;
   WebSocket_Coalesce_Limit : constant := 4 * 1_024;
   --  Small frames use one transport operation. Larger frames keep the
   --  caller's payload in place and send the fixed header separately.

   function HTTP_Date return String is
      Now : constant Ada.Calendar.Time := Ada.Calendar.Clock;
      Year : constant Ada.Calendar.Year_Number :=
        Ada.Calendar.Formatting.Year (Now, Time_Zone => 0);
      Month : constant Ada.Calendar.Month_Number :=
        Ada.Calendar.Formatting.Month (Now, Time_Zone => 0);
      Day : constant Ada.Calendar.Day_Number :=
        Ada.Calendar.Formatting.Day (Now, Time_Zone => 0);
      Hour : constant Ada.Calendar.Formatting.Hour_Number :=
        Ada.Calendar.Formatting.Hour (Now, Time_Zone => 0);
      Minute : constant Ada.Calendar.Formatting.Minute_Number :=
        Ada.Calendar.Formatting.Minute (Now, Time_Zone => 0);
      Second : constant Ada.Calendar.Formatting.Second_Number :=
        Ada.Calendar.Formatting.Second (Now);
      Adjusted_Year : constant Natural :=
        (if Month < 3 then Natural (Year) - 1 else Natural (Year));
      Adjusted_Month : constant Natural :=
        (if Month < 3 then Natural (Month) + 12 else Natural (Month));
      Weekday : constant Natural :=
        (Natural (Day) + 13 * (Adjusted_Month + 1) / 5
         + Adjusted_Year mod 100 + (Adjusted_Year mod 100) / 4
         + (Adjusted_Year / 100) / 4 + 5 * (Adjusted_Year / 100)) mod 7;
      Weekdays : constant array (Natural range 0 .. 6) of String (1 .. 3) :=
        ("Sat", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri");
      Months : constant array (Positive range 1 .. 12) of String (1 .. 3) :=
        ("Jan", "Feb", "Mar", "Apr", "May", "Jun",
         "Jul", "Aug", "Sep", "Oct", "Nov", "Dec");

      function Two (Value : Natural) return String is
        (Character'Val (Character'Pos ('0') + Value / 10)
         & Character'Val (Character'Pos ('0') + Value mod 10));

      function Four (Value : Natural) return String is
        (Two (Value / 100) & Two (Value mod 100));
   begin
      return Weekdays (Weekday) & ", " & Two (Natural (Day)) & " "
        & Months (Natural (Month)) & " " & Four (Natural (Year)) & " "
        & Two (Natural (Hour)) & ":" & Two (Natural (Minute)) & ":"
        & Two (Natural (Second)) & " GMT";
   end HTTP_Date;

   protected body Ingress_Budget_State is
      procedure Try_Reserve (Bytes : Natural; Granted : out Boolean) is
      begin
         Granted := Bytes <= Limit - Used;
         if Granted then
            Used := Used + Bytes;
            High_Water := Natural'Max (High_Water, Used);
         else
            if Denied < Natural'Last then
               Denied := Denied + 1;
            end if;
         end if;
      end Try_Reserve;

      procedure Release (Bytes : Natural) is
      begin
         if Bytes > Used then
            raise Program_Error with "HTTP ingress budget underflow";
         end if;
         Used := Used - Bytes;
      end Release;

      function Current return Ingress_Budget_Snapshot is
        ((Limit   => Limit,
          Current => Used,
          Peak    => High_Water,
          Denials => Denied));
   end Ingress_Budget_State;

   procedure Try_Reserve
     (Item : in out Ingress_Budget;
      Bytes : Natural;
      Granted : out Boolean)
   is
   begin
      Item.State.Try_Reserve (Bytes, Granted);
   end Try_Reserve;

   procedure Release (Item : in out Ingress_Budget; Bytes : Natural) is
   begin
      Item.State.Release (Bytes);
   end Release;

   function Current (Item : Ingress_Budget) return Ingress_Budget_Snapshot is
     (Item.State.Current);

   protected body Outbound_Budget_State is
      procedure Try_Reserve (Bytes : Natural; Granted : out Boolean) is
      begin
         Granted := Bytes <= Limit - Used;
         if Granted then
            Used := Used + Bytes;
            High_Water := Natural'Max (High_Water, Used);
         elsif Denied < Natural'Last then
            Denied := Denied + 1;
         end if;
      end Try_Reserve;

      procedure Release (Bytes : Natural) is
      begin
         if Bytes > Used then
            raise Program_Error with "HTTP outbound budget underflow";
         end if;
         Used := Used - Bytes;
      end Release;

      function Current return Outbound_Budget_Snapshot is
        ((Limit   => Limit,
          Current => Used,
          Peak    => High_Water,
          Denials => Denied));
   end Outbound_Budget_State;

   procedure Try_Reserve
     (Item : in out Outbound_Budget;
      Bytes : Natural;
      Granted : out Boolean) is
   begin
      Item.State.Try_Reserve (Bytes, Granted);
   end Try_Reserve;

   procedure Release (Item : in out Outbound_Budget; Bytes : Natural) is
   begin
      Item.State.Release (Bytes);
   end Release;

   function Current (Item : Outbound_Budget)
     return Outbound_Budget_Snapshot is (Item.State.Current);

   Default_Ingress_Budget : aliased Ingress_Budget
     (Limit => Default_Ingress_Budget_Bytes);

   procedure Release_Buffered (Item : in out Connection) is
   begin
      if Item.Buffered_Bytes > 0 then
         if Item.Reservation_Budget /= null then
            Release (Item.Reservation_Budget.all, Item.Buffered_Bytes);
         end if;
      end if;
      Item.Buffered_Bytes := 0;
      Item.Reservation_Budget := null;
   end Release_Buffered;

   procedure Reserve_Buffered
     (Item : in out Connection;
      Bytes_To_Reserve : Natural)
   is
      Granted : Boolean;
      Selected : constant Ingress_Budget_Access :=
        (if Item.Budget_Handle = null
         then Default_Ingress_Budget'Access
         else Item.Budget_Handle);
   begin
      Release_Buffered (Item);
      if Bytes_To_Reserve = 0 then
         return;
      end if;
      Try_Reserve
        (Selected.all, Bytes_To_Reserve, Granted);
      if not Granted then
         raise Resource_Exhausted with
           "HTTP server ingress byte budget exhausted";
      end if;
      Item.Buffered_Bytes := Bytes_To_Reserve;
      Item.Reservation_Budget := Selected;
   end Reserve_Buffered;

   procedure Resize_Buffered
     (Item : in out Connection;
      Bytes_To_Retain : Natural)
   is
      Granted  : Boolean;
      Selected : constant Ingress_Budget_Access :=
        (if Item.Reservation_Budget /= null
         then Item.Reservation_Budget
         elsif Item.Budget_Handle /= null
         then Item.Budget_Handle
         else Default_Ingress_Budget'Access);
   begin
      if Bytes_To_Retain > Item.Buffered_Bytes then
         Try_Reserve
           (Selected.all, Bytes_To_Retain - Item.Buffered_Bytes, Granted);
         if not Granted then
            raise Resource_Exhausted with
              "HTTP server ingress byte budget exhausted";
         end if;
         Item.Reservation_Budget := Selected;
      elsif Bytes_To_Retain < Item.Buffered_Bytes then
         Release
           (Selected.all, Item.Buffered_Bytes - Bytes_To_Retain);
      end if;
      Item.Buffered_Bytes := Bytes_To_Retain;
      if Bytes_To_Retain = 0 then
         Item.Reservation_Budget := null;
      end if;
   end Resize_Buffered;

   overriding procedure Finalize (Item : in out Connection) is
   begin
      Release_Buffered (Item);
   end Finalize;

   procedure Configure_Ingress_Budget
     (Item   : in out Connection;
      Budget : not null access Ingress_Budget)
   is
   begin
      if Item.Buffered_Bytes /= 0 then
         raise Program_Error with
           "cannot replace an active HTTP ingress budget";
      end if;
      Item.Budget_Handle := Budget.all'Unchecked_Access;
   end Configure_Ingress_Budget;

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

   function Header_Count (Item : Request; Name : String) return Natural is
     (Header_Field_Count (Item, Name));

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
      elsif Timeout >= 0.0 and then Elapsed >= Timeout then
         raise Flyology.IO.Timeout_Error with
           "HTTP request deadline expired";
      end if;
      declare
         Buffer : Ada.Streams.Stream_Element_Array
           (1 .. Ada.Streams.Stream_Element_Offset (Chunk));
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Item.Channel.Receive (Buffer, Last, Left, Token);
         Closed := Last < Buffer'First;
         if not Closed then
            if Item.State = WebSocket then
               Resize_Buffered
                 (Item,
                  Item.Buffered_Bytes
                    + Natural (Last - Buffer'First + 1));
            end if;
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

   function Is_Hex_Digit (Value : Character) return Boolean is
     (Value in '0' .. '9' or else Value in 'a' .. 'f'
      or else Value in 'A' .. 'F');

   function Valid_Port (Value : String) return Boolean is
      Result : Natural := 0;
   begin
      if Value'Length = 0 then
         return False;
      end if;
      for Item of Value loop
         if Item not in '0' .. '9' then
            return False;
         end if;
         if Result >
           (65_535 - (Character'Pos (Item) - Character'Pos ('0'))) / 10
         then
            return False;
         end if;
         Result := Result * 10 + Character'Pos (Item) - Character'Pos ('0');
      end loop;
      return True;
   end Valid_Port;

   function Valid_Reg_Name (Value : String) return Boolean is
      Index : Natural := Value'First;
   begin
      if Value'Length = 0 then
         return False;
      end if;
      while Index <= Value'Last loop
         if Value (Index) in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9'
           or else Value (Index) in '-' | '.' | '_' | '~'
           or else Value (Index) in '!' | '$' | '&' | ''' | '(' | ')'
                                      | '*' | '+' | ';' | '='
         then
            Index := Index + 1;
         elsif Value (Index) = '%'
           and then Index + 2 <= Value'Last
           and then Is_Hex_Digit (Value (Index + 1))
           and then Is_Hex_Digit (Value (Index + 2))
         then
            Index := Index + 3;
         else
            return False;
         end if;
      end loop;
      return True;
   end Valid_Reg_Name;

   function Valid_Authority (Value : String) return Boolean is
      Closing : Natural;
      Colon   : Natural;

      function Valid_IPv6 (Text : String) return Boolean is
         Address : GNAT.Sockets.Inet_Addr_Type;
      begin
         if Ada.Strings.Fixed.Index (Text, ":") = 0 then
            return False;
         end if;
         Address := GNAT.Sockets.Inet_Addr (Text);
         return GNAT.Sockets.Image (Address)'Length > 0;
      exception
         when others => return False;
      end Valid_IPv6;

      function Valid_IPvFuture (Text : String) return Boolean is
         Dot : constant Natural := Ada.Strings.Fixed.Index (Text, ".");
      begin
         if Text'Length < 4
           or else Text (Text'First) not in 'v' | 'V'
           or else Dot <= Text'First + 1
           or else Dot = Text'Last
         then
            return False;
         end if;
         for Index in Text'First + 1 .. Dot - 1 loop
            if not Is_Hex_Digit (Text (Index)) then
               return False;
            end if;
         end loop;
         for Index in Dot + 1 .. Text'Last loop
            if Text (Index) not in
              'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '.' | '_' | '~'
                | '!' | '$' | '&' | ''' | '(' | ')' | '*' | '+' | ',' | ';'
                | '=' | ':'
            then
               return False;
            end if;
         end loop;
         return True;
      end Valid_IPvFuture;
   begin
      if Value'Length = 0
        or else Ada.Strings.Fixed.Index (Value, "@") /= 0
        or else Ada.Strings.Fixed.Index (Value, ",") /= 0
      then
         return False;
      elsif Value (Value'First) = '[' then
         Closing := Ada.Strings.Fixed.Index (Value, "]");
         if Closing = 0 or else Closing = Value'First + 1 then
            return False;
         end if;
         return (Valid_IPv6 (Value (Value'First + 1 .. Closing - 1))
                 or else Valid_IPvFuture
                   (Value (Value'First + 1 .. Closing - 1)))
           and then (Closing = Value'Last
           or else (Value (Closing + 1) = ':'
                    and then Valid_Port
                      (Value (Closing + 2 .. Value'Last))));
      else
         Colon := Ada.Strings.Fixed.Index (Value, ":");
         if Colon = 0 then
            return Valid_Reg_Name (Value);
         elsif Ada.Strings.Fixed.Index
           (Value (Colon + 1 .. Value'Last), ":") /= 0
         then
            return False;
         else
            return Valid_Reg_Name (Value (Value'First .. Colon - 1))
              and then Valid_Port (Value (Colon + 1 .. Value'Last));
         end if;
      end if;
   end Valid_Authority;

   procedure Validate_Target_And_Authority (Value : Request) is
      Request_Target : constant String := Target (Value);
      Request_Method : constant String := Method (Value);
      Host           : constant String := Header (Value, "Host");
      Scheme_End     : Natural := 0;
      Index          : Natural := Request_Target'First;

      function Hex_Digit (Item : Character) return Boolean is
        (Item in '0' .. '9' | 'a' .. 'f' | 'A' .. 'F');
   begin
      while Index <= Request_Target'Last loop
         if Character'Pos (Request_Target (Index)) > 127
           or else Request_Target (Index) in
             '<' | '>' | '"' | '{' | '}' | '|' | '\' | '^' | '`'
         then
            raise Protocol_Error with
              "invalid raw character in request target";
         elsif Request_Target (Index) = '%' then
            if Request_Target'Last - Index < 2
              or else not Hex_Digit (Request_Target (Index + 1))
              or else not Hex_Digit (Request_Target (Index + 2))
            then
               raise Protocol_Error with
                 "invalid percent escape in request target";
            end if;
            Index := Index + 3;
         else
            Index := Index + 1;
         end if;
      end loop;
      if Host'Length > 0 and then not Valid_Authority (Host) then
         raise Protocol_Error with "invalid Host authority";
      end if;
      if Ada.Strings.Fixed.Index (Request_Target, "#") /= 0 then
         raise Protocol_Error with "fragment is not allowed in request target";
      elsif Request_Method = "CONNECT" then
         raise Protocol_Error with "CONNECT is not supported";
      elsif Request_Target = "*" then
         if Request_Method /= "OPTIONS" then
            raise Protocol_Error with "asterisk-form requires OPTIONS";
         end if;
      elsif Request_Target (Request_Target'First) = '/' then
         null;
      elsif Lower (Request_Target)'Length >= 7
        and then Lower (Request_Target)
          (Request_Target'First .. Request_Target'First + 6) = "http://"
      then
         Scheme_End := Request_Target'First + 6;
      elsif Lower (Request_Target)'Length >= 8
        and then Lower (Request_Target)
          (Request_Target'First .. Request_Target'First + 7) = "https://"
      then
         Scheme_End := Request_Target'First + 7;
      else
         raise Protocol_Error with "unsupported HTTP request-target form";
      end if;

      if Scheme_End /= 0 then
         declare
            Authority_First : constant Natural := Scheme_End + 1;
            Authority_Last  : Natural := Request_Target'Last;
         begin
            for Index in Authority_First .. Request_Target'Last loop
               if Request_Target (Index) in '/' | '?' then
                  Authority_Last := Index - 1;
                  exit;
               end if;
            end loop;
            if Authority_Last < Authority_First
              or else not Valid_Authority
                (Request_Target (Authority_First .. Authority_Last))
            then
               raise Protocol_Error with "invalid absolute request authority";
            elsif Host'Length > 0
              and then Lower (Host) /= Lower
                (Request_Target (Authority_First .. Authority_Last))
            then
               raise Protocol_Error with "Host conflicts with request target";
            end if;
         end;
      end if;
   end Validate_Target_And_Authority;

   procedure Write
     (Item    : in out Connection;
      Value   : String;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);

   procedure Write
     (Item    : in out Connection;
      Value   : Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);

   procedure Write_Parts
     (Item    : in out Connection;
      First   : Ada.Streams.Stream_Element_Array;
      Second  : Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);

   procedure Read_Line
     (Item       : in out Connection;
      Value      : out Unbounded_String;
      Started    : Ada.Real_Time.Time;
      Timeout    : Duration;
      Token      : access Flyology.Cancellation.Token;
      Maximum    : Natural)
   is
      Marker : Natural;
      Closed : Boolean;
   begin
      loop
         declare
            Available : constant String := To_String (Item.Pending);
         begin
            Marker := Ada.Strings.Fixed.Index (Available, CRLF);
            exit when Marker /= 0;
            if Available'Length > Maximum then
               raise Protocol_Error with "HTTP line is too large";
            end if;
         end;
         Receive_More
           (Item, Closed, Started, Timeout, Token, Maximum => Maximum + 2);
         if Closed then
            raise Protocol_Error with "peer closed inside HTTP line";
         end if;
      end loop;
      declare
         Available : constant String := To_String (Item.Pending);
      begin
         if Marker - 1 > Maximum then
            raise Protocol_Error with "HTTP line is too large";
         end if;
         Value :=
           (if Marker = Available'First then Null_Unbounded_String
            else To_Unbounded_String
              (Available (Available'First .. Marker - 1)));
      end;
      Consume (Item, Marker + 1);
   end Read_Line;

   function Parse_Chunk_Size
     (Line : String; Maximum_Body : Natural) return Natural
   is
      Semicolon : constant Natural := Ada.Strings.Fixed.Index (Line, ";");
      Last      : constant Natural :=
        (if Semicolon = 0 then Line'Last else Semicolon - 1);
      Result    : Natural := 0;
      Digit     : Natural;
   begin
      if Line'Length = 0 or else Last < Line'First then
         raise Protocol_Error with "empty HTTP chunk size";
      end if;
      for Index in Line'First .. Last loop
         if Line (Index) in '0' .. '9' then
            Digit := Character'Pos (Line (Index)) - Character'Pos ('0');
         elsif Line (Index) in 'a' .. 'f' then
            Digit := Character'Pos (Line (Index)) - Character'Pos ('a') + 10;
         elsif Line (Index) in 'A' .. 'F' then
            Digit := Character'Pos (Line (Index)) - Character'Pos ('A') + 10;
         else
            raise Protocol_Error with "invalid HTTP chunk size";
         end if;
         if Digit > Maximum_Body
           or else Result > (Maximum_Body - Digit) / 16
         then
            raise Payload_Too_Large with "HTTP request body is too large";
         end if;
         Result := Result * 16 + Digit;
      end loop;
      if Semicolon /= 0 then
         declare
            Position : Natural := Semicolon + 1;
         begin
            while Position <= Line'Last loop
               declare
                  Name_First : constant Natural := Position;
               begin
                  while Position <= Line'Last
                    and then Line (Position) not in '=' | ';'
                  loop
                     Position := Position + 1;
                  end loop;
                  if Position = Name_First then
                     raise Protocol_Error with
                       "invalid HTTP chunk extension";
                  end if;
                  Validate_Token
                    (Line (Name_First .. Position - 1),
                     "chunk extension name");
                  if Position <= Line'Last
                    and then Line (Position) = '='
                  then
                     Position := Position + 1;
                     if Position > Line'Last then
                        raise Protocol_Error with
                          "empty HTTP chunk extension value";
                     elsif Line (Position) = '"' then
                        Position := Position + 1;
                        loop
                           if Position > Line'Last then
                              raise Protocol_Error with
                                "unterminated quoted chunk extension";
                           elsif Line (Position) = '"' then
                              Position := Position + 1;
                              exit;
                           elsif Line (Position) = Character'Val (92) then
                              Position := Position + 1;
                              if Position > Line'Last
                                or else
                                  (Character'Pos (Line (Position)) < 32
                                   and then Line (Position) /=
                                     Character'Val (9))
                                or else Character'Pos (Line (Position)) = 127
                              then
                                 raise Protocol_Error with
                                   "invalid quoted-pair in chunk extension";
                              end if;
                              Position := Position + 1;
                           elsif (Character'Pos (Line (Position)) < 32
                                  and then Line (Position) /=
                                    Character'Val (9))
                             or else Character'Pos (Line (Position)) = 127
                             or else Line (Position) = '"'
                           then
                              raise Protocol_Error with
                                "invalid quoted chunk extension";
                           else
                              Position := Position + 1;
                           end if;
                        end loop;
                     else
                        declare
                           Value_First : constant Natural := Position;
                        begin
                           while Position <= Line'Last
                             and then Line (Position) /= ';'
                           loop
                              Position := Position + 1;
                           end loop;
                           if Position = Value_First then
                              raise Protocol_Error with
                                "empty HTTP chunk extension value";
                           end if;
                           Validate_Token
                             (Line (Value_First .. Position - 1),
                              "chunk extension value");
                        end;
                     end if;
                  end if;
                  if Position <= Line'Last then
                     if Line (Position) /= ';' then
                        raise Protocol_Error with
                          "invalid bytes after chunk extension";
                     end if;
                     Position := Position + 1;
                     if Position > Line'Last then
                        raise Protocol_Error with
                          "empty HTTP chunk extension";
                     end if;
                  end if;
               end;
            end loop;
         end;
      end if;
      return Result;
   end Parse_Chunk_Size;

   procedure Read_Request_Head
     (Item        : in out Connection;
      Value       : out Request;
      Peer_Closed : out Boolean;
      Timeout     : Duration := 30.0;
      Max_Body    : Natural := Max_Request_Body;
      Token       : access Flyology.Cancellation.Token := null)
   is
   begin
      Read_Request_Head
        (Item, Value, Peer_Closed,
         Header_Timeout  => Timeout,
         Request_Timeout => Timeout,
         Max_Body        => Max_Body,
         Token           => Token);
   end Read_Request_Head;

   procedure Read_Request_Head
     (Item            : in out Connection;
      Value           : out Request;
      Peer_Closed     : out Boolean;
      Header_Timeout  : Duration;
      Request_Timeout : Duration;
      Max_Body        : Natural := Max_Request_Body;
      Token           : access Flyology.Cancellation.Token := null)
   is
      Header_End : Natural := 0;
      Closed     : Boolean;
      Body_Size  : Natural := 0;
      Chunked    : Boolean := False;
      Body_Limit : constant Natural := Natural'Min
        (Max_Body, Max_Request_Body);
      Started    : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Effective_Header_Timeout : constant Duration :=
        (if Header_Timeout < 0.0
         then Request_Timeout
         elsif Request_Timeout < 0.0
         then Header_Timeout
         else Duration'Min (Header_Timeout, Request_Timeout));
   begin
      if Item.State /= Reading_HTTP then
         raise Program_Error with "HTTP connection is not reading requests";
      elsif not Item.Body_Done then
         raise Program_Error with
           "previous HTTP request body has not been consumed";
      end if;
      Release_Buffered (Item);
      Item.Response_Begun := False;
      Peer_Closed := False;
      Value.Body_Value := Null_Unbounded_String;
      Item.Body_Mode := No_Body;
      Item.Body_Remaining := 0;
      Item.Body_Total := 0;
      Item.Body_Limit := Body_Limit;
      Item.Body_Done := True;
      Item.Body_Accepted := True;
      Item.Continue_Pending := False;
      Item.Chunk_CRLF_Pending := False;
      Item.Body_Started := Started;
      Item.Body_Timeout := Request_Timeout;

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
           (Item, Closed, Started, Effective_Header_Timeout, Token,
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
      Validate_Target_And_Authority (Value);
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
            if Body_Size > Body_Limit then
               raise Payload_Too_Large with "HTTP request body is too large";
            end if;
         end if;
      end;

      declare
         Transfer_Count : constant Natural :=
           Header_Field_Count (Value, "Transfer-Encoding");
         Transfer_Value : constant String :=
           Header (Value, "Transfer-Encoding");
      begin
         if Transfer_Count /= 0 then
            if Value.Version_Value /= HTTP_1_1
              or else Transfer_Count > 1
              or else Lower (Trim (Transfer_Value)) /= "chunked"
            then
               raise Protocol_Error with
                 "unsupported request Transfer-Encoding";
            elsif Header_Field_Count (Value, "Content-Length") /= 0 then
               raise Protocol_Error with
                 "request has both Transfer-Encoding and Content-Length";
            end if;
            Chunked := True;
         end if;
      end;

      declare
         Expect_Count : constant Natural :=
           Header_Field_Count (Value, "Expect");
         Expect_Value : constant String := Header (Value, "Expect");
      begin
         if Expect_Count /= 0 then
            if Value.Version_Value /= HTTP_1_1
              or else Expect_Count > 1
              or else Lower (Trim (Expect_Value)) /= "100-continue"
            then
               raise Expectation_Failed with "unsupported HTTP expectation";
            elsif Chunked or else Body_Size > 0 then
               Item.Continue_Pending := True;
               Item.Body_Accepted := False;
            end if;
         end if;
      end;

      Consume (Item, Header_End + 3);
      if Chunked then
         Item.Body_Mode := Chunked_Body;
         Item.Body_Done := False;
         Item.Body_Accepted := not Item.Continue_Pending;
      elsif Body_Size > 0 then
         Item.Body_Mode := Fixed_Body;
         Item.Body_Remaining := Body_Size;
         Item.Body_Done := False;
         Item.Body_Accepted := not Item.Continue_Pending;
      else
         Item.Body_Mode := No_Body;
         Item.Body_Done := True;
         Item.Body_Accepted := True;
      end if;

      Value.Keep_Alive :=
        (if Value.Version_Value = HTTP_1_1
         then not Header_Has_Token (Value, "Connection", "close")
         else Header_Has_Token (Value, "Connection", "keep-alive")
           and then not Header_Has_Token (Value, "Connection", "close"));
      Item.Request_Close := not Value.Keep_Alive;
      Item.Current_Is_Head := Method (Value) = "HEAD";
      Item.Current_Version := Value.Version_Value;
   end Read_Request_Head;

   function Body_Time_Left (Item : Connection) return Duration is
      Elapsed : constant Duration := Ada.Real_Time.To_Duration
        (Ada.Real_Time.Clock - Item.Body_Started);
   begin
      if Item.Body_Timeout < 0.0 then
         return -1.0;
      elsif Elapsed >= Item.Body_Timeout then
         return 0.0;
      else
         return Item.Body_Timeout - Elapsed;
      end if;
   end Body_Time_Left;

   procedure Accept_Body
     (Item  : in out Connection;
      Token : access Flyology.Cancellation.Token := null)
   is
      Left : Duration;
   begin
      if Item.State /= Reading_HTTP or else Item.Body_Done then
         return;
      elsif Item.Body_Accepted then
         return;
      end if;
      Left := Body_Time_Left (Item);
      if Item.Body_Timeout >= 0.0 and then Left <= 0.0 then
         raise Flyology.IO.Timeout_Error with
           "HTTP request deadline expired";
      end if;
      Write
        (Item, "HTTP/1.1 100 Continue" & CRLF & CRLF,
         Left, Token);
      Item.Continue_Pending := False;
      Item.Body_Accepted := True;
   end Accept_Body;

   procedure Read_Body
     (Item     : in out Connection;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Token    : access Flyology.Cancellation.Token := null)
   is
      Written : Natural := 0;
      Closed  : Boolean;

      procedure Copy_Pending (Maximum : Natural) is
         Available : constant String := To_String (Item.Pending);
         Count     : constant Natural := Natural'Min
           (Maximum,
            Natural'Min
              (Available'Length, Natural (Data'Length) - Written));
      begin
         for Index in 1 .. Count loop
            Data
              (Data'First
               + Ada.Streams.Stream_Element_Offset (Written + Index - 1)) :=
                Ada.Streams.Stream_Element
                  (Character'Pos (Available (Available'First + Index - 1)));
         end loop;
         Consume (Item, Count);
         Written := Written + Count;
         Item.Body_Remaining := Item.Body_Remaining - Count;
         Item.Body_Total := Item.Body_Total + Count;
      end Copy_Pending;

      procedure Need (Count : Natural; Description : String) is
      begin
         while Length (Item.Pending) < Count loop
            Receive_More
              (Item, Closed, Item.Body_Started, Item.Body_Timeout, Token,
               Maximum => Count);
            if Closed then
               raise Protocol_Error with
                 "peer closed inside HTTP " & Description;
            end if;
         end loop;
      end Need;

      procedure Finish_Chunk is
      begin
         Need (2, "chunk terminator");
         declare
            Available : constant String := To_String (Item.Pending);
         begin
            if Available (Available'First .. Available'First + 1) /= CRLF then
               raise Protocol_Error with "invalid HTTP chunk terminator";
            end if;
         end;
         Consume (Item, 2);
         Item.Chunk_CRLF_Pending := False;
      end Finish_Chunk;

      procedure Finish_Trailers is
         Line          : Unbounded_String;
         Trailer_Bytes : Natural := 0;
      begin
         loop
            if Trailer_Bytes > Max_Header_Bytes - 2 then
               raise Protocol_Error with "HTTP trailers are too large";
            end if;
            Read_Line
              (Item, Line, Item.Body_Started, Item.Body_Timeout, Token,
               Maximum => Max_Header_Bytes - Trailer_Bytes - 2);
            exit when Length (Line) = 0;
            Trailer_Bytes := Trailer_Bytes + Length (Line) + 2;
            Validate_Header_Block (To_String (Line));
            declare
               Value : constant String := To_String (Line);
               Colon : constant Natural :=
                 Ada.Strings.Fixed.Index (Value, ":");
               Name  : constant String :=
                 Lower (Value (Value'First .. Colon - 1));
            begin
               if Name in "connection" | "content-length" | "host" | "trailer"
                          | "transfer-encoding" | "upgrade"
               then
                  raise Protocol_Error with "forbidden HTTP trailer field";
               end if;
            end;
         end loop;
         Item.Body_Mode := No_Body;
         Item.Body_Done := True;
      end Finish_Trailers;
   begin
      Data := (others => 0);
      Last := Data'First - 1;
      Finished := Item.Body_Done;
      if Data'Length = 0 then
         raise Constraint_Error with "HTTP body destination is empty";
      elsif Item.State /= Reading_HTTP then
         raise Program_Error with "HTTP connection is not reading a body";
      elsif Item.Body_Done then
         return;
      elsif not Item.Body_Accepted then
         raise Program_Error with
           "Accept_Body must precede a 100-continue body read";
      elsif Item.Body_Timeout >= 0.0
        and then Body_Time_Left (Item) <= 0.0
      then
         raise Flyology.IO.Timeout_Error with
           "HTTP request deadline expired";
      end if;

      while Written < Natural (Data'Length) and then not Item.Body_Done loop
         case Item.Body_Mode is
            when No_Body =>
               Item.Body_Done := True;

            when Fixed_Body =>
               if Length (Item.Pending) = 0 then
                  Receive_More
                    (Item, Closed, Item.Body_Started, Item.Body_Timeout, Token,
                     Maximum => Natural'Min
                       (Item.Body_Remaining,
                        Natural (Data'Length) - Written));
                  if Closed then
                     raise Protocol_Error with
                       "peer closed inside HTTP request body";
                  end if;
               end if;
               Copy_Pending (Item.Body_Remaining);
               if Item.Body_Remaining = 0 then
                  Item.Body_Mode := No_Body;
                  Item.Body_Done := True;
               end if;

            when Chunked_Body =>
               if Item.Chunk_CRLF_Pending then
                  Finish_Chunk;
               end if;
               if Item.Body_Remaining = 0 then
                  declare
                     Line       : Unbounded_String;
                     Chunk_Size : Natural;
                  begin
                     Read_Line
                       (Item, Line, Item.Body_Started, Item.Body_Timeout,
                        Token, Maximum => 1_024);
                     Chunk_Size :=
                       Parse_Chunk_Size (To_String (Line), Item.Body_Limit);
                     if Chunk_Size = 0 then
                        Finish_Trailers;
                     elsif Item.Body_Total > Item.Body_Limit - Chunk_Size then
                        raise Payload_Too_Large with
                          "HTTP request body is too large";
                     else
                        Item.Body_Remaining := Chunk_Size;
                     end if;
                  end;
               end if;
               if not Item.Body_Done and then Item.Body_Remaining > 0 then
                  if Length (Item.Pending) = 0 then
                     Receive_More
                       (Item, Closed, Item.Body_Started, Item.Body_Timeout,
                        Token,
                        Maximum => Natural'Min
                          (Item.Body_Remaining,
                           Natural (Data'Length) - Written));
                     if Closed then
                        raise Protocol_Error with
                          "peer closed inside HTTP chunk";
                     end if;
                  end if;
                  Copy_Pending (Item.Body_Remaining);
                  if Item.Body_Remaining = 0 then
                     Item.Chunk_CRLF_Pending := True;
                  end if;
               end if;
         end case;
      end loop;

      if Written > 0 then
         Last :=
           Data'First + Ada.Streams.Stream_Element_Offset (Written - 1);
      end if;
      Finished := Item.Body_Done;
   end Read_Body;

   procedure Discard_Body
     (Item  : in out Connection;
      Token : access Flyology.Cancellation.Token := null)
   is
      Buffer   : Ada.Streams.Stream_Element_Array (1 .. 8 * 1_024);
      Last     : Ada.Streams.Stream_Element_Offset;
      Finished : Boolean;
   begin
      Accept_Body (Item, Token);
      loop
         Read_Body (Item, Buffer, Last, Finished, Token);
         exit when Finished;
      end loop;
   end Discard_Body;

   function Body_Complete (Item : Connection) return Boolean is
     (Item.Body_Done);

   function Request_Deadline (Item : Connection) return Ada.Real_Time.Time is
     (if Item.Body_Timeout < 0.0
      then Ada.Real_Time.Time_Last
      else Item.Body_Started
        + Ada.Real_Time.To_Time_Span (Item.Body_Timeout));

   procedure Narrow_Request_Deadline
     (Item     : in out Connection;
      Deadline : Ada.Real_Time.Time)
   is
      Current : constant Ada.Real_Time.Time := Request_Deadline (Item);
   begin
      if Deadline > Current then
         raise Program_Error with "HTTP request deadline cannot be extended";
      elsif Deadline <= Item.Body_Started then
         Item.Body_Timeout := 0.0;
      elsif Deadline < Current then
         Item.Body_Timeout := Ada.Real_Time.To_Duration
           (Deadline - Item.Body_Started);
      end if;
   end Narrow_Request_Deadline;

   procedure Narrow_Body_Limit
     (Item    : in out Connection;
      Maximum : Natural)
   is
   begin
      if Maximum > Item.Body_Limit then
         raise Program_Error with "HTTP body limit cannot be extended";
      elsif Item.Body_Total /= 0 then
         raise Program_Error with
           "HTTP body limit cannot change after body consumption";
      elsif Item.Body_Remaining > Maximum then
         raise Payload_Too_Large with "HTTP request body is too large";
      end if;
      Item.Body_Limit := Maximum;
   end Narrow_Body_Limit;

   procedure Buffer_Request_Body
     (Item  : in out Connection;
      Value : in out Request;
      Token : access Flyology.Cancellation.Token := null)
   is
      Buffer   : Ada.Streams.Stream_Element_Array (1 .. 8 * 1_024);
      Last     : Ada.Streams.Stream_Element_Offset;
      Finished : Boolean;
      Reserved : Natural := 0;
   begin
      if Item.Body_Done then
         return;
      end if;
      Reserved :=
        (case Item.Body_Mode is
            when No_Body      => 0,
            when Fixed_Body   => Item.Body_Remaining,
            when Chunked_Body => Item.Body_Limit);
      Reserve_Buffered (Item, Reserved);
      Accept_Body (Item, Token);
      loop
         Read_Body (Item, Buffer, Last, Finished, Token);
         if Last >= Buffer'First then
            Append
              (Value.Body_Value,
               Text (Buffer (Buffer'First .. Last)));
         end if;
         exit when Finished;
      end loop;

      if Item.Buffered_Bytes > Item.Body_Total then
         Release
           (Item.Reservation_Budget.all,
            Item.Buffered_Bytes - Item.Body_Total);
         Item.Buffered_Bytes := Item.Body_Total;
         if Item.Buffered_Bytes = 0 then
            Item.Reservation_Budget := null;
         end if;
      end if;
   exception
      when others =>
         Release_Buffered (Item);
         raise;
   end Buffer_Request_Body;

   procedure Read_Request
     (Item        : in out Connection;
      Value       : out Request;
      Peer_Closed : out Boolean;
      Timeout     : Duration := 30.0;
      Max_Body    : Natural := Max_Request_Body;
      Token       : access Flyology.Cancellation.Token := null)
   is
   begin
      Read_Request_Head
        (Item, Value, Peer_Closed, Timeout, Max_Body, Token);
      if Peer_Closed then
         return;
      end if;
      Buffer_Request_Body (Item, Value, Token);
   end Read_Request;

   function Reason (Status : Positive) return String is
   begin
      case Status is
         when 101 => return "Switching Protocols";
         when 200 => return "OK";
         when 201 => return "Created";
         when 202 => return "Accepted";
         when 203 => return "Non-Authoritative Information";
         when 204 => return "No Content";
         when 205 => return "Reset Content";
         when 206 => return "Partial Content";
         when 301 => return "Moved Permanently";
         when 302 => return "Found";
         when 303 => return "See Other";
         when 304 => return "Not Modified";
         when 307 => return "Temporary Redirect";
         when 308 => return "Permanent Redirect";
         when 400 => return "Bad Request";
         when 401 => return "Unauthorized";
         when 403 => return "Forbidden";
         when 404 => return "Not Found";
         when 405 => return "Method Not Allowed";
         when 406 => return "Not Acceptable";
         when 408 => return "Request Timeout";
         when 409 => return "Conflict";
         when 410 => return "Gone";
         when 413 => return "Content Too Large";
         when 415 => return "Unsupported Media Type";
         when 422 => return "Unprocessable Content";
         when 426 => return "Upgrade Required";
         when 429 => return "Too Many Requests";
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
                            | "date" | "transfer-encoding" | "upgrade"
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

   procedure Write
     (Item    : in out Connection;
      Value   : Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token) is
   begin
      if Value'Length > 0 then
         Item.Channel.Send_All (Value, Timeout, Token);
      end if;
   end Write;

   procedure Write_Parts
     (Item    : in out Connection;
      First   : Ada.Streams.Stream_Element_Array;
      Second  : Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;

      function Time_Left return Duration is
         Elapsed : constant Duration := Ada.Real_Time.To_Duration
           (Ada.Real_Time.Clock - Started);
      begin
         if Timeout < 0.0 then
            return -1.0;
         elsif Elapsed >= Timeout then
            return 0.0;
         else
            return Timeout - Elapsed;
         end if;
      end Time_Left;
   begin
      if First'Length > 0 then
         Item.Channel.Send_All (First, Timeout, Token);
      end if;
      if Second'Length > 0 then
         Item.Channel.Send_All (Second, Time_Left, Token);
      end if;
   end Write_Parts;

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
      Must_Close : constant Boolean :=
        Close or else Item.Request_Close or else not Item.Body_Done;
      Body_Forbidden : constant Boolean := Status in 204 | 205 | 304;
      Head : Unbounded_String;
   begin
      if Item.State /= Reading_HTTP or else Item.Response_Begun then
         raise Program_Error with "HTTP response already started";
      end if;
      if Status not in 200 .. 599 then
         raise Constraint_Error with
           "final HTTP status must be 200 through 599";
      end if;
      if Body_Forbidden and then Payload'Length /= 0 then
         raise Program_Error with
           "HTTP status does not permit response content";
      end if;
      Validate_Extra_Headers (Extra_Headers);
      Append
        (Head,
         (if Item.Current_Version = HTTP_1_1
          then "HTTP/1.1 " else "HTTP/1.0 ")
         & Decimal (Status) & " " & Reason (Status) & CRLF);
      Append (Head, "Date: " & HTTP_Date & CRLF);
      if Status not in 204 | 304 then
         Append (Head, "Content-Length: " & Decimal (Payload'Length) & CRLF);
      end if;
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
      Item.Response_Begun := True;
      begin
         if not Item.Current_Is_Head
           and then not Body_Forbidden
           and then Payload'Length > 0
         then
            Write (Item, To_String (Head) & Payload, Timeout, Token);
         else
            Write (Item, To_String (Head), Timeout, Token);
         end if;
      exception
         when others =>
            Item.Request_Close := True;
            Item.State := Terminal;
            raise;
      end;
      if Must_Close then
         Item.Request_Close := True;
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

   procedure Begin_Response_Stream
     (Item          : in out Connection;
      Status        : Positive;
      Content_Type  : String;
      Extra_Headers : String := "";
      Close         : Boolean := False;
      Timeout       : Duration := 30.0;
      Token         : access Flyology.Cancellation.Token := null)
   is
      Must_Close : constant Boolean :=
        Close
        or else Item.Request_Close
        or else Item.Current_Version = HTTP_1_0;
      Head : Unbounded_String;
   begin
      if Item.State /= Reading_HTTP or else Item.Response_Begun then
         raise Program_Error with "HTTP response already started";
      elsif not Item.Body_Done then
         raise Program_Error with
           "streaming response requires a consumed request body";
      elsif Status not in 200 .. 599 then
         raise Constraint_Error with
           "final HTTP status must be 200 through 599";
      elsif Status in 204 | 205 | 304 then
         raise Program_Error with
           "HTTP status does not permit a streaming response";
      end if;
      Validate_Extra_Headers (Extra_Headers);
      for Value of Content_Type loop
         if Character'Pos (Value) < 32 or else Character'Pos (Value) = 127 then
            raise Program_Error with "invalid HTTP content type";
         end if;
      end loop;
      Append
        (Head,
         (if Item.Current_Version = HTTP_1_1
          then "HTTP/1.1 " else "HTTP/1.0 ")
         & Decimal (Status) & " " & Reason (Status) & CRLF);
      Append (Head, "Date: " & HTTP_Date & CRLF);
      if Content_Type'Length > 0 then
         Append (Head, "Content-Type: " & Content_Type & CRLF);
      end if;
      if Item.Current_Version = HTTP_1_1 then
         Append (Head, "Transfer-Encoding: chunked" & CRLF);
      end if;
      Append (Head, Extra_Headers);
      Append
        (Head,
         "Connection: " & (if Must_Close then "close" else "keep-alive")
         & CRLF & CRLF);
      Item.Response_Begun := True;
      Item.Request_Close := Must_Close;
      Item.State := Streaming_HTTP;
      begin
         Write (Item, To_String (Head), Timeout, Token);
      exception
         when others =>
            Item.Request_Close := True;
            Item.State := Terminal;
            raise;
      end;
   end Begin_Response_Stream;

   procedure Write_Response_Chunk
     (Item    : in out Connection;
      Data    : String;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null)
   is
   begin
      if Item.State /= Streaming_HTTP then
         raise Program_Error with "HTTP streaming response is not active";
      elsif Data'Length = 0 or else Item.Current_Is_Head then
         return;
      elsif Item.Current_Version = HTTP_1_1 then
         begin
            Write
              (Item, Hex (Data'Length) & CRLF & Data & CRLF, Timeout, Token);
         exception
            when others =>
               Item.Request_Close := True;
               Item.State := Terminal;
               raise;
         end;
      else
         begin
            Write (Item, Data, Timeout, Token);
         exception
            when others =>
               Item.Request_Close := True;
               Item.State := Terminal;
               raise;
         end;
      end if;
   end Write_Response_Chunk;

   procedure Write_Response_Chunk
     (Item    : in out Connection;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null)
   is
   begin
      if Item.State /= Streaming_HTTP then
         raise Program_Error with "HTTP streaming response is not active";
      elsif Data'Length = 0 or else Item.Current_Is_Head then
         return;
      elsif Item.Current_Version = HTTP_1_1 then
         declare
            Prefix : constant Ada.Streams.Stream_Element_Array :=
              Bytes (Hex (Natural (Data'Length)) & CRLF);
            Suffix : constant Ada.Streams.Stream_Element_Array := Bytes (CRLF);
            Frame  : Ada.Streams.Stream_Element_Array
              (1 .. Ada.Streams.Stream_Element_Offset
                (Prefix'Length + Data'Length + Suffix'Length));
            Last : Ada.Streams.Stream_Element_Offset := 0;
         begin
            for Value of Prefix loop
               Last := Last + 1;
               Frame (Last) := Value;
            end loop;
            for Value of Data loop
               Last := Last + 1;
               Frame (Last) := Value;
            end loop;
            for Value of Suffix loop
               Last := Last + 1;
               Frame (Last) := Value;
            end loop;
            Write (Item, Frame, Timeout, Token);
         exception
            when others =>
               Item.Request_Close := True;
               Item.State := Terminal;
               raise;
         end;
      else
         begin
            Write (Item, Data, Timeout, Token);
         exception
            when others =>
               Item.Request_Close := True;
               Item.State := Terminal;
               raise;
         end;
      end if;
   end Write_Response_Chunk;

   procedure End_Response_Stream
     (Item    : in out Connection;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null)
   is
   begin
      if Item.State /= Streaming_HTTP then
         raise Program_Error with "HTTP streaming response is not active";
      end if;
      if Item.Current_Version = HTTP_1_1 and then not Item.Current_Is_Head then
         begin
            Write (Item, "0" & CRLF & CRLF, Timeout, Token);
         exception
            when others =>
               Item.Request_Close := True;
               Item.State := Terminal;
               raise;
         end;
      end if;
      Item.State :=
        (if Item.Request_Close then Terminal else Reading_HTTP);
   end End_Response_Stream;

   procedure Begin_SSE
     (Item          : in out Connection;
      Extra_Headers : String := "";
      Timeout       : Duration := 30.0;
      Token         : access Flyology.Cancellation.Token := null)
   is
   begin
      if Item.State /= Reading_HTTP or else Item.Response_Begun then
         raise Program_Error with "HTTP response already started";
      elsif not Item.Body_Done then
         raise Program_Error with "SSE request body has not been consumed";
      end if;
      if Item.Current_Is_Head then
         raise Program_Error with "SSE is not available for HEAD";
      elsif Item.Current_Version /= HTTP_1_1 then
         raise Program_Error with "SSE requires HTTP/1.1";
      end if;
      Validate_Extra_Headers (Extra_Headers);
      Item.Response_Begun := True;
      Item.State := Streaming_SSE;
      begin
         Write
           (Item,
            "HTTP/1.1 200 OK" & CRLF
            & "Date: " & HTTP_Date & CRLF
            & "Content-Type: text/event-stream" & CRLF
            & "Cache-Control: no-cache" & CRLF
            & "Transfer-Encoding: chunked" & CRLF
            & Extra_Headers
            & "Connection: "
            & (if Item.Request_Close then "close" else "keep-alive")
            & CRLF & CRLF,
            Timeout, Token);
      exception
         when others =>
            Item.Request_Close := True;
            Item.State := Terminal;
            raise;
      end;
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

   function Valid_UTF8 (Value : String) return Boolean is
      Index : Natural := Value'First;

      function Byte (Offset : Natural) return Natural is
        (Character'Pos (Value (Index + Offset)));

      function Continuation (Offset : Natural) return Boolean is
        (Index + Offset <= Value'Last
         and then Byte (Offset) in 16#80# .. 16#BF#);
   begin
      while Index <= Value'Last loop
         if Byte (0) <= 16#7F# then
            Index := Index + 1;
         elsif Byte (0) in 16#C2# .. 16#DF#
           and then Continuation (1)
         then
            Index := Index + 2;
         elsif Byte (0) = 16#E0#
           and then Index + 2 <= Value'Last
           and then Byte (1) in 16#A0# .. 16#BF#
           and then Continuation (2)
         then
            Index := Index + 3;
         elsif Byte (0) in 16#E1# .. 16#EC# | 16#EE# .. 16#EF#
           and then Continuation (1)
           and then Continuation (2)
         then
            Index := Index + 3;
         elsif Byte (0) = 16#ED#
           and then Index + 2 <= Value'Last
           and then Byte (1) in 16#80# .. 16#9F#
           and then Continuation (2)
         then
            Index := Index + 3;
         elsif Byte (0) = 16#F0#
           and then Index + 3 <= Value'Last
           and then Byte (1) in 16#90# .. 16#BF#
           and then Continuation (2)
           and then Continuation (3)
         then
            Index := Index + 4;
         elsif Byte (0) in 16#F1# .. 16#F3#
           and then Continuation (1)
           and then Continuation (2)
           and then Continuation (3)
         then
            Index := Index + 4;
         elsif Byte (0) = 16#F4#
           and then Index + 3 <= Value'Last
           and then Byte (1) in 16#80# .. 16#8F#
           and then Continuation (2)
           and then Continuation (3)
         then
            Index := Index + 4;
         else
            return False;
         end if;
      end loop;
      return True;
   end Valid_UTF8;

   procedure Send_Event
     (Item    : in out Connection;
      Data    : String;
      Event   : String := "";
      Id      : String := "";
      Retry   : Natural := 0;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null;
      Include_Id : Boolean := False;
      Include_Retry : Boolean := False)
   is
      Payload : Unbounded_String;
      First   : Integer := Data'First;
   begin
      if Item.State /= Streaming_SSE then
         raise Program_Error with "SSE response is not active";
      end if;
      Validate_SSE_Field (Event, "SSE event name");
      Validate_SSE_Field (Id, "SSE id");
      if not Valid_UTF8 (Data)
        or else not Valid_UTF8 (Event)
        or else not Valid_UTF8 (Id)
        or else Ada.Strings.Fixed.Index
          (Id, String'(1 => Character'Val (0))) /= 0
      then
         raise Program_Error with "SSE fields must contain valid UTF-8";
      end if;
      if Event'Length > 0 then
         Append (Payload, "event: " & Event & Character'Val (10));
      end if;
      if Id'Length > 0 or else Include_Id then
         Append (Payload, "id: " & Id & Character'Val (10));
      end if;
      if Retry > 0 or else Include_Retry then
         Append (Payload, "retry: " & Decimal (Retry) & Character'Val (10));
      end if;
      if Data'Length = 0 then
         Append (Payload, "data:" & Character'Val (10));
      else
         while First <= Data'Last loop
            declare
               Break : Natural := 0;
               Last  : Integer;
            begin
               for Index in First .. Data'Last loop
                  if Data (Index) in
                    Character'Val (10) | Character'Val (13)
                  then
                     Break := Index;
                     exit;
                  end if;
               end loop;
               Last := (if Break = 0 then Data'Last else Break - 1);
               Append (Payload, "data:");
               if Last >= First then
                  Append (Payload, " " & Data (First .. Last));
               end if;
               Append (Payload, Character'Val (10));
               exit when Break = 0;
               First := Break + 1;
               if Data (Break) = Character'Val (13)
                 and then First <= Data'Last
                 and then Data (First) = Character'Val (10)
               then
                  First := First + 1;
               end if;
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
         begin
            Write
              (Item, Hex (Value'Length) & CRLF & Value & CRLF, Timeout, Token);
         exception
            when others =>
               Item.Request_Close := True;
               Item.State := Terminal;
               raise;
         end;
      end;
   end Send_Event;

   procedure Send_SSE_Comment
     (Item    : in out Connection;
      Comment : String := "";
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null)
   is
      Payload : Unbounded_String;
      First   : Integer := Comment'First;
   begin
      if Item.State /= Streaming_SSE then
         raise Program_Error with "SSE response is not active";
      elsif not Valid_UTF8 (Comment) then
         raise Program_Error with "SSE comment must contain valid UTF-8";
      end if;
      if Comment'Length = 0 then
         Append (Payload, ":" & Character'Val (10));
      else
         while First <= Comment'Last loop
            declare
               Break : Natural := 0;
               Last  : Integer;
            begin
               for Index in First .. Comment'Last loop
                  if Comment (Index) in
                    Character'Val (10) | Character'Val (13)
                  then
                     Break := Index;
                     exit;
                  end if;
               end loop;
               Last := (if Break = 0 then Comment'Last else Break - 1);
               Append (Payload, ":");
               if Last >= First then
                  Append (Payload, " " & Comment (First .. Last));
               end if;
               Append (Payload, Character'Val (10));
               exit when Break = 0;
               First := Break + 1;
               if Comment (Break) = Character'Val (13)
                 and then First <= Comment'Last
                 and then Comment (First) = Character'Val (10)
               then
                  First := First + 1;
               end if;
            end;
         end loop;
      end if;
      Append (Payload, Character'Val (10));
      declare
         Value : constant String := To_String (Payload);
      begin
         begin
            Write
              (Item, Hex (Value'Length) & CRLF & Value & CRLF, Timeout, Token);
         exception
            when others =>
               Item.Request_Close := True;
               Item.State := Terminal;
               raise;
         end;
      end;
   end Send_SSE_Comment;

   procedure End_SSE
     (Item    : in out Connection;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null) is
   begin
      if Item.State /= Streaming_SSE then
         raise Program_Error with "SSE response is not active";
      end if;
      begin
         Write (Item, "0" & CRLF & CRLF, Timeout, Token);
      exception
         when others =>
            Item.Request_Close := True;
            Item.State := Terminal;
            raise;
      end;
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

   function Header_Has_Exact_Token
     (Item : Request; Name : String; Value : String) return Boolean
   is
      List  : constant String := Header (Item, Name);
      First : Positive := 1;
      Found : Boolean := False;
   begin
      Validate_Token (Value, "header token");
      while First <= List'Length loop
         declare
            Comma : constant Natural :=
              Ada.Strings.Fixed.Index (List (First .. List'Last), ",");
            Last : constant Natural :=
              (if Comma = 0 then List'Last else Comma - 1);
            Candidate : constant String := Trim (List (First .. Last));
         begin
            Validate_Token (Candidate, "header token");
            if Candidate = Value then
               Found := True;
            end if;
            exit when Comma = 0;
            First := Comma + 1;
         end;
      end loop;
      return Found;
   end Header_Has_Exact_Token;

   procedure Accept_WebSocket
     (Item     : in out Connection;
      Value    : Request;
      Protocol : String := "";
      Origin_Policy : WebSocket_Origin_Policy := Reject_Browser_Origins;
      Allowed_Origin : String := "";
      Timeout  : Duration := 30.0;
      Token    : access Flyology.Cancellation.Token := null)
   is
      Key : constant String := Header (Value, "Sec-WebSocket-Key");
      Origin : constant String := Header (Value, "Origin");
      Origin_Count : constant Natural := Header_Field_Count (Value, "Origin");
      GUID : constant String := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
   begin
      if Item.State /= Reading_HTTP or else Item.Response_Begun then
         raise Program_Error with "HTTP response already started";
      elsif not Item.Body_Done or else Item.Body_Total > 0
        or else Content (Value)'Length > 0
      then
         raise Program_Error with
           "WebSocket upgrade requests must not carry a body";
      end if;
      if Trim (Header (Value, "Sec-WebSocket-Version")) /= "13" then
         Respond
           (Item, 426, "text/plain", "WebSocket version 13 is required",
            "Sec-WebSocket-Version: 13" & CRLF,
            Close => True, Timeout => Timeout, Token => Token);
         raise Protocol_Error with "unsupported WebSocket version";
      elsif Method (Value) /= "GET"
        or else Version (Value) /= HTTP_1_1
        or else not Header_Has_Token (Value, "Connection", "upgrade")
        or else not Header_Has_Token (Value, "Upgrade", "websocket")
        or else not Valid_WebSocket_Key (Key)
      then
         raise Protocol_Error with "invalid WebSocket upgrade request";
      end if;
      if Origin_Count > 1
        or else (Origin_Policy = Reject_Browser_Origins
                 and then Origin_Count /= 0)
        or else (Origin_Policy = Require_Exact_Origin
                 and then (Origin_Count /= 1 or else Origin /= Allowed_Origin))
      then
         raise Protocol_Error with "WebSocket origin was rejected";
      end if;
      if Header_Field_Count (Value, "Sec-WebSocket-Protocol") > 0 then
         if Trim (Header (Value, "Sec-WebSocket-Protocol")) = "" then
            raise Protocol_Error with
              "empty WebSocket subprotocol offer";
         end if;
         declare
            Validated : constant Boolean := Header_Has_Exact_Token
              (Value, "Sec-WebSocket-Protocol", "flyology-no-match");
            pragma Unreferenced (Validated);
         begin
            null;
         end;
      end if;
      if Protocol'Length > 0 then
         Validate_Token (Protocol, "WebSocket subprotocol");
         if not Header_Has_Exact_Token
           (Value, "Sec-WebSocket-Protocol", Protocol)
         then
            raise Protocol_Error with "WebSocket subprotocol was not offered";
         end if;
      end if;
      Reserve_Buffered (Item, Length (Item.Pending));
      Item.Response_Begun := True;
      Item.State := WebSocket;
      Item.WebSocket_Reserved := False;
      Item.WebSocket_Fragmented := False;
      Item.WebSocket_Receive_Active := False;
      Item.WebSocket_Message_Deadline := Ada.Real_Time.Time_Last;
      Item.WebSocket_Close_Sent := False;
      Flyology.Bytes.Clear (Item.WebSocket_Message);
      Item.WebSocket_Control_Count := 0;
      begin
         Write
           (Item,
            "HTTP/1.1 101 Switching Protocols" & CRLF
            & "Date: " & HTTP_Date & CRLF
            & "Upgrade: websocket" & CRLF
            & "Connection: Upgrade" & CRLF
            & "Sec-WebSocket-Accept: " & Base64 (SHA1 (Key & GUID)) & CRLF
            & (if Protocol'Length = 0 then ""
               else "Sec-WebSocket-Protocol: " & Protocol & CRLF)
            & CRLF,
            Timeout, Token);
      exception
         when others =>
            Release_Buffered (Item);
            Item.Request_Close := True;
            Item.State := Terminal;
            raise;
      end;
   exception
      when others =>
         if not Item.Response_Begun and then Item.State /= WebSocket then
            Release_Buffered (Item);
         end if;
         raise;
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
            raise WebSocket_Peer_EOF;
         end if;
      end loop;
   end Ensure_Pending;

   procedure Send_Frame
     (Item    : in out Connection;
      Opcode  : Natural;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      Header : Ada.Streams.Stream_Element_Array (1 .. 10);
      Last   : Ada.Streams.Stream_Element_Offset := Header'First - 1;
      Size   : constant Natural := Data'Length;

      procedure Append_Header (Value : Natural) is
      begin
         Last := Last + 1;
         Header (Last) := Ada.Streams.Stream_Element (Value);
      end Append_Header;
   begin
      Append_Header (16#80# + Opcode);
      if Size <= 125 then
         Append_Header (Size);
      elsif Size <= 65_535 then
         Append_Header (126);
         Append_Header (Size / 256);
         Append_Header (Size mod 256);
      else
         Append_Header (127);
         for Shift in reverse 0 .. 7 loop
            Append_Header
              (Natural
                 (Interfaces.Shift_Right
                    (Interfaces.Unsigned_64 (Size), Shift * 8)
                  and 16#FF#));
         end loop;
      end if;
      if Size <= WebSocket_Coalesce_Limit then
         declare
            Frame : Ada.Streams.Stream_Element_Array
              (1 .. Last + Ada.Streams.Stream_Element_Offset (Size));
         begin
            Frame (1 .. Last) := Header (1 .. Last);
            Frame (Last + 1 .. Frame'Last) := Data;
            Write (Item, Frame, Timeout, Token);
         end;
      else
         Write_Parts
           (Item, Header (Header'First .. Last), Data, Timeout, Token);
      end if;
   end Send_Frame;

   procedure Send_Frame
     (Item    : in out Connection;
      Opcode  : Natural;
      Data    : String;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token) is
   begin
      Send_Frame (Item, Opcode, Bytes (Data), Timeout, Token);
   end Send_Frame;

   procedure Receive_WebSocket
     (Item    : in out Connection;
      Kind    : out WebSocket_Data_Kind;
      Data    : out Flyology.Bytes.Unbounded_Bytes;
      Closed  : out Boolean;
      Max_Message : Natural := Max_WebSocket_Frame;
      Timeout : Duration := 30.0;
      Message_Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null)
   is
      Opcode       : Natural;
      Size         : Interfaces.Unsigned_64;
      Header_Size  : Natural;
      Final        : Boolean;
      Message_Limit : constant Natural := Natural'Min
        (Max_Message, Max_WebSocket_Frame);
      Started      : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Writing_Control : Boolean := False;

      function Time_Left return Duration is
         Elapsed : constant Duration := Ada.Real_Time.To_Duration
           (Ada.Real_Time.Clock - Started);
         Quantum_Left : constant Duration :=
           (if Timeout < 0.0 then -1.0
            elsif Elapsed >= Timeout then 0.0
            else Timeout - Elapsed);
         Message_Left : constant Duration :=
           (if Item.WebSocket_Message_Deadline = Ada.Real_Time.Time_Last
            then -1.0
            elsif Ada.Real_Time.Clock >= Item.WebSocket_Message_Deadline
            then 0.0
            else Ada.Real_Time.To_Duration
              (Item.WebSocket_Message_Deadline - Ada.Real_Time.Clock));
      begin
         if Quantum_Left < 0.0 then
            return Message_Left;
         elsif Message_Left < 0.0 then
            return Quantum_Left;
         else
            return Duration'Min (Quantum_Left, Message_Left);
         end if;
      end Time_Left;

      procedure Check_Deadline is
      begin
         if Time_Left = 0.0 then
            raise Flyology.IO.Timeout_Error with
              "WebSocket receive deadline expired";
         end if;
      end Check_Deadline;

      function Valid_Close_Code (Code : Natural) return Boolean is
        ((Code in 1_000 .. 1_015
          and then Code not in 1_004 .. 1_006 | 1_015)
         or else (Code in 3_000 .. 4_999));

      procedure Fail (Code : Positive; Message : String) is
         Payload : constant String :=
           Character'Val (Code / 256) & Character'Val (Code mod 256);
      begin
         Item.State := Terminal;
         begin
            if not Item.WebSocket_Close_Sent
              and then (Timeout < 0.0 or else Time_Left > 0.0)
            then
               Send_Frame (Item, 8, Payload, Time_Left, Token);
               Item.WebSocket_Close_Sent := True;
            end if;
         exception
            when others =>
               null;
         end;
         raise Protocol_Error with Message;
      end Fail;

      procedure Finish_Message is
      begin
         if Item.WebSocket_Message_Kind = Text_Frame
           and then not Valid_UTF8
             (Flyology.Bytes.To_Byte_String (Item.WebSocket_Message))
         then
            Fail (1_007, "invalid UTF-8 in WebSocket text message");
         end if;
         Kind := Item.WebSocket_Message_Kind;
         Flyology.Bytes.Move (Data, Item.WebSocket_Message);
         Item.WebSocket_Fragmented := False;
         Item.WebSocket_Reserved := False;
         Item.WebSocket_Message_Limit := 0;
         Item.WebSocket_Control_Count := 0;
         Item.WebSocket_Receive_Active := False;
         Item.WebSocket_Message_Deadline := Ada.Real_Time.Time_Last;
         Resize_Buffered (Item, Length (Item.Pending));
      end Finish_Message;

      procedure Abandon_Message is
      begin
         Item.Pending := Null_Unbounded_String;
         Flyology.Bytes.Clear (Item.WebSocket_Message);
         Item.WebSocket_Fragmented := False;
         Item.WebSocket_Reserved := False;
         Item.WebSocket_Message_Limit := 0;
         Item.WebSocket_Control_Count := 0;
         Item.WebSocket_Receive_Active := False;
         Item.WebSocket_Message_Deadline := Ada.Real_Time.Time_Last;
         Release_Buffered (Item);
      end Abandon_Message;
   begin
      if Item.State /= WebSocket then
         raise Program_Error with "WebSocket connection is not active";
      end if;
      if not Item.WebSocket_Receive_Active then
         Item.WebSocket_Receive_Active := True;
         Item.WebSocket_Message_Deadline :=
           (if Message_Timeout < 0.0 then Ada.Real_Time.Time_Last
            else Started + Ada.Real_Time.To_Time_Span (Message_Timeout));
         Item.WebSocket_Message_Limit := Message_Limit;
      elsif Item.WebSocket_Message_Limit /= Message_Limit then
         raise Program_Error with
           "WebSocket Max_Message changed during fragmented receive";
      end if;
      Kind := Text_Frame;
      Flyology.Bytes.Clear (Data);
      Closed := False;
      loop
         Check_Deadline;
         Ensure_Pending (Item, 2, Ada.Real_Time.Clock, Time_Left, Token);
         declare
            Buffer : constant String := To_String (Item.Pending);
            First  : constant Natural := Character'Pos (Buffer (1));
            Second : constant Natural := Character'Pos (Buffer (2));
         begin
            Final := First / 128 = 1;
            if (First / 16) mod 8 /= 0 or else Second / 128 /= 1 then
               Fail (1_002, "invalid WebSocket frame flags");
            end if;
            Opcode := First mod 16;
            Size := Interfaces.Unsigned_64 (Second mod 128);
         end;
         if Opcode not in 0 | 1 | 2 | 8 | 9 | 10 then
            Fail (1_002, "unsupported WebSocket opcode");
         elsif Opcode >= 8 and then not Final then
            Fail (1_002, "fragmented WebSocket control frame");
         end if;
         if Size = 126 then
            Ensure_Pending (Item, 4, Ada.Real_Time.Clock, Time_Left, Token);
            declare
               Buffer : constant String := To_String (Item.Pending);
            begin
               Size := Interfaces.Unsigned_64
                 (Character'Pos (Buffer (3)) * 256
                  + Character'Pos (Buffer (4)));
            end;
            Header_Size := 4;
            if Size < 126 then
               Fail (1_002, "noncanonical WebSocket frame length");
            end if;
         elsif Size = 127 then
            Ensure_Pending (Item, 10, Ada.Real_Time.Clock, Time_Left, Token);
            Size := 0;
            declare
               Buffer : constant String := To_String (Item.Pending);
            begin
               if Character'Pos (Buffer (3)) >= 128 then
                  Fail (1_002, "invalid WebSocket 64-bit frame length");
               end if;
               for Index in 3 .. 10 loop
                  Size := Interfaces.Shift_Left (Size, 8)
                    or Interfaces.Unsigned_64 (Character'Pos (Buffer (Index)));
               end loop;
            end;
            Header_Size := 10;
            if Size <= 65_535 then
               Fail (1_002, "noncanonical WebSocket frame length");
            end if;
         else
            Header_Size := 2;
         end if;
         if Size > Interfaces.Unsigned_64 (Max_WebSocket_Frame) then
            Fail (1_009, "WebSocket frame is too large");
         end if;
         if Opcode >= 8 and then Size > 125 then
            Fail (1_002, "oversized WebSocket control frame");
         elsif Opcode in 1 | 2
           and then Size > Interfaces.Unsigned_64 (Message_Limit)
         then
            Fail (1_009, "WebSocket message is too large");
         elsif Opcode = 0
           and then
             (Size > Interfaces.Unsigned_64 (Message_Limit)
              or else Interfaces.Unsigned_64
                (Flyology.Bytes.Length (Item.WebSocket_Message)) >
                  Interfaces.Unsigned_64 (Message_Limit) - Size)
         then
            Fail (1_009, "WebSocket message is too large");
         end if;
         Ensure_Pending
           (Item, Header_Size + 4 + Natural (Size),
            Ada.Real_Time.Clock, Time_Left, Token);
         declare
            Buffer : constant String := To_String (Item.Pending);
            Mask_First : constant Natural := Header_Size + 1;
            Payload_First : constant Natural := Header_Size + 5;
            Payload : Ada.Streams.Stream_Element_Array
              (1 .. Ada.Streams.Stream_Element_Offset (Size));
         begin
            for Index in 1 .. Natural (Size) loop
               Payload (Ada.Streams.Stream_Element_Offset (Index)) :=
                 Ada.Streams.Stream_Element
                   (Interfaces.Unsigned_8
                      (Character'Pos (Buffer (Payload_First + Index - 1)))
                    xor Interfaces.Unsigned_8
                      (Character'Pos
                         (Buffer (Mask_First + ((Index - 1) mod 4)))));
            end loop;
            Consume (Item, Header_Size + 4 + Natural (Size));
            case Opcode is
               when 0 =>
                  if not Item.WebSocket_Fragmented then
                     Fail (1_002, "unexpected WebSocket continuation frame");
                  elsif Payload'Length > Message_Limit
                    or else Flyology.Bytes.Length (Item.WebSocket_Message) >
                      Message_Limit - Payload'Length
                  then
                     Fail (1_009, "WebSocket message is too large");
                  end if;
                  Flyology.Bytes.Append
                    (Item.WebSocket_Message, Payload);
                  if Final then
                     Finish_Message;
                     return;
                  end if;
               when 1 =>
                  if Item.WebSocket_Fragmented then
                     Fail (1_002, "new data frame inside fragmented message");
                  end if;
                  Item.WebSocket_Message_Kind := Text_Frame;
                  if Payload'Length > Message_Limit then
                     Fail (1_009, "WebSocket message is too large");
                  end if;
                  Item.WebSocket_Message :=
                    Flyology.Bytes.To_Unbounded_Bytes (Payload);
                  if Final then
                     Finish_Message;
                     return;
                  end if;
                  Item.WebSocket_Fragmented := True;
               when 2 =>
                  if Item.WebSocket_Fragmented then
                     Fail (1_002, "new data frame inside fragmented message");
                  end if;
                  Item.WebSocket_Message_Kind := Binary_Frame;
                  if Payload'Length > Message_Limit then
                     Fail (1_009, "WebSocket message is too large");
                  end if;
                  Item.WebSocket_Message :=
                    Flyology.Bytes.To_Unbounded_Bytes (Payload);
                  if Final then
                     Finish_Message;
                     return;
                  end if;
                  Item.WebSocket_Fragmented := True;
               when 8 =>
                  if Payload'Length = 1 then
                     Fail (1_002, "invalid WebSocket close frame");
                  elsif Payload'Length >= 2 then
                     declare
                        Code : constant Natural :=
                          Natural (Payload (Payload'First)) * 256
                          + Natural (Payload (Payload'First + 1));
                        Reason : constant String :=
                          Text
                            (Payload
                               (Payload'First + 2 .. Payload'Last));
                     begin
                        if not Valid_Close_Code (Code) then
                           Fail (1_002, "invalid WebSocket close code");
                        elsif not Valid_UTF8 (Reason) then
                           Fail (1_007, "invalid WebSocket close reason");
                        end if;
                     end;
                  end if;
                  if not Item.WebSocket_Close_Sent then
                     Writing_Control := True;
                     Send_Frame (Item, 8, Payload, Time_Left, Token);
                     Writing_Control := False;
                     Item.WebSocket_Close_Sent := True;
                  end if;
                  Item.State := Terminal;
                  Closed := True;
                  Abandon_Message;
                  return;
               when 9 =>
                  Item.WebSocket_Control_Count :=
                    Item.WebSocket_Control_Count + 1;
                  if Item.WebSocket_Control_Count > 32 then
                     Fail (1_008, "too many WebSocket control frames");
                  end if;
                  Writing_Control := True;
                  Send_Frame (Item, 10, Payload, Time_Left, Token);
                  Writing_Control := False;
               when 10 =>
                  Item.WebSocket_Control_Count :=
                    Item.WebSocket_Control_Count + 1;
                  if Item.WebSocket_Control_Count > 32 then
                     Fail (1_008, "too many WebSocket control frames");
                  end if;
               when others =>
                  raise Program_Error with "unreachable WebSocket opcode";
            end case;
            Resize_Buffered
              (Item,
               Length (Item.Pending)
               + Flyology.Bytes.Length (Item.WebSocket_Message));
         end;
      end loop;
   exception
      when Flyology.IO.Timeout_Error =>
         if Writing_Control
           or else (Item.WebSocket_Message_Deadline /= Ada.Real_Time.Time_Last
                    and then Ada.Real_Time.Clock >=
                      Item.WebSocket_Message_Deadline)
         then
            Abandon_Message;
            Item.State := Terminal;
         elsif Length (Item.Pending) = 0
           and then Flyology.Bytes.Length (Item.WebSocket_Message) = 0
           and then not Item.WebSocket_Fragmented
         then
            Item.WebSocket_Receive_Active := False;
            Item.WebSocket_Message_Deadline := Ada.Real_Time.Time_Last;
            Item.WebSocket_Message_Limit := 0;
            Item.WebSocket_Control_Count := 0;
            Resize_Buffered (Item, 0);
         end if;
         raise;
      when WebSocket_Peer_EOF =>
         Abandon_Message;
         Item.State := Terminal;
         if Item.WebSocket_Close_Sent then
            Closed := True;
            return;
         end if;
         raise Protocol_Error with "peer closed inside WebSocket frame";
      when Protocol_Error =>
         Abandon_Message;
         Item.State := Terminal;
         raise;
      when others =>
         Abandon_Message;
         Item.State := Terminal;
         raise;
   end Receive_WebSocket;

   procedure Send_WebSocket
     (Item    : in out Connection;
      Kind    : WebSocket_Data_Kind;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null) is
   begin
      if Item.State /= WebSocket then
         raise Program_Error with "WebSocket connection is not active";
      end if;
      if Data'Length > Max_WebSocket_Frame then
         raise Constraint_Error with "WebSocket frame is too large";
      elsif Kind = Text_Frame
        and then not Valid_UTF8 (Text (Data))
      then
         raise Constraint_Error with "WebSocket text must contain valid UTF-8";
      end if;
      Send_Frame
        (Item, (if Kind = Text_Frame then 1 else 2), Data, Timeout, Token);
   exception
      when others =>
         Item.Pending := Null_Unbounded_String;
         Flyology.Bytes.Clear (Item.WebSocket_Message);
         Item.WebSocket_Fragmented := False;
         Item.WebSocket_Receive_Active := False;
         Item.WebSocket_Message_Deadline := Ada.Real_Time.Time_Last;
         Release_Buffered (Item);
         Item.Request_Close := True;
         Item.State := Terminal;
         raise;
   end Send_WebSocket;

   procedure Send_WebSocket
     (Item    : in out Connection;
      Data    : String;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null) is
   begin
      if not Valid_UTF8 (Data) then
         raise Constraint_Error with "WebSocket text must contain valid UTF-8";
      end if;
      Send_WebSocket (Item, Text_Frame, Bytes (Data), Timeout, Token);
   end Send_WebSocket;

   procedure Close_WebSocket
     (Item    : in out Connection;
      Code    : Positive := 1_000;
      Reason  : String := "";
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null)
   is
      function Valid_Server_Close_Code return Boolean is
        ((Code in 1_000 .. 1_015
          and then Code not in 1_004 .. 1_006 | 1_010 | 1_015)
         or else (Code in 3_000 .. 4_999));
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;

      function Time_Left return Duration is
         Elapsed : constant Duration := Ada.Real_Time.To_Duration
           (Ada.Real_Time.Clock - Started);
      begin
         if Timeout < 0.0 then
            return -1.0;
         elsif Elapsed >= Timeout then
            return 0.0;
         else
            return Timeout - Elapsed;
         end if;
      end Time_Left;
   begin
      if Item.State /= WebSocket then
         raise Program_Error with "WebSocket connection is not active";
      end if;
      if not Valid_Server_Close_Code
        or else Reason'Length > 123
        or else not Valid_UTF8 (Reason)
      then
         raise Constraint_Error with "invalid WebSocket close payload";
      end if;
      Flyology.Bytes.Clear (Item.WebSocket_Message);
      Item.WebSocket_Fragmented := False;
      Item.WebSocket_Receive_Active := False;
      Item.WebSocket_Message_Deadline := Ada.Real_Time.Time_Last;
      Item.WebSocket_Message_Limit := 0;
      Resize_Buffered (Item, Length (Item.Pending));
      Send_Frame
        (Item, 8,
         Character'Val (Code / 256) & Character'Val (Code mod 256) & Reason,
         Time_Left, Token);
      Item.WebSocket_Close_Sent := True;
      loop
         declare
            Kind   : WebSocket_Data_Kind;
            Data   : Flyology.Bytes.Unbounded_Bytes;
            Closed : Boolean;
            Left   : constant Duration := Time_Left;
         begin
            if Left = 0.0 then
               raise Flyology.IO.Timeout_Error with
                 "WebSocket close handshake expired";
            end if;
            Receive_WebSocket
              (Item, Kind, Data, Closed,
               Timeout => Left, Message_Timeout => Left, Token => Token);
            exit when Closed;
         end;
      end loop;
      Release_Buffered (Item);
   exception
      when others =>
         Item.State := Terminal;
         Flyology.Bytes.Clear (Item.WebSocket_Message);
         Item.WebSocket_Fragmented := False;
         Item.WebSocket_Receive_Active := False;
         Item.WebSocket_Message_Deadline := Ada.Real_Time.Time_Last;
         Item.WebSocket_Message_Limit := 0;
         Release_Buffered (Item);
         raise;
   end Close_WebSocket;

end Flyology.HTTP.Server;
