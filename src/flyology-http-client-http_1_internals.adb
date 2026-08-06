separate (Flyology.HTTP.Client)
--  Implements HTTP/1 request framing, strict response parsing, and streaming
--  body decoding. Pool and transport establishment policy remain in siblings.
package body HTTP_1_Internals is
   function Request_Head
     (State         : Client_State;
      Value         : Request;
      Streaming     : Boolean;
      Stream_Length : Body_Length;
      Use_Expectation : Boolean) return String
   is
      Result : Unbounded_String;
      Body_Length : constant Natural :=
        Flyology.Bytes.Length (Value.Body_Value);
   begin
      Validate_Request (Value);
      Append
        (Result, Image (Value.Method_Value) & " " &
         To_String (Value.Target_Value) & " HTTP/1.1" & CRLF);
      Append (Result, "Host: " & Host_Field (State.Origin_Value) & CRLF);
      for Index in 1 .. Flyology.HTTP.Headers.Count (Value.Fields) loop
         Append
           (Result, Flyology.HTTP.Headers.Name (Value.Fields, Index) & ": " &
            Flyology.HTTP.Headers.Value (Value.Fields, Index) & CRLF);
      end loop;
      if Use_Expectation
        and then
          (Body_Length > 0
             or else
               (Streaming
                  and then
                    (not Stream_Length.Is_Known
                       or else Stream_Length.Bytes > 0)))
      then
         Append (Result, "Expect: 100-continue" & CRLF);
      end if;
      if Streaming and then Stream_Length.Is_Known then
         Append
           (Result,
            "Content-Length: " & Decimal (Stream_Length.Bytes) & CRLF);
      elsif Streaming then
         Append (Result, "Transfer-Encoding: chunked" & CRLF);
      elsif Body_Length > 0 then
         Append (Result, "Content-Length: " & Decimal (Body_Length) & CRLF);
      end if;
      if Streaming
        and then not Stream_Length.Is_Known
        and then Flyology.HTTP.Headers.Count (Value.Trailer_Fields) > 0
      then
         Append (Result, "Trailer: ");
         for Index in 1 .. Flyology.HTTP.Headers.Count
           (Value.Trailer_Fields)
         loop
            if Index > 1 then
               Append (Result, ", ");
            end if;
            Append
              (Result,
               Flyology.HTTP.Headers.Name (Value.Trailer_Fields, Index));
         end loop;
         Append (Result, CRLF);
      end if;
      Append (Result, CRLF);
      return To_String (Result);
   end Request_Head;

   procedure Send_Streaming_Body
     (Data   : in out Response_Data;
      Source : in out Request_Body_Source'Class;
      Length : Body_Length;
      Trailers : Flyology.HTTP.Headers.List;
      Token  : access Flyology.Cancellation.Token)
   is
      Buffer    : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Request_Buffer_Size));
      Last      : Ada.Streams.Stream_Element_Offset;
      Finished  : Boolean;
      Remaining_Bytes : Body_Size := Length.Bytes;

      function Produced return Natural is
      begin
         if Last < Buffer'First - 1 or else Last > Buffer'Last then
            raise Request_Body_Error with
              "request body source returned an invalid last index";
         elsif Last < Buffer'First then
            return 0;
         end if;
         return Natural (Last - Buffer'First + 1);
      end Produced;

      procedure Pull is
      begin
         begin
            Read
              (Source, Buffer, Last, Finished,
               Remaining (Data.Started, Data.Timeout), Token);
         exception
            when others =>
               Data.Source_Failed := True;
               raise;
         end;
      end Pull;

      procedure Validate_Pull
        (Length_Known : Boolean; Remaining : Body_Size)
      is
         Action : constant Pull_Action := Classify_Pull
           (Length_Known => Length_Known,
            Produced     => Body_Byte_Count (Produced),
            Remaining    => Body_Byte_Count (Remaining),
            Finished     => Finished);
      begin
         case Action is
            when Accept_Pull =>
               null;
            when Reject_No_Progress =>
               raise Request_Body_Error with
                 "request body source made no progress";
            when Reject_Too_Long =>
               raise Request_Body_Error with
                 "request body source exceeded its declared length";
            when Reject_Too_Short =>
               raise Request_Body_Error with
                 "request body source ended before its declared length";
            when Reject_Not_Finished =>
               raise Request_Body_Error with
                 "request body source did not finish at its declared length";
         end case;
      end Validate_Pull;

      procedure Send_Data (Count : Natural) is
      begin
         if Count > 0 then
            Connections.Send_All
              (Data.Connection.Channel,
               Buffer
                 (Buffer'First ..
                    Buffer'First + Ada.Streams.Stream_Element_Offset
                      (Count - 1)),
               Remaining (Data.Started, Data.Timeout), Token => Token);
         end if;
      end Send_Data;
   begin
      if Length.Is_Known then
         while Remaining_Bytes > 0 loop
            Pull;
            declare
               Count : constant Natural := Produced;
            begin
               Validate_Pull (True, Remaining_Bytes);
               Send_Data (Count);
               Remaining_Bytes := Remaining_Bytes - Body_Size (Count);
            end;
         end loop;
      else
         loop
            Pull;
            Validate_Pull (False, 0);
            declare
               Count : constant Natural := Produced;
            begin
               if Count > 0 then
                  Connections.Send_All
                    (Data.Connection.Channel,
                     Byte_Array (Hexadecimal (Count) & CRLF),
                     Remaining (Data.Started, Data.Timeout),
                     Token => Token);
                  Send_Data (Count);
                  Connections.Send_All
                    (Data.Connection.Channel, Byte_Array (CRLF),
                     Remaining (Data.Started, Data.Timeout),
                     Token => Token);
               end if;
            end;
            exit when Finished;
         end loop;
         Connections.Send_All
           (Data.Connection.Channel, Byte_Array ("0" & CRLF),
            Remaining (Data.Started, Data.Timeout), Token => Token);
         for Index in 1 .. Flyology.HTTP.Headers.Count (Trailers) loop
            Connections.Send_All
              (Data.Connection.Channel,
               Byte_Array
                 (Flyology.HTTP.Headers.Name (Trailers, Index) & ": " &
                  Flyology.HTTP.Headers.Value (Trailers, Index) & CRLF),
               Remaining (Data.Started, Data.Timeout), Token => Token);
         end loop;
         Connections.Send_All
           (Data.Connection.Channel, Byte_Array (CRLF),
            Remaining (Data.Started, Data.Timeout), Token => Token);
      end if;
   end Send_Streaming_Body;

   procedure Receive_More
     (Data        : in out Response_Data;
      Peer_Closed : out Boolean;
      Token       : access Flyology.Cancellation.Token;
      Maximum_Wait : Duration := Flyology.IO.Infinite)
   is
      Buffer : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Receive_Buffer_Size));
      Last   : Ada.Streams.Stream_Element_Offset;
      Whole_Wait : constant Duration := Remaining
        (Data.Started, Data.Timeout);
      Wait : constant Duration :=
        (if Maximum_Wait < 0.0 then Whole_Wait
         elsif Whole_Wait < 0.0 then Maximum_Wait
         else Duration'Min (Whole_Wait, Maximum_Wait));
   begin
      Connections.Receive
        (Data.Connection.Channel, Buffer, Last,
         Wait, Token => Token);
      Peer_Closed := Last < Buffer'First;
      if not Peer_Closed then
         Data.Saw_Response_Bytes := True;
         Append (Data.Pending, Byte_String (Buffer (Buffer'First .. Last)));
      end if;
   end Receive_More;

   procedure Reset_Attempt (Data : in out Response_Data) is
   begin
      Flyology.HTTP.Headers.Clear (Data.Fields);
      Flyology.HTTP.Headers.Clear (Data.Trailers);
      Data.Connection := null;
      Data.Slot_Index := 0;
      Data.Status_Value := 200;
      Data.Reason_Value := Null_Unbounded_String;
      Data.Protocol_Value := HTTP_1_1_Protocol;
      Data.Version_Value := HTTP_1_1;
      Data.Pending := Null_Unbounded_String;
      Data.Mode := No_Body;
      Data.Remaining_Body := 0;
      Data.Chunk_Remaining := 0;
      Data.Need_Chunk_CRLF := False;
      Data.Reading_Trailers := False;
      Data.Complete := False;
      Data.Reusable := False;
      Data.Saw_Response_Bytes := False;
      Data.Source_Failed := False;
      Data.Informational_Count := 0;
   end Reset_Attempt;

   function Trim_OWS (Value : String) return String is
      First : Natural := Value'First;
      Last  : Natural := Value'Last;
   begin
      while First <= Last
        and then Value (First) in ' ' | Character'Val (9)
      loop
         First := First + 1;
      end loop;
      while Last >= First and then Value (Last) in ' ' | Character'Val (9) loop
         Last := Last - 1;
      end loop;
      return Value (First .. Last);
   end Trim_OWS;

   function Header_Has_Token
     (Fields : Flyology.HTTP.Headers.List; Name : String; Token : String)
      return Boolean
   is
      use Ada.Characters.Handling;
   begin
      for Occurrence in 1 .. Flyology.HTTP.Headers.Count (Fields, Name) loop
         declare
            Text  : constant String :=
              Flyology.HTTP.Headers.Value (Fields, Name, Occurrence);
            First : Natural := Text'First;
         begin
            while First <= Text'Last loop
               declare
                  Comma : constant Natural := Ada.Strings.Fixed.Index
                    (Text (First .. Text'Last), ",");
                  Last : constant Natural :=
                    (if Comma = 0 then Text'Last else Comma - 1);
               begin
                  if To_Lower (Trim_OWS (Text (First .. Last))) =
                    To_Lower (Token)
                  then
                     return True;
                  end if;
                  exit when Comma = 0;
                  First := Comma + 1;
               end;
            end loop;
         end;
      end loop;
      return False;
   end Header_Has_Token;

   function Parse_Natural (Value : String) return Natural is
      Result : Natural := 0;
   begin
      if Value = "" then
         raise Protocol_Error with "empty HTTP decimal value";
      end if;
      for Item of Value loop
         if Item not in '0' .. '9'
           or else Result >
             (Natural'Last - (Character'Pos (Item) - Character'Pos ('0'))) / 10
         then
            raise Protocol_Error with
              "invalid or overflowing HTTP decimal value";
         end if;
         Result := Result * 10 + Character'Pos (Item) - Character'Pos ('0');
      end loop;
      return Result;
   end Parse_Natural;

   function Content_Length
     (Fields  : Flyology.HTTP.Headers.List;
      Present : out Boolean) return Natural
   is
      Expected : Natural := 0;
      Have     : Boolean := False;
   begin
      for Occurrence in 1 .. Flyology.HTTP.Headers.Count
        (Fields, "Content-Length")
      loop
         declare
            Text  : constant String := Flyology.HTTP.Headers.Value
              (Fields, "Content-Length", Occurrence);
            First : Natural := Text'First;
         begin
            loop
               declare
                  Comma : constant Natural := Ada.Strings.Fixed.Index
                    (Text (First .. Text'Last), ",");
                  Last : constant Natural :=
                    (if Comma = 0 then Text'Last else Comma - 1);
                  Parsed : constant Natural :=
                    Parse_Natural (Trim_OWS (Text (First .. Last)));
               begin
                  if Have and then Parsed /= Expected then
                     raise Protocol_Error with "conflicting Content-Length";
                  end if;
                  Expected := Parsed;
                  Have := True;
                  exit when Comma = 0;
                  First := Comma + 1;
               end;
            end loop;
         end;
      end loop;
      Present := Have;
      return Expected;
   end Content_Length;

   procedure Parse_Response_Head
     (Data : in out Response_Data; Head : String)
   is
      First_CRLF : constant Natural := Ada.Strings.Fixed.Index (Head, CRLF);
      Cursor     : Natural;
      Status_Line : constant String :=
        (if First_CRLF = 0 then Head else Head (Head'First .. First_CRLF - 1));
   begin
      Flyology.HTTP.Headers.Clear (Data.Fields);
      if Status_Line'Length < 12
        or else Status_Line (Status_Line'First + 8) /= ' '
      then
         raise Protocol_Error with "malformed HTTP response status line";
      elsif Status_Line
        (Status_Line'First .. Status_Line'First + 7) = "HTTP/1.1"
      then
         Data.Version_Value := HTTP_1_1;
      elsif Status_Line
        (Status_Line'First .. Status_Line'First + 7) = "HTTP/1.0"
      then
         Data.Version_Value := HTTP_1_0;
      else
         raise Protocol_Error with "unsupported HTTP response version";
      end if;
      declare
         Start : constant Natural := Status_Line'First + 9;
         Parsed : Natural;
      begin
         if Status_Line'Last < Start + 2
           or else (for some Index in Start .. Start + 2 =>
                      Status_Line (Index) not in '0' .. '9')
           or else
             (Status_Line'Last > Start + 2
                and then Status_Line (Start + 3) /= ' ')
         then
            raise Protocol_Error with "malformed HTTP response status";
         end if;
         Parsed :=
           (Character'Pos (Status_Line (Start)) - Character'Pos ('0')) * 100
           + (Character'Pos (Status_Line (Start + 1))
              - Character'Pos ('0')) * 10
           + Character'Pos (Status_Line (Start + 2)) - Character'Pos ('0');
         if Parsed not in Status_Code then
            raise Protocol_Error with "invalid HTTP response status";
         end if;
         if Status_Line'Last > Start + 3
           and then
             (for some Index in Start + 4 .. Status_Line'Last =>
                (Character'Pos (Status_Line (Index)) < 32
                   and then Status_Line (Index) /= Character'Val (9))
                  or else Character'Pos (Status_Line (Index)) = 127)
         then
            raise Protocol_Error with "invalid HTTP response reason phrase";
         end if;
         Data.Status_Value := Status_Code (Parsed);
         Data.Reason_Value :=
           (if Status_Line'Last > Start + 3
            then To_Unbounded_String
              (Status_Line (Start + 4 .. Status_Line'Last))
            else Null_Unbounded_String);
      end;

      Cursor := First_CRLF + CRLF'Length;
      while Cursor <= Head'Last loop
         declare
            Mark : constant Natural := Ada.Strings.Fixed.Index
              (Head (Cursor .. Head'Last), CRLF);
            Line_Last : constant Natural :=
              (if Mark = 0 then Head'Last else Mark - 1);
            Colon : Natural;
         begin
            exit when Line_Last < Cursor;
            if Head (Cursor) in ' ' | Character'Val (9) then
               raise Protocol_Error with "obsolete folded HTTP response field";
            end if;
            Colon := Ada.Strings.Fixed.Index (Head (Cursor .. Line_Last), ":");
            if Colon = 0 or else Colon = Cursor then
               raise Protocol_Error with "malformed HTTP response field";
            end if;
            begin
               Flyology.HTTP.Headers.Add
                 (Data.Fields, Head (Cursor .. Colon - 1),
                  Trim_OWS (Head (Colon + 1 .. Line_Last)));
            exception
               when Flyology.HTTP.Headers.Headers_Too_Large =>
                  raise Response_Too_Large;
               when Constraint_Error =>
                  raise Protocol_Error with "invalid HTTP response field";
            end;
            exit when Mark = 0;
            Cursor := Mark + CRLF'Length;
         end;
      end loop;
   end Parse_Response_Head;

   procedure Read_Next_Head
     (Data         : in out Response_Data;
      Token        : access Flyology.Cancellation.Token;
      Maximum_Wait : Duration := Flyology.IO.Infinite)
   is
      Closed       : Boolean;
      Read_Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;

      function Wait_Remaining return Duration is
      begin
         if Maximum_Wait < 0.0 then
            return Flyology.IO.Infinite;
         end if;
         return Flyology.Time_Math.Remaining
           (Maximum_Wait,
            Ada.Real_Time.To_Duration
              (Ada.Real_Time.Clock - Read_Started));
      end Wait_Remaining;
   begin
      loop
         declare
            Text : constant String := To_String (Data.Pending);
            Mark : constant Natural := Ada.Strings.Fixed.Index
              (Text, CRLF & CRLF);
         begin
            if Mark /= 0 then
               declare
                  Head_Last : constant Natural := Mark + CRLF'Length - 1;
               begin
                  if Head_Last - Text'First + 1 >
                    Flyology.HTTP.Headers.Default_Max_Bytes
                  then
                     raise Response_Too_Large;
                  end if;
                  Parse_Response_Head
                    (Data, Text (Text'First .. Head_Last));
                  Data.Pending :=
                    (if Head_Last = Text'Last
                     then Null_Unbounded_String
                     else To_Unbounded_String
                       (Text (Head_Last + CRLF'Length + 1 .. Text'Last)));
               end;
               return;
            elsif Text'Length >=
              Flyology.HTTP.Headers.Default_Max_Bytes
            then
               raise Response_Too_Large;
            end if;
         end;
         Receive_More (Data, Closed, Token, Wait_Remaining);
         if Closed then
            raise Protocol_Error with
              "peer closed during HTTP response head";
         end if;
      end loop;
   end Read_Next_Head;

   procedure Accept_Informational (Data : in out Response_Data) is
      Action : constant Informational_Action := Classify_Informational
        (Status           => Data.Status_Value,
         Has_Body_Framing =>
           Flyology.HTTP.Headers.Count (Data.Fields, "Content-Length") > 0
             or else Flyology.HTTP.Headers.Count
               (Data.Fields, "Transfer-Encoding") > 0,
         Accepted         => Data.Informational_Count);
   begin
      case Action is
         when Accept_Continue | Accept_Other_Informational =>
            Data.Informational_Count :=
              Next_Informational_Count (Data.Informational_Count);
         when Reject_Upgrade =>
            raise Protocol_Error with "HTTP protocol upgrade is unsupported";
         when Reject_Informational_Framing =>
            raise Protocol_Error with
              "informational HTTP response contains body framing";
         when Reject_Informational_Excess =>
            raise Protocol_Error with
              "too many informational HTTP responses";
      end case;
   end Accept_Informational;

   procedure Read_Final_Head
     (Data  : in out Response_Data;
      Token : access Flyology.Cancellation.Token) is
   begin
      loop
         Read_Next_Head (Data, Token);
         exit when Data.Status_Value not in 100 .. 199;
         Accept_Informational (Data);
      end loop;
   end Read_Final_Head;

   procedure Await_Continue
     (Data         : in out Response_Data;
      Wait_Timeout : Duration;
      Token        : access Flyology.Cancellation.Token;
      Final_Ready  : out Boolean)
   is
      Wait_Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;

      function Continue_Remaining return Duration is
      begin
         if Wait_Timeout < 0.0 then
            return Flyology.IO.Infinite;
         end if;
         return Flyology.Time_Math.Remaining
           (Wait_Timeout,
            Ada.Real_Time.To_Duration
              (Ada.Real_Time.Clock - Wait_Started));
      end Continue_Remaining;

      function Read_Within_Continue_Wait return Boolean is
         Continue_Wait : constant Duration := Continue_Remaining;
         Whole_Wait    : constant Duration := Remaining
           (Data.Started, Data.Timeout);
         Continue_Is_Limit : constant Boolean :=
           Continue_Wait >= 0.0
             and then (Whole_Wait < 0.0 or else Continue_Wait < Whole_Wait);
      begin
         if Continue_Wait = 0.0 and then Length (Data.Pending) = 0 then
            return False;
         end if;
         begin
            Read_Next_Head (Data, Token, Continue_Wait);
            return True;
         exception
            when Flyology.IO.Timeout_Error =>
               if not Continue_Is_Limit then
                  raise;
               elsif Length (Data.Pending) = 0 then
                  return False;
               else
                  --  Do not interleave a request body with a partially
                  --  received response head. Finish it under the whole
                  --  exchange deadline instead of applying the fallback.
                  Read_Next_Head (Data, Token);
                  return True;
               end if;
         end;
      end Read_Within_Continue_Wait;
   begin
      Final_Ready := False;
      loop
         exit when not Read_Within_Continue_Wait;
         if Data.Status_Value not in 100 .. 199 then
            Final_Ready := True;
            return;
         end if;
         Accept_Informational (Data);
         if Data.Status_Value = 100 then
            return;
         end if;
      end loop;
   end Await_Continue;

   procedure Select_Body_Mode
     (Data : in out Response_Data; Request_Method : Method)
   is
      Length_Present : Boolean;
      Length_Value   : constant Natural := Content_Length
        (Data.Fields, Length_Present);
      Transfer_Count : constant Natural := Flyology.HTTP.Headers.Count
        (Data.Fields, "Transfer-Encoding");
      Close_Token : constant Boolean := Header_Has_Token
        (Data.Fields, "Connection", "close");
      Keep_Token : constant Boolean := Header_Has_Token
        (Data.Fields, "Connection", "keep-alive");
   begin
      Data.Reusable :=
        (if Data.Version_Value = HTTP_1_1
         then not Close_Token else Keep_Token);
      if Data.Status_Value = 204
        and then (Length_Present or else Transfer_Count > 0)
      then
         raise Protocol_Error with "204 response contains body framing";
      elsif Data.Status_Value = 205
        and then (Transfer_Count > 0
                    or else (Length_Present and then Length_Value /= 0))
      then
         raise Protocol_Error with "205 response contains a nonempty body";
      elsif Data.Version_Value = HTTP_1_0 and then Transfer_Count > 0 then
         raise Protocol_Error with
           "HTTP/1.0 response contains Transfer-Encoding";
      end if;
      if Image (Request_Method) = "HEAD"
        or else Data.Status_Value in 100 .. 199 | 204 | 205 | 304
      then
         Data.Mode := No_Body;
      elsif Transfer_Count > 0 then
         if Length_Present then
            raise Protocol_Error with
              "HTTP response has both Transfer-Encoding and Content-Length";
         elsif Transfer_Count /= 1
           or else Ada.Characters.Handling.To_Lower
             (Trim_OWS
                (Flyology.HTTP.Headers.Value
                   (Data.Fields, "Transfer-Encoding"))) /= "chunked"
         then
            raise Protocol_Error with
              "unsupported HTTP response transfer coding";
         end if;
         Data.Mode := Chunked_Body;
      elsif Length_Present then
         Data.Mode := (if Length_Value = 0 then No_Body else Fixed_Body);
         Data.Remaining_Body := Length_Value;
      else
         Data.Mode := Until_Close_Body;
         Data.Reusable := False;
      end if;
      if Data.Mode = No_Body then
         if Length (Data.Pending) > 0 then
            --  Bytes following a bodyless response may only be a response to a
            --  pipelined request, which this client never sends.
            Data.Reusable := False;
         end if;
         Release_Lease (Data, Data.Reusable);
      end if;
   end Select_Body_Mode;

   procedure Remove_Pending_Prefix
     (Data : in out Response_Data; Count : Natural);
   function Chunk_Size (Line : String) return Natural;
   procedure Add_Trailer (Data : in out Response_Data; Line : String);

   procedure Validate_Response
     (Value : Ada.Streams.Stream_Element_Array)
   is
      Data          : Response_Data;
      Informational : Informational_Count := 0;

      procedure Take_Line (Line : out Unbounded_String) is
         Text : constant String := To_String (Data.Pending);
         Mark : constant Natural := Ada.Strings.Fixed.Index (Text, CRLF);
      begin
         if Mark = 0 then
            raise Protocol_Error with "incomplete HTTP framing line";
         end if;
         Line := To_Unbounded_String (Text (Text'First .. Mark - 1));
         Remove_Pending_Prefix (Data, Mark - Text'First + CRLF'Length);
      end Take_Line;
   begin
      Data.Pending := To_Unbounded_String (Byte_String (Value));
      loop
         declare
            Text : constant String := To_String (Data.Pending);
            Mark : constant Natural := Ada.Strings.Fixed.Index
              (Text, CRLF & CRLF);
         begin
            if Mark = 0 then
               if Text'Length >= Flyology.HTTP.Headers.Default_Max_Bytes then
                  raise Response_Too_Large;
               end if;
               raise Protocol_Error with "incomplete HTTP response head";
            end if;
            declare
               Head_Last : constant Natural := Mark + CRLF'Length - 1;
            begin
               if Head_Last - Text'First + 1 >
                 Flyology.HTTP.Headers.Default_Max_Bytes
               then
                  raise Response_Too_Large;
               end if;
               Parse_Response_Head (Data, Text (Text'First .. Head_Last));
               Data.Pending :=
                 (if Head_Last + CRLF'Length >= Text'Last
                  then Null_Unbounded_String
                  else To_Unbounded_String
                    (Text (Head_Last + CRLF'Length + 1 .. Text'Last)));
            end;
         end;
         exit when Data.Status_Value not in 100 .. 199;
         case Classify_Informational
           (Status           => Data.Status_Value,
            Has_Body_Framing =>
              Flyology.HTTP.Headers.Count (Data.Fields, "Content-Length") > 0
                or else Flyology.HTTP.Headers.Count
                  (Data.Fields, "Transfer-Encoding") > 0,
            Accepted         => Informational)
         is
            when Accept_Continue | Accept_Other_Informational =>
               Informational := Next_Informational_Count (Informational);
            when Reject_Upgrade =>
               raise Protocol_Error with
                 "HTTP protocol upgrade is unsupported";
            when Reject_Informational_Framing =>
               raise Protocol_Error with
                 "informational HTTP response contains body framing";
            when Reject_Informational_Excess =>
               raise Protocol_Error with
                 "too many informational HTTP responses";
         end case;
      end loop;

      Select_Body_Mode (Data, To_Method ("GET"));
      case Data.Mode is
         when No_Body | Until_Close_Body =>
            null;
         when Fixed_Body =>
            if Length (Data.Pending) < Data.Remaining_Body then
               raise Protocol_Error with
                 "peer closed before Content-Length was received";
            end if;
         when Chunked_Body =>
            loop
               declare
                  Line : Unbounded_String;
                  Size : Natural;
               begin
                  Take_Line (Line);
                  Size := Chunk_Size (To_String (Line));
                  if Size = 0 then
                     loop
                        Take_Line (Line);
                        exit when Length (Line) = 0;
                        Add_Trailer (Data, To_String (Line));
                     end loop;
                     exit;
                  end if;
                  if Length (Data.Pending) < Size + CRLF'Length then
                     raise Protocol_Error with "incomplete HTTP chunk data";
                  end if;
                  declare
                     Text : constant String := To_String (Data.Pending);
                     CRLF_First : constant Natural := Text'First + Size;
                  begin
                     if Text (CRLF_First .. CRLF_First + 1) /= CRLF then
                        raise Protocol_Error with
                          "missing CRLF after HTTP chunk data";
                     end if;
                  end;
                  Remove_Pending_Prefix (Data, Size + CRLF'Length);
               end;
            end loop;
      end case;
   end Validate_Response;
   procedure Remove_Pending_Prefix
     (Data : in out Response_Data; Count : Natural)
   is
      Text : constant String := To_String (Data.Pending);
   begin
      if Count = 0 then
         return;
      elsif Count >= Text'Length then
         Data.Pending := Null_Unbounded_String;
      else
         Data.Pending := To_Unbounded_String
           (Text (Text'First + Count .. Text'Last));
      end if;
   end Remove_Pending_Prefix;

   procedure Copy_Pending
     (Source : in out Response_Data;
      Target : in out Ada.Streams.Stream_Element_Array;
      Used   : in out Natural;
      Limit  : Natural)
   is
      Text      : constant String := To_String (Source.Pending);
      Available : constant Natural := Text'Length;
      Room      : constant Natural := Natural (Target'Length) - Used;
      Count     : constant Natural := Natural'Min
        (Available, Natural'Min (Room, Limit));
   begin
      if Count = 0 then
         return;
      end if;
      for Offset in 0 .. Count - 1 loop
         Target
           (Target'First
              + Ada.Streams.Stream_Element_Offset (Used + Offset)) :=
             Ada.Streams.Stream_Element
               (Character'Pos (Text (Text'First + Offset)));
      end loop;
      Used := Used + Count;
      Remove_Pending_Prefix (Source, Count);
   end Copy_Pending;

   procedure Ensure_Pending
     (Data    : in out Response_Data;
      Minimum : Positive;
      Token   : access Flyology.Cancellation.Token)
   is
      Closed : Boolean;
   begin
      while Length (Data.Pending) < Minimum loop
         Receive_More (Data, Closed, Token);
         if Closed then
            raise Protocol_Error with
              "peer closed during HTTP response framing";
         end if;
      end loop;
   end Ensure_Pending;

   function Chunk_Size (Line : String) return Natural is
      Semicolon : constant Natural := Ada.Strings.Fixed.Index (Line, ";");
      Last      : constant Natural :=
        (if Semicolon = 0 then Line'Last else Semicolon - 1);
      Result    : Natural := 0;
      Digit     : Natural;
   begin
      if Line'Length = 0 or else Last < Line'First then
         raise Protocol_Error with "empty HTTP chunk size";
      end if;
      for Index in Line'Range loop
         if Character'Pos (Line (Index)) < 32
           or else Character'Pos (Line (Index)) = 127
         then
            raise Protocol_Error with "invalid HTTP chunk extension";
         end if;
      end loop;
      for Index in Line'First .. Last loop
         case Line (Index) is
            when '0' .. '9' =>
               Digit := Character'Pos (Line (Index)) - Character'Pos ('0');
            when 'a' .. 'f' =>
               Digit := Character'Pos (Line (Index))
                 - Character'Pos ('a') + 10;
            when 'A' .. 'F' =>
               Digit := Character'Pos (Line (Index))
                 - Character'Pos ('A') + 10;
            when others =>
               raise Protocol_Error with "invalid HTTP chunk size";
         end case;
         if Result > (Natural'Last - Digit) / 16 then
            raise Protocol_Error with "overflowing HTTP chunk size";
         end if;
         Result := Result * 16 + Digit;
      end loop;
      return Result;
   end Chunk_Size;

   procedure Read_Chunk_Line
     (Data  : in out Response_Data;
      Line  : out Unbounded_String;
      Token : access Flyology.Cancellation.Token)
   is
      Closed : Boolean;
   begin
      loop
         declare
            Text : constant String := To_String (Data.Pending);
            Mark : constant Natural := Ada.Strings.Fixed.Index (Text, CRLF);
         begin
            if Mark /= 0 then
               Line := To_Unbounded_String (Text (Text'First .. Mark - 1));
               Remove_Pending_Prefix (Data, Mark - Text'First + CRLF'Length);
               return;
            elsif Text'Length >= Flyology.HTTP.Headers.Default_Max_Bytes then
               raise Protocol_Error with
                 "HTTP chunk line exceeds framing bound";
            end if;
         end;
         Receive_More (Data, Closed, Token);
         if Closed then
            raise Protocol_Error with "peer closed during HTTP chunk framing";
         end if;
      end loop;
   end Read_Chunk_Line;

   procedure Add_Trailer (Data : in out Response_Data; Line : String) is
      Colon : constant Natural := Ada.Strings.Fixed.Index (Line, ":");
      Lower : constant String :=
        (if Colon = 0 then ""
         else Ada.Characters.Handling.To_Lower
           (Line (Line'First .. Colon - 1)));
   begin
      if Colon = 0 or else Colon = Line'First
        or else Line (Line'First) in ' ' | Character'Val (9)
      then
         raise Protocol_Error with "malformed HTTP trailer field";
      elsif Lower in
        "connection" | "content-length" | "host" | "trailer" |
        "transfer-encoding"
      then
         raise Protocol_Error with "forbidden HTTP trailer field";
      end if;
      begin
         Flyology.HTTP.Headers.Add
           (Data.Trailers, Line (Line'First .. Colon - 1),
            Trim_OWS (Line (Colon + 1 .. Line'Last)));
      exception
         when Constraint_Error | Flyology.HTTP.Headers.Headers_Too_Large =>
            raise Protocol_Error with "invalid HTTP trailer field";
      end;
   end Add_Trailer;

   procedure Read_Response_Body
     (Item     : in out Response;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Token    : access Flyology.Cancellation.Token)
   is
      Used   : Natural := 0;
      Closed : Boolean;
   begin
      for Element of Data loop
         Element := 0;
      end loop;
      Last := Data'First - 1;
      if Item.Data = null or else Item.Data.Complete then
         Finished := True;
         return;
      elsif Data'Length = 0 then
         Finished := False;
         return;
      end if;

      declare
         FD        : Flyology.IO.Descriptor;
         Requested : Boolean;
      begin
         Item.Data.Owner.Pool.Shutdown_Source (FD, Requested);
         if Requested then
            raise Client_Closed;
         end if;
      end;

      case Item.Data.Mode is
         when No_Body =>
            Release_Lease (Item.Data.all, Item.Data.Reusable);

         when Fixed_Body =>
            while Used < Natural (Data'Length)
              and then Item.Data.Remaining_Body > 0
            loop
               if Length (Item.Data.Pending) = 0 then
                  Receive_More (Item.Data.all, Closed, Token);
                  if Closed then
                     raise Protocol_Error with
                       "peer closed before Content-Length was received";
                  end if;
               end if;
               declare
                  Before : constant Natural := Used;
               begin
                  Copy_Pending
                    (Item.Data.all, Data, Used, Item.Data.Remaining_Body);
                  Item.Data.Remaining_Body := Item.Data.Remaining_Body -
                    (Used - Before);
               end;
            end loop;
            if Item.Data.Remaining_Body = 0 then
               if Length (Item.Data.Pending) > 0 then
                  Item.Data.Reusable := False;
               end if;
               Release_Lease (Item.Data.all, Item.Data.Reusable);
            end if;

         when Until_Close_Body =>
            while Used < Natural (Data'Length) loop
               if Length (Item.Data.Pending) = 0 then
                  Receive_More (Item.Data.all, Closed, Token);
                  if Closed then
                     Release_Lease (Item.Data.all, False);
                     exit;
                  end if;
               end if;
               Copy_Pending (Item.Data.all, Data, Used, Natural'Last);
            end loop;

         when Chunked_Body =>
            while Used < Natural (Data'Length) and then not Item.Data.Complete
            loop
               if Item.Data.Chunk_Remaining > 0 then
                  if Length (Item.Data.Pending) = 0 then
                     Receive_More (Item.Data.all, Closed, Token);
                     if Closed then
                        raise Protocol_Error with
                          "peer closed during HTTP chunk data";
                     end if;
                  end if;
                  declare
                     Before : constant Natural := Used;
                  begin
                     Copy_Pending
                       (Item.Data.all, Data, Used,
                        Item.Data.Chunk_Remaining);
                     Item.Data.Chunk_Remaining := Item.Data.Chunk_Remaining -
                       (Used - Before);
                  end;
                  if Item.Data.Chunk_Remaining = 0 then
                     Item.Data.Need_Chunk_CRLF := True;
                  end if;

               elsif Item.Data.Need_Chunk_CRLF then
                  Ensure_Pending
                    (Item.Data.all, CRLF'Length, Token);
                  declare
                     Text : constant String := To_String (Item.Data.Pending);
                  begin
                     if Text (Text'First .. Text'First + 1) /= CRLF then
                        raise Protocol_Error with
                          "missing CRLF after HTTP chunk data";
                     end if;
                  end;
                  Remove_Pending_Prefix (Item.Data.all, CRLF'Length);
                  Item.Data.Need_Chunk_CRLF := False;

               elsif Item.Data.Reading_Trailers then
                  declare
                     Line : Unbounded_String;
                  begin
                     Read_Chunk_Line (Item.Data.all, Line, Token);
                     if Length (Line) = 0 then
                        if Length (Item.Data.Pending) > 0 then
                           Item.Data.Reusable := False;
                        end if;
                        Release_Lease (Item.Data.all, Item.Data.Reusable);
                     else
                        Add_Trailer (Item.Data.all, To_String (Line));
                     end if;
                  end;

               else
                  declare
                     Line : Unbounded_String;
                  begin
                     Read_Chunk_Line (Item.Data.all, Line, Token);
                     Item.Data.Chunk_Remaining := Chunk_Size
                       (To_String (Line));
                     if Item.Data.Chunk_Remaining = 0 then
                        Item.Data.Reading_Trailers := True;
                     end if;
                  end;
               end if;
            end loop;
      end case;

      if Used > 0 then
         Last := Data'First + Ada.Streams.Stream_Element_Offset (Used) - 1;
      end if;
      Finished := Item.Data.Complete;
   exception
      when Flyology.Cancellation.Operation_Cancelled =>
         if Item.Data /= null and then Item.Data.Connection /= null then
            Release_Lease (Item.Data.all, False);
         end if;
         Translate_Interruption (Item.Data.Owner, Token);
      when others =>
         if Item.Data /= null and then Item.Data.Connection /= null then
            Release_Lease (Item.Data.all, False);
         end if;
         if Item.Data /= null
           and then Item.Data.Owner /= null
           and then Item.Data.Owner.Pool.Is_Stopping
         then
            raise Client_Closed;
         end if;
         raise;
   end Read_Response_Body;
end HTTP_1_Internals;
