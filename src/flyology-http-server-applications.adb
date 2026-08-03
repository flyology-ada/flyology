with Ada.Strings.Fixed;

package body Flyology.HTTP.Server.Applications is

   CRLF : constant String := Character'Val (13) & Character'Val (10);

   function Create
     (Value    : aliased in out Request;
      Item     : aliased in out Connection;
      Context  : System.Address;
      Peer     : GNAT.Sockets.Sock_Addr_Type;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time) return Exchange
   is
   begin
      return Result : Exchange do
         Result.Request_Handle := Value'Unchecked_Access;
         Result.Connection_Handle := Item'Unchecked_Access;
         Result.Context_Handle := Context;
         Result.Peer_Value := Peer;
         Result.Token_Handle :=
           (if Token = null then null else Token.all'Unchecked_Access);
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

   function Connection_Access
     (Item : in out Exchange) return not null access Connection
   is (Item.Connection_Handle);

   function Context_Address (Item : Exchange) return System.Address is
     (Item.Context_Handle);

   function Peer (Item : Exchange) return GNAT.Sockets.Sock_Addr_Type is
     (Item.Peer_Value);

   function Cancellation
     (Item : Exchange) return access Flyology.Cancellation.Token
   is (Item.Token_Handle);

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

   function Body_Policy (Item : Exchange) return Request_Body_Policy is
     (Item.Body_Mode);

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
      if Item.Body_Mode /= Stream_Body then
         raise Program_Error with "route body policy is not streamed";
      end if;
      Flyology.HTTP.Server.Read_Body
        (Item.Connection_Handle.all, Data, Last, Finished,
         Item.Token_Handle);
   end Read_Body;

   function Content (Item : Exchange) return String is
     (Flyology.HTTP.Server.Content (Item.Request_Handle.all));

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
      if Item.Response_Value /= Not_Started then
         raise Program_Error with "HTTP exchange response already started";
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
      if Item.Response_Value /= Not_Started then
         raise Program_Error with "HTTP exchange response already started";
      end if;
      Begin_Response_Stream
        (Item.Connection_Handle.all, Status, Content_Type,
         Extra_Headers => To_String (Item.Extra_Headers),
         Close         => Close,
         Timeout       => Remaining (Item),
         Token         => Item.Token_Handle);
      Item.Status_Value := Status;
      Item.Response_Value := Streaming;
   exception
      when others =>
         Item.Response_Value := Failed;
         raise;
   end Begin_Stream;

   procedure Write_Chunk (Item : in out Exchange; Data : String) is
   begin
      if Item.Response_Value /= Streaming then
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

   procedure End_Stream (Item : in out Exchange) is
   begin
      if Item.Response_Value /= Streaming then
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

   function Response (Item : Exchange) return Response_State is
     (Item.Response_Value);

   function Response_Status (Item : Exchange) return Natural is
     (Item.Status_Value);

   function Response_Bytes (Item : Exchange) return Natural is
     (Item.Response_Length);

   procedure Mark_Failed (Item : in out Exchange) is
   begin
      Item.Connection_Handle.Request_Close := True;
      Item.Response_Value := Failed;
   end Mark_Failed;

   procedure Apply_Body_Policy
     (Item     : in out Exchange;
      Accepted : out Boolean)
   is
   begin
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
      CORS_Policy     : Natural)
   is
   begin
      Item.Route_Value := To_Unbounded_String (Name);
      Item.Path_Value := To_Unbounded_String (Normalized_Path);
      Item.Body_Mode := Policy;
      Item.Authentication_Value := Authentication;
      Item.CORS_Policy_Value := CORS_Policy;
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
      if Has_Parameter (Item, Name) then
         raise Program_Error with "duplicate HTTP route parameter";
      elsif Item.Parameter_Count = Max_Path_Parameters then
         raise Program_Error with "too many HTTP route parameters";
      end if;
      Item.Parameter_Count := Item.Parameter_Count + 1;
      Item.Parameters (Item.Parameter_Count) :=
        (To_Unbounded_String (Name), To_Unbounded_String (Value));
   end Add_Parameter;

end Flyology.HTTP.Server.Applications;
