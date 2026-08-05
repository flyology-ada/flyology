with Ada.Strings.Fixed;
with Flyology.IO;

package body Flyology.HTTP.Server.Applications is
   use type Ada.Task_Identification.Task_Id;

   CRLF : constant String := Character'Val (13) & Character'Val (10);

   procedure Require_Owner (Item : Exchange) is
   begin
      if Ada.Task_Identification.Current_Task /= Item.Owner_Task then
         raise Program_Error with
           "HTTP exchange may only be used by its connection-owner task";
      end if;
   end Require_Owner;

   function Create
      (Value    : aliased in out Request;
      Item     : aliased in out Connection;
      Peer     : Flyology.IO.Sockets.Endpoint;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time) return Exchange
   is
   begin
      return Result : Exchange
        (Request_Handle    => Value'Access,
         Connection_Handle => Item'Access,
         Token_Handle      => Token)
      do
         Result.Peer_Value := Peer;
         Result.Deadline_Value := Deadline;
      end return;
   end Create;

   function Request_Value (Item : Exchange) return Request is
     (Item.Request_Handle.all);

   function Request_Method (Item : Exchange) return String is
     (Method (Item.Request_Handle.all));

   function Request_Target (Item : Exchange) return String is
     (Target (Item.Request_Handle.all));

   function Request_Header (Item : Exchange; Name : String) return String is
     (Header (Item.Request_Handle.all, Name));

   function Request_Header_Count
     (Item : Exchange; Name : String) return Natural
   is (Header_Count (Item.Request_Handle.all, Name));

   function Wire_Response_Started (Item : Exchange) return Boolean is
     (Flyology.HTTP.Server.Response_Started (Item.Connection_Handle.all));

   function Peer (Item : Exchange) return Flyology.IO.Sockets.Endpoint is
     (Item.Peer_Value);

   function Cancellation
     (Item : Exchange) return access Flyology.Cancellation.Token
   is
     (if Item.Token_Handle = null then null
      else Item.Token_Handle.all'Unchecked_Access);

   function Deadline (Item : Exchange) return Ada.Real_Time.Time is
     (Item.Deadline_Value);

   function Remaining (Item : Exchange) return Duration is
      use type Ada.Real_Time.Time;
      Now : Ada.Real_Time.Time;
   begin
      if Item.Deadline_Value = Ada.Real_Time.Time_Last then
         return -1.0;
      end if;
      Now := Ada.Real_Time.Clock;
      if Now >= Item.Deadline_Value then
         return 0.0;
      end if;
      return Ada.Real_Time.To_Duration (Item.Deadline_Value - Now);
   end Remaining;

   procedure Narrow_Deadline
     (Item  : in out Exchange;
      Value : Ada.Real_Time.Time)
   is
      use type Ada.Real_Time.Time;
   begin
      Require_Owner (Item);
      if Value > Item.Deadline_Value then
         raise Program_Error with "HTTP exchange deadline cannot be extended";
      end if;
      Narrow_Request_Deadline (Item.Connection_Handle.all, Value);
      Item.Deadline_Value := Value;
   end Narrow_Deadline;

   function Route_Name (Item : Exchange) return String is
     (To_String (Item.Route_Value));

   function Path (Item : Exchange) return String is
     (To_String (Item.Path_Value));

   function Parameter (Item : Exchange; Name : String) return String is
   begin
      for Index in 1 .. Item.Parameter_Count loop
         if To_String (Item.Parameters (Index).Name) = Name then
            return To_String (Item.Parameters (Index).Value);
         end if;
      end loop;
      return "";
   end Parameter;

   function Has_Parameter (Item : Exchange; Name : String) return Boolean is
   begin
      for Index in 1 .. Item.Parameter_Count loop
         if To_String (Item.Parameters (Index).Name) = Name then
            return True;
         end if;
      end loop;
      return False;
   end Has_Parameter;

   function Request_ID (Item : Exchange) return String is
     (To_String (Item.Request_ID_Value));

   procedure Set_Request_ID (Item : in out Exchange; Value : String) is
   begin
      Require_Owner (Item);
      if Value'Length = 0 or else Value'Length > 128 then
         raise Program_Error with "invalid HTTP request id length";
      end if;
      for Character_Value of Value loop
         if Character_Value not in 'a' .. 'z'
           and then Character_Value not in 'A' .. 'Z'
           and then Character_Value not in '0' .. '9'
           and then Character_Value not in '-' | '.' | '_'
         then
            raise Program_Error with "invalid HTTP request id";
         end if;
      end loop;
      Item.Request_ID_Value := To_Unbounded_String (Value);
   end Set_Request_ID;

   function Has_Principal (Item : Exchange) return Boolean is
     (Item.Principal_Present);

   function Principal (Item : Exchange) return String is
     (To_String (Item.Principal_Value));

   procedure Set_Principal (Item : in out Exchange; Value : String) is
   begin
      Require_Owner (Item);
      if Value'Length = 0 or else Value'Length > 256 then
         raise Program_Error with "invalid HTTP principal length";
      end if;
      for Character_Value of Value loop
         if Character'Pos (Character_Value) < 32
           or else Character'Pos (Character_Value) = 127
         then
            raise Program_Error with "invalid HTTP principal";
         end if;
      end loop;
      Item.Principal_Value := To_Unbounded_String (Value);
      Item.Principal_Present := True;
   end Set_Principal;

   function Authentication (Item : Exchange) return Authentication_Mode is
     (Item.Authentication_Value);

   function CORS_Policy (Item : Exchange) return Natural is
     (Item.CORS_Policy_Value);

   function Concurrency_Limit (Item : Exchange) return Natural is
     (Item.Concurrency_Value);

   function Rate_Per_Second (Item : Exchange) return Natural is
     (Item.Rate_Value);

   function Body_Policy (Item : Exchange) return Request_Body_Policy is
     (Item.Body_Mode);

   function Body_State (Item : Exchange) return Request_Body_State is
   begin
      case Item.Body_Mode is
         when Reject_Body =>
            return
              (if Flyology.HTTP.Server.Body_Complete
                    (Item.Connection_Handle.all)
               then Body_Completed else Body_Rejected);
         when Stream_Body =>
            return
              (if Flyology.HTTP.Server.Body_Complete
                    (Item.Connection_Handle.all)
               then Body_Completed else Body_Streaming);
         when Buffer_Body =>
            return
              (if Flyology.HTTP.Server.Body_Complete
                    (Item.Connection_Handle.all)
               then Body_Buffered else Body_Pending);
         when Discard_Request_Body =>
            return
              (if Flyology.HTTP.Server.Body_Complete
                    (Item.Connection_Handle.all)
               then Body_Completed else Body_Pending);
      end case;
   end Body_State;

   function Body_Complete (Item : Exchange) return Boolean is
     (Flyology.HTTP.Server.Body_Complete (Item.Connection_Handle.all));

   function Request_Body_Bytes (Item : Exchange) return Natural is
     (Item.Connection_Handle.Body_Total);

   procedure Read_Body
     (Item     : in out Exchange;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean)
   is
   begin
      Require_Owner (Item);
      if Item.Body_Mode /= Stream_Body then
         raise Program_Error with "route body policy is not streamed";
      end if;
      Flyology.HTTP.Server.Read_Body
        (Item.Connection_Handle.all, Data, Last, Finished,
         Item.Token_Handle);
   end Read_Body;

   function Content (Item : Exchange) return String is
   begin
      if Item.Body_Mode /= Buffer_Body
        or else not Flyology.HTTP.Server.Body_Complete
          (Item.Connection_Handle.all)
      then
         raise Program_Error with
           "request content is available only after buffered admission";
      end if;
      return Flyology.HTTP.Server.Content (Item.Request_Handle.all);
   end Content;

   procedure Validate_Header_Name (Name : String) is
      Separators : constant String := "()<>@,;:" & Character'Val (92)
        & Character'Val (34) & "/[]?={} " & Character'Val (9);
   begin
      if Name'Length = 0 then
         raise Program_Error with "empty HTTP response header name";
      end if;
      for Value of Name loop
         if Character'Pos (Value) <= 32
           or else Character'Pos (Value) >= 127
           or else Ada.Strings.Fixed.Index
             (Separators, String'(1 => Value)) /= 0
         then
            raise Program_Error with "invalid HTTP response header name";
         end if;
      end loop;
   end Validate_Header_Name;

   procedure Validate_Header_Value (Value : String) is
   begin
      for Item of Value loop
         if (Character'Pos (Item) < 32 and then Item /= Character'Val (9))
           or else Character'Pos (Item) = 127
         then
            raise Program_Error with "invalid HTTP response header value";
         end if;
      end loop;
   end Validate_Header_Value;

   procedure Add_Header
     (Item  : in out Exchange;
      Name  : String;
      Value : String)
   is
   begin
      Require_Owner (Item);
      if Item.Response_Value /= Not_Started then
         raise Program_Error with "HTTP response already started";
      end if;
      Validate_Header_Name (Name);
      Validate_Header_Value (Value);
      Append (Item.Extra_Headers, Name & ": " & Value & CRLF);
   end Add_Header;

   procedure Respond
     (Item         : in out Exchange;
      Status       : Positive;
      Content_Type : String;
      Payload      : String;
      Close        : Boolean := False)
   is
      Is_Head : constant Boolean :=
        Method (Item.Request_Handle.all) = "HEAD";
   begin
      Require_Owner (Item);
      if Item.Response_Value /= Not_Started then
         raise Program_Error with "HTTP exchange response already started";
      elsif Item.Authentication_Value = Required_Authentication
        and then not Item.Principal_Present
        and then Status < 400
      then
         raise Program_Error with
           "required-authentication route cannot send an unauthenticated"
           & " response";
      end if;
      Flyology.HTTP.Server.Respond
        (Item.Connection_Handle.all, Status, Content_Type, Payload,
         Extra_Headers => To_String (Item.Extra_Headers),
         Close         => Close,
         Timeout       => Remaining (Item),
         Token         => Item.Token_Handle);
      Item.Status_Value := Status;
      Item.Response_Length :=
        (if Is_Head or else Status in 204 | 205 | 304
         then 0 else Payload'Length);
      Item.Response_Value := Completed;
   exception
      when others =>
         Item.Response_Value := Failed;
         raise;
   end Respond;

   procedure Text
     (Item   : in out Exchange;
      Status : Positive;
      Value  : String)
   is
   begin
      Respond (Item, Status, "text/plain; charset=utf-8", Value);
   end Text;

   procedure JSON
     (Item       : in out Exchange;
      Status     : Positive;
      Serialized : String)
   is
   begin
      Respond (Item, Status, "application/json", Serialized);
   end JSON;

   procedure Redirect
     (Item     : in out Exchange;
      Status   : Positive;
      Location : String)
   is
   begin
      if Status not in 301 | 302 | 303 | 307 | 308 then
         raise Program_Error with "invalid HTTP redirect status";
      end if;
      Add_Header (Item, "Location", Location);
      Respond (Item, Status, "", "");
   end Redirect;

   procedure No_Content (Item : in out Exchange) is
   begin
      Respond (Item, 204, "", "");
   end No_Content;

   function Hex (Value : Natural) return Character is
     (if Value < 10
      then Character'Val (Character'Pos ('0') + Value)
      else Character'Val (Character'Pos ('A') + Value - 10));

   function JSON_Escape (Value : String) return String is
      Result : Unbounded_String;
      Code   : Natural;
   begin
      for Item of Value loop
         Code := Character'Pos (Item);
         case Item is
            when Character'Val (34) =>
               Append
                 (Result,
                  String'(1 => Character'Val (92),
                          2 => Character'Val (34)));
            when Character'Val (92) =>
               Append (Result, Character'Val (92) & Character'Val (92));
            when Character'Val (8) =>
               Append (Result, Character'Val (92) & "b");
            when Character'Val (9) =>
               Append (Result, Character'Val (92) & "t");
            when Character'Val (10) =>
               Append (Result, Character'Val (92) & "n");
            when Character'Val (12) =>
               Append (Result, Character'Val (92) & "f");
            when Character'Val (13) =>
               Append (Result, Character'Val (92) & "r");
            when others =>
               if Code < 32 then
                  Append
                    (Result, Character'Val (92) & "u00"
                     & Hex (Code / 16) & Hex (Code mod 16));
               else
                  Append (Result, Item);
               end if;
         end case;
      end loop;
      return To_String (Result);
   end JSON_Escape;

   procedure Problem
     (Item   : in out Exchange;
      Status : Positive;
      Kind   : String;
      Detail : String)
   is
      Payload : constant String :=
        "{""type"":""urn:flyology:problem:"
        & JSON_Escape (Kind) & """,""status"":"
        & Ada.Strings.Fixed.Trim (Positive'Image (Status), Ada.Strings.Both)
        & ",""detail"":""" & JSON_Escape (Detail) & """}";
   begin
      Respond (Item, Status, "application/problem+json", Payload);
   end Problem;

   procedure Begin_Stream
     (Item         : in out Exchange;
      Status       : Positive;
      Content_Type : String;
      Close        : Boolean := False)
   is
   begin
      Require_Owner (Item);
      if Item.Response_Value /= Not_Started then
         raise Program_Error with "HTTP exchange response already started";
      elsif Item.Authentication_Value = Required_Authentication
        and then not Item.Principal_Present
        and then Status < 400
      then
         raise Program_Error with
           "required-authentication route cannot start an unauthenticated"
           & " stream";
      end if;
      Begin_Response_Stream
        (Item.Connection_Handle.all, Status, Content_Type,
         Extra_Headers => To_String (Item.Extra_Headers),
         Close         => Close,
         Timeout       => Remaining (Item),
         Token         => Item.Token_Handle);
      Item.Status_Value := Status;
      Item.Response_Value := Streaming_Response;
   exception
      when others =>
         Item.Response_Value := Failed;
         raise;
   end Begin_Stream;

   procedure Write_Chunk (Item : in out Exchange; Data : String) is
   begin
      Require_Owner (Item);
      if Item.Response_Value /= Streaming_Response then
         raise Program_Error with "HTTP exchange stream is not active";
      end if;
      Write_Response_Chunk
        (Item.Connection_Handle.all, Data, Remaining (Item),
         Item.Token_Handle);
      if Method (Item.Request_Handle.all) /= "HEAD" then
         Item.Response_Length := Item.Response_Length + Data'Length;
      end if;
   exception
      when others =>
         Item.Response_Value := Failed;
         raise;
   end Write_Chunk;

   procedure Write_Chunk
     (Item : in out Exchange;
      Data : Ada.Streams.Stream_Element_Array) is
   begin
      Require_Owner (Item);
      if Item.Response_Value /= Streaming_Response then
         raise Program_Error with "HTTP exchange stream is not active";
      end if;
      Write_Response_Chunk
        (Item.Connection_Handle.all, Data, Remaining (Item),
         Item.Token_Handle);
      if Method (Item.Request_Handle.all) /= "HEAD" then
         Item.Response_Length := Item.Response_Length + Natural (Data'Length);
      end if;
   exception
      when others =>
         Item.Response_Value := Failed;
         raise;
   end Write_Chunk;

   procedure End_Stream (Item : in out Exchange) is
   begin
      Require_Owner (Item);
      if Item.Response_Value /= Streaming_Response then
         raise Program_Error with "HTTP exchange stream is not active";
      end if;
      End_Response_Stream
        (Item.Connection_Handle.all, Remaining (Item), Item.Token_Handle);
      Item.Response_Value := Completed;
   exception
      when others =>
         Item.Response_Value := Failed;
         raise;
   end End_Stream;

   procedure Begin_SSE (Item : in out Exchange) is
   begin
      Require_Owner (Item);
      if Item.Response_Value /= Not_Started then
         raise Program_Error with "HTTP exchange response already started";
      elsif Item.Authentication_Value = Required_Authentication
        and then not Item.Principal_Present
      then
         raise Program_Error with
           "required-authentication route cannot start unauthenticated SSE";
      elsif Item.Upgrade_Value /= Allow_SSE then
         raise Program_Error with "route does not permit SSE";
      end if;
      Flyology.HTTP.Server.Begin_SSE
        (Item.Connection_Handle.all,
         Extra_Headers => To_String (Item.Extra_Headers),
         Timeout       => Remaining (Item),
         Token         => Item.Token_Handle);
      Item.Status_Value := 200;
      Item.Response_Value := Streaming_SSE;
   exception
      when others =>
         Item.Response_Value := Failed;
         raise;
   end Begin_SSE;

   procedure Send_SSE
     (Item  : in out Exchange;
      Data  : String;
      Event : String := "";
      Id    : String := "";
      Retry : Natural := 0;
      Include_Id : Boolean := False;
      Include_Retry : Boolean := False)
   is
   begin
      Require_Owner (Item);
      if Item.Response_Value /= Streaming_SSE then
         raise Program_Error with "HTTP exchange SSE stream is not active";
      end if;
      Flyology.HTTP.Server.Send_Event
        (Item.Connection_Handle.all, Data, Event, Id, Retry,
         Remaining (Item), Item.Token_Handle, Include_Id, Include_Retry);
      if Method (Item.Request_Handle.all) /= "HEAD" then
         Item.Response_Length := Item.Response_Length + Data'Length;
      end if;
   exception
      when others =>
         Item.Response_Value := Failed;
         raise;
   end Send_SSE;

   procedure Send_SSE_Comment
     (Item : in out Exchange; Comment : String := "") is
   begin
      Require_Owner (Item);
      if Item.Response_Value /= Streaming_SSE then
         raise Program_Error with "HTTP exchange SSE stream is not active";
      end if;
      Flyology.HTTP.Server.Send_SSE_Comment
        (Item.Connection_Handle.all, Comment, Remaining (Item),
         Item.Token_Handle);
   exception
      when others =>
         Item.Response_Value := Failed;
         raise;
   end Send_SSE_Comment;

   procedure End_SSE (Item : in out Exchange) is
   begin
      Require_Owner (Item);
      if Item.Response_Value /= Streaming_SSE then
         raise Program_Error with "HTTP exchange SSE stream is not active";
      end if;
      Flyology.HTTP.Server.End_SSE
        (Item.Connection_Handle.all, Remaining (Item), Item.Token_Handle);
      Item.Response_Value := Completed;
   exception
      when others =>
         Item.Response_Value := Failed;
         raise;
   end End_SSE;

   procedure Accept_WebSocket
     (Item           : in out Exchange;
      Protocol       : String := "";
      Origin_Policy  : WebSocket_Origin_Policy := Reject_Browser_Origins;
      Allowed_Origin : String := "";
      Compression    : WebSocket_Compression_Mode :=
        No_WebSocket_Compression)
   is
   begin
      Require_Owner (Item);
      if Item.Response_Value /= Not_Started then
         raise Program_Error with "HTTP exchange response already started";
      elsif Item.Authentication_Value = Required_Authentication
        and then not Item.Principal_Present
      then
         raise Program_Error with
           "required-authentication route cannot upgrade unauthenticated"
           & " WebSocket";
      elsif Item.Upgrade_Value /= Allow_WebSocket then
         raise Program_Error with "route does not permit WebSocket upgrade";
      end if;
      Flyology.HTTP.Server.Accept_WebSocket
        (Item             => Item.Connection_Handle.all,
         Value            => Item.Request_Handle.all,
         Protocol         => Protocol,
         Origin_Policy    => Origin_Policy,
         Allowed_Origin   => Allowed_Origin,
         Compression      => Compression,
         Timeout          => Remaining (Item),
         Token            => Item.Token_Handle);
      Item.Status_Value := 101;
      Item.Response_Value := Upgraded;
   exception
      when others =>
         Item.Response_Value := Failed;
         raise;
   end Accept_WebSocket;

   procedure Receive_WebSocket
     (Item        : in out Exchange;
      Kind        : out WebSocket_Data_Kind;
      Data        : out Flyology.Bytes.Unbounded_Bytes;
      Closed      : out Boolean;
      Max_Message : Natural := Default_Max_WebSocket_Message;
      Timeout     : Duration := 30.0;
      Message_Timeout : Duration := 30.0)
   is
      Left : constant Duration := Remaining (Item);
      Wait : constant Duration :=
        (if Left < 0.0 then Timeout
         elsif Timeout < 0.0 then Left
         else Duration'Min (Left, Timeout));
   begin
      Require_Owner (Item);
      if Item.Response_Value /= Upgraded then
         raise Program_Error with "HTTP exchange WebSocket is not active";
      end if;
      Flyology.HTTP.Server.Receive_WebSocket
        (Item.Connection_Handle.all, Kind, Data, Closed, Max_Message,
         Wait,
         (if Left < 0.0 then Message_Timeout
          elsif Message_Timeout < 0.0 then Left
          else Duration'Min (Left, Message_Timeout)),
         Item.Token_Handle);
   exception
      when Flyology.IO.Timeout_Error =>
         raise;
      when others =>
         Item.Response_Value := Failed;
         raise;
   end Receive_WebSocket;

   procedure Send_WebSocket
     (Item : in out Exchange;
      Kind : WebSocket_Data_Kind;
      Data : Ada.Streams.Stream_Element_Array)
   is
   begin
      Require_Owner (Item);
      if Item.Response_Value /= Upgraded then
         raise Program_Error with "HTTP exchange WebSocket is not active";
      end if;
      Flyology.HTTP.Server.Send_WebSocket
        (Item.Connection_Handle.all, Kind, Data, Remaining (Item),
         Item.Token_Handle);
      Item.Response_Length := Item.Response_Length + Data'Length;
   exception
      when others =>
         Item.Response_Value := Failed;
         raise;
   end Send_WebSocket;

   procedure Send_WebSocket
     (Item : in out Exchange;
      Kind : WebSocket_Data_Kind;
      Data : Flyology.Bytes.Unbounded_Bytes)
   is
   begin
      Require_Owner (Item);
      if Item.Response_Value /= Upgraded then
         raise Program_Error with "HTTP exchange WebSocket is not active";
      end if;
      Flyology.HTTP.Server.Send_WebSocket
        (Item.Connection_Handle.all, Kind, Data, Remaining (Item),
         Item.Token_Handle);
      Item.Response_Length :=
        Item.Response_Length + Flyology.Bytes.Length (Data);
   exception
      when others =>
         Item.Response_Value := Failed;
         raise;
   end Send_WebSocket;

   procedure Send_WebSocket
     (Item : in out Exchange;
      Data : String)
   is
   begin
      Require_Owner (Item);
      if Item.Response_Value /= Upgraded then
         raise Program_Error with "HTTP exchange WebSocket is not active";
      end if;
      Flyology.HTTP.Server.Send_WebSocket
        (Item.Connection_Handle.all, Data, Remaining (Item),
         Item.Token_Handle);
      Item.Response_Length := Item.Response_Length + Data'Length;
   exception
      when others =>
         Item.Response_Value := Failed;
         raise;
   end Send_WebSocket;

   procedure Close_WebSocket
     (Item   : in out Exchange;
      Code   : Positive := 1_000;
      Reason : String := "")
   is
   begin
      Require_Owner (Item);
      if Item.Response_Value /= Upgraded then
         raise Program_Error with "HTTP exchange WebSocket is not active";
      end if;
      Flyology.HTTP.Server.Close_WebSocket
        (Item.Connection_Handle.all, Code, Reason, Remaining (Item),
         Item.Token_Handle);
      Item.Response_Value := Completed;
   exception
      when others =>
         Item.Response_Value := Failed;
         raise;
   end Close_WebSocket;

   procedure Complete_WebSocket (Item : in out Exchange) is
   begin
      Require_Owner (Item);
      if Item.Response_Value /= Upgraded then
         raise Program_Error with "HTTP exchange WebSocket is not active";
      end if;
      Item.Response_Value := Completed;
   end Complete_WebSocket;

   function Response (Item : Exchange) return Response_State is
     (Item.Response_Value);

   function Response_Status (Item : Exchange) return Natural is
     (Item.Status_Value);

   function Response_Bytes (Item : Exchange) return Natural is
     (Item.Response_Length);

   procedure Mark_Failed (Item : in out Exchange) is
   begin
      Require_Owner (Item);
      Item.Connection_Handle.Request_Close := True;
      Item.Response_Value := Failed;
   end Mark_Failed;

   procedure Apply_Body_Policy
     (Item     : in out Exchange;
      Accepted : out Boolean)
   is
   begin
      Require_Owner (Item);
      Accepted := False;
      case Item.Body_Mode is
         when Reject_Body =>
            if not Flyology.HTTP.Server.Body_Complete
              (Item.Connection_Handle.all)
            then
               Item.Problem
                 (413, "body-not-accepted", "Route does not accept a body");
               return;
            end if;
         when Stream_Body =>
            Flyology.HTTP.Server.Accept_Body
              (Item.Connection_Handle.all, Item.Token_Handle);
         when Buffer_Body =>
            Flyology.HTTP.Server.Buffer_Request_Body
              (Item.Connection_Handle.all,
               Item.Request_Handle.all,
               Item.Token_Handle);
         when Discard_Request_Body =>
            Flyology.HTTP.Server.Discard_Body
              (Item.Connection_Handle.all, Item.Token_Handle);
      end case;
      Accepted := True;
   end Apply_Body_Policy;

   procedure Configure_Route
     (Item            : in out Exchange;
      Name            : String;
      Normalized_Path : String;
      Policy          : Request_Body_Policy;
      Authentication  : Authentication_Mode;
      CORS_Policy     : Natural;
      Concurrency     : Natural;
      Rate_Per_Second : Natural;
      Upgrade         : Upgrade_Mode)
   is
   begin
      Require_Owner (Item);
      if Item.Route_Sealed then
         raise Program_Error with "HTTP route metadata is sealed";
      end if;
      Item.Route_Value := To_Unbounded_String (Name);
      Item.Path_Value := To_Unbounded_String (Normalized_Path);
      Item.Body_Mode := Policy;
      Item.Authentication_Value := Authentication;
      Item.CORS_Policy_Value := CORS_Policy;
      Item.Concurrency_Value := Concurrency;
      Item.Rate_Value := Rate_Per_Second;
      Item.Upgrade_Value := Upgrade;
      Item.Parameter_Count := 0;
      Item.Parameters := (others => (Null_Unbounded_String,
                                     Null_Unbounded_String));
   end Configure_Route;

   procedure Add_Parameter
     (Item  : in out Exchange;
      Name  : String;
      Value : String)
   is
   begin
      Require_Owner (Item);
      if Item.Route_Sealed then
         raise Program_Error with "HTTP route metadata is sealed";
      elsif Has_Parameter (Item, Name) then
         raise Program_Error with "duplicate HTTP route parameter";
      elsif Item.Parameter_Count = Max_Path_Parameters then
         raise Program_Error with "too many HTTP route parameters";
      end if;
      Item.Parameter_Count := Item.Parameter_Count + 1;
      Item.Parameters (Item.Parameter_Count) :=
        (To_Unbounded_String (Name), To_Unbounded_String (Value));
   end Add_Parameter;

   procedure Seal_Route (Item : in out Exchange) is
   begin
      Require_Owner (Item);
      Item.Route_Sealed := True;
   end Seal_Route;

end Flyology.HTTP.Server.Applications;
