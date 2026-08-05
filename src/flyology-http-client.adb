with Ada.Characters.Handling;
with Ada.Real_Time;
with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;
with Flyology.IO;
with Flyology.IO.Connections;
with Flyology.IO.Connections.TLS;
with Flyology.IO.DNS;
with Flyology.IO.Sockets;
with Flyology.Time_Math;
with Flyology.Wake_Sources;

package body Flyology.HTTP.Client is
   use Ada.Strings.Unbounded;
   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;
   use type Flyology.IO.Descriptor;

   package Connections renames Flyology.IO.Connections;
   package Sockets renames Flyology.IO.Sockets;

   CRLF : constant String := Character'Val (13) & Character'Val (10);
   Receive_Buffer_Size : constant Positive := 8 * 1_024;
   Request_Buffer_Size : constant Positive := 8 * 1_024;
   Max_Informational_Responses : constant Positive := 8;
   Max_Request_Target_Bytes : constant Positive := 8 * 1_024;

   type Pooled_Connection is limited record
      Channel : Connections.Connection;
   end record;
   type Pooled_Connection_Access is access Pooled_Connection;

   procedure Free_Connection is new Ada.Unchecked_Deallocation
     (Pooled_Connection, Pooled_Connection_Access);

   type Slot_Phase is (Empty, Connecting, Leased, Idle, Closing);

   type Slot is record
      Phase       : Slot_Phase := Empty;
      Connection  : Pooled_Connection_Access := null;
      Born         : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Last_Used    : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Request_Count : Natural := 0;
      Interrupting : Boolean := False;
      Interrupt_Sent : Boolean := False;
      Owner_Done   : Boolean := False;
   end record;
   type Slot_Array is array (Positive range <>) of Slot;

   type Checkout_Result is
     (Checkout_Idle, Checkout_Create, Checkout_Discard, Checkout_Busy,
      Checkout_Closed);
   type Return_Result is
     (Returned_Idle, Return_Close, Return_Close_Deferred);
   type Failure_Result is (Failure_Free, Failure_Free_Deferred);

   protected type Pool_Controller (Capacity : Positive) is
      procedure Configure (Value : Pool_Configuration);
      procedure Try_Checkout
        (Now        : Ada.Real_Time.Time;
         Result     : out Checkout_Result;
         Slot_Index : out Natural;
         Connection : out Pooled_Connection_Access);
      procedure Install
        (Slot_Index : Positive;
         Connection : Pooled_Connection_Access;
         Now        : Ada.Real_Time.Time);
      procedure Publish_Connecting
        (Slot_Index : Positive; Connection : Pooled_Connection_Access);
      procedure Creation_Failed
        (Slot_Index : Positive; Result : out Failure_Result);
      procedure Return_Lease
        (Slot_Index : Positive;
         Reusable   : Boolean;
         Now        : Ada.Real_Time.Time;
         Result     : out Return_Result;
         Connection : out Pooled_Connection_Access);
      procedure Finish_Close (Slot_Index : Positive);
      procedure Take_Idle
        (Found      : out Boolean;
         Slot_Index : out Natural;
         Connection : out Pooled_Connection_Access);
      procedure Request_Shutdown;
      procedure Take_Active_For_Interrupt
        (Found      : out Boolean;
         Slot_Index : out Natural;
         Connection : out Pooled_Connection_Access);
      procedure Finish_Interrupt
        (Slot_Index : Positive;
         Release_Ownership : out Boolean;
         Connection : out Pooled_Connection_Access);
      entry Await_Drained;
      procedure Wait_Source
        (FD : out Flyology.IO.Descriptor; Can_Checkout : out Boolean);
      procedure Shutdown_Source
        (FD : out Flyology.IO.Descriptor; Requested : out Boolean);
      procedure Register_Waiter;
      procedure Unregister_Waiter;
      procedure Record_Admission_Timeout;
      procedure Record_Stale_Retry;
      function Snapshot return Client_Diagnostics;
      function Is_Stopping return Boolean;
   private
      Policy       : Pool_Configuration := Default_Pool_Configuration;
      Slots        : Slot_Array (1 .. Capacity);
      Is_Configured : Boolean := False;
      Stopping     : Boolean := False;
      Connecting_Count : Natural := 0;
      Leased_Count : Natural := 0;
      Idle_Count   : Natural := 0;
      Closing_Count : Natural := 0;
      Waiter_Count : Natural := 0;
      Created_Count : Natural := 0;
      Reused_Count : Natural := 0;
      Closed_Count : Natural := 0;
      Timeout_Count : Natural := 0;
      Stale_Retry_Count : Natural := 0;
      Checkout_Wake : Flyology.Wake_Sources.Source;
      Checkout_Signalled : Boolean := False;
      Shutdown_Wake : Flyology.Wake_Sources.Source;
   end Pool_Controller;

   protected type State_Lifetime is
      procedure Retain_Response;
      procedure Release_Response (Final_Reference : out Boolean);
      procedure Release_Client (Final_Reference : out Boolean);
   private
      Client_Live : Boolean := True;
      Responses   : Natural := 0;
   end State_Lifetime;

   protected body Pool_Controller is separate;

   protected body State_Lifetime is separate;

   type Client_State (Capacity : Positive) is limited record
      Manager       : aliased Connections.Server (Capacity => Capacity);
      Pool          : Pool_Controller (Capacity);
      Lifetime      : State_Lifetime;
      Backend       : Flyology.IO.TLS.Provider_Access := null;
      Origin_Value  : Origin;
      Is_Configured : Boolean := False;
   end record;

   type Body_Mode is (No_Body, Fixed_Body, Chunked_Body, Until_Close_Body);

   type Response_Data is record
      Owner          : Client_State_Access := null;
      Connection     : Pooled_Connection_Access := null;
      Slot_Index     : Natural := 0;
      Status_Value   : Status_Code := 200;
      Reason_Value   : Unbounded_String;
      Protocol_Value : Protocol := HTTP_1_1_Protocol;
      Version_Value  : HTTP_Version := HTTP_1_1;
      Fields         : Flyology.HTTP.Headers.List;
      Trailers       : Flyology.HTTP.Headers.List;
      Pending        : Unbounded_String;
      Mode           : Body_Mode := No_Body;
      Remaining_Body : Natural := 0;
      Chunk_Remaining : Natural := 0;
      Need_Chunk_CRLF : Boolean := False;
      Reading_Trailers : Boolean := False;
      Complete       : Boolean := False;
      Reusable       : Boolean := False;
      Saw_Response_Bytes : Boolean := False;
      Source_Failed      : Boolean := False;
      Informational_Count : Natural := 0;
      Retains_Owner  : Boolean := False;
      Started        : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Timeout        : Duration := 0.0;
   end record;

   procedure Free_State is new Ada.Unchecked_Deallocation
     (Client_State, Client_State_Access);
   procedure Free_Response_Data is new Ada.Unchecked_Deallocation
     (Response_Data, Response_Data_Access);

   procedure Release_State (Item : in out Client_State_Access) is
   begin
      if Item /= null then
         Flyology.IO.TLS.Release (Item.Backend);
         Free_State (Item);
      end if;
   end Release_State;

   function Remaining
     (Started : Ada.Real_Time.Time; Timeout : Duration) return Duration is
   begin
      if Timeout < 0.0 then
         return Flyology.IO.Infinite;
      end if;
      return Flyology.Time_Math.Remaining
        (Timeout,
         Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started));
   end Remaining;

   function Byte_Array (Value : String)
      return Ada.Streams.Stream_Element_Array
   is
      Result : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Value'Length));
   begin
      if Value'Length > 0 then
         for Offset in 0 .. Value'Length - 1 loop
            Result
              (Result'First + Ada.Streams.Stream_Element_Offset (Offset)) :=
              Ada.Streams.Stream_Element
                (Character'Pos (Value (Value'First + Offset)));
         end loop;
      end if;
      return Result;
   end Byte_Array;

   function Byte_String (Value : Ada.Streams.Stream_Element_Array)
      return String
   is
      Result : String (1 .. Natural (Value'Length));
      Cursor : Natural := 0;
   begin
      for Item of Value loop
         Cursor := Cursor + 1;
         Result (Cursor) := Character'Val (Item);
      end loop;
      return Result;
   end Byte_String;

   function Decimal (Value : Natural) return String is
      Text : constant String := Natural'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Decimal;

   function Decimal (Value : Body_Size) return String is
      Text : constant String := Body_Size'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Decimal;

   function Hexadecimal (Value : Natural) return String is
      Hex_Digits : constant String := "0123456789abcdef";
      Buffer : String (1 .. (Natural'Size + 3) / 4);
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
   end Hexadecimal;

   function Is_Default_Port (Value : Origin) return Boolean is
     ((Scheme (Value) = Plain_HTTP and then Port (Value) = 80)
        or else
      (Scheme (Value) = Secure_HTTPS and then Port (Value) = 443));

   function Host_Field (Value : Origin) return String is
      Name : constant String := Host (Value);
      Bracketed : constant String :=
        (if Ada.Strings.Fixed.Index (Name, ":") = 0
         then Name else "[" & Name & "]");
   begin
      return Bracketed &
        (if Is_Default_Port (Value) then ""
         else ":" & Decimal (Natural (Port (Value))));
   end Host_Field;

   procedure Close_And_Finish
     (Owner      : not null Client_State_Access;
      Slot_Index : Positive;
      Connection : in out Pooled_Connection_Access) is
   begin
      if Connection /= null then
         if Scheme (Owner.Origin_Value) = Secure_HTTPS then
            begin
               Flyology.IO.Connections.TLS.Shutdown
                 (Connection.Channel, Timeout => 0.0);
            exception
               when others => null;
            end;
         end if;
         begin
            Connections.Close (Connection.Channel);
         exception
            when others => null;
         end;
         Free_Connection (Connection);
      end if;
      Owner.Pool.Finish_Close (Slot_Index);
   end Close_And_Finish;

   procedure Interrupt_Active (Owner : not null Client_State_Access) is
      Found       : Boolean;
      Slot_Index  : Natural;
      Connection  : Pooled_Connection_Access;
      Release_Ownership : Boolean;
      Released    : Pooled_Connection_Access;
   begin
      loop
         Owner.Pool.Take_Active_For_Interrupt
           (Found, Slot_Index, Connection);
         exit when not Found;
         begin
            Connections.Close (Connection.Channel);
         exception
            when others => null;
         end;
         Owner.Pool.Finish_Interrupt
           (Positive (Slot_Index), Release_Ownership, Released);
         if Release_Ownership and then Released /= null then
            Free_Connection (Released);
         end if;
      end loop;
   end Interrupt_Active;

   procedure Release_Lease
     (Data : in out Response_Data; Reusable : Boolean) is
      Result : Return_Result;
      Value  : Pooled_Connection_Access;
      Index  : constant Natural := Data.Slot_Index;
   begin
      if Data.Connection = null then
         Data.Complete := True;
         return;
      end if;
      Data.Owner.Pool.Return_Lease
        (Positive (Data.Slot_Index), Reusable, Ada.Real_Time.Clock,
         Result, Value);
      Data.Connection := null;
      Data.Slot_Index := 0;
      Data.Complete := True;
      if Result = Return_Close then
         Close_And_Finish (Data.Owner, Positive (Index), Value);
      end if;
   end Release_Lease;

   procedure Set_Method (Item : in out Request; Value : Method) is
   begin
      Item.Method_Value := Value;
   end Set_Method;

   procedure Set_Target (Item : in out Request; Value : String) is
   begin
      if Value /= "*" and then
        (Value'Length = 0
        or else Value'Length > Max_Request_Target_Bytes
        or else Value (Value'First) /= '/'
        or else Ada.Strings.Fixed.Index (Value, "#") /= 0
        or else
          (for some Character_Value of Value =>
             Character_Value = ' '
               or else Character'Pos (Character_Value) < 32
               or else Character'Pos (Character_Value) > 126))
      then
         raise Constraint_Error with "invalid HTTP client request target";
      end if;
      Item.Target_Value := To_Unbounded_String (Value);
   end Set_Target;

   procedure Add_Header
     (Item : in out Request; Name : String; Value : String)
   is
      Lower : constant String := Ada.Characters.Handling.To_Lower (Name);
   begin
      if Lower in
        "connection" | "content-length" | "expect" | "host" |
        "keep-alive" | "proxy-connection" | "te" | "trailer" |
        "transfer-encoding" | "upgrade"
      then
         raise Constraint_Error with
           "HTTP client controls framing and connection fields";
      end if;
      Flyology.HTTP.Headers.Add (Item.Fields, Name, Value);
   end Add_Header;

   procedure Set_Expect_Continue
     (Item         : in out Request;
      Enabled      : Boolean := True;
      Wait_Timeout : Duration := 1.0) is
   begin
      Item.Expect_Continue := Enabled;
      Item.Continue_Wait := Wait_Timeout;
   end Set_Expect_Continue;

   procedure Add_Trailer
     (Item : in out Request; Name : String; Value : String)
   is
      Lower : constant String := Ada.Characters.Handling.To_Lower (Name);
   begin
      if Lower in
        "authorization" | "connection" | "content-encoding" |
        "content-length" | "content-range" | "content-type" | "cookie" |
        "expect" | "host" | "if-match" | "if-modified-since" |
        "if-none-match" | "if-range" | "if-unmodified-since" |
        "keep-alive" | "max-forwards" | "proxy-authorization" |
        "proxy-connection" | "range" | "te" | "trailer" |
        "transfer-encoding" | "upgrade"
      then
         raise Constraint_Error with
           "field is prohibited in HTTP request trailers";
      end if;
      Flyology.HTTP.Headers.Add (Item.Trailer_Fields, Name, Value);
   end Add_Trailer;

   procedure Set_Body (Item : in out Request; Value : String) is
   begin
      Item.Body_Value := Flyology.Bytes.From_Byte_String (Value);
   end Set_Body;

   procedure Set_Body
     (Item : in out Request; Value : Ada.Streams.Stream_Element_Array) is
   begin
      Item.Body_Value := Flyology.Bytes.To_Unbounded_Bytes (Value);
   end Set_Body;

   function Known_Length (Bytes : Body_Size) return Body_Length is
     (Is_Known => True, Bytes => Bytes);

   procedure Configure
     (Item         : in out Client;
      Origin_Value : Origin;
      Pool         : Pool_Configuration := Default_Pool_Configuration) is
   begin
      if Item.Control.State /= null then
         raise Program_Error with "HTTP client is already configured";
      elsif Scheme (Origin_Value) = Secure_HTTPS then
         raise Program_Error with "HTTPS client requires a TLS backend";
      end if;
      Item.Control.State := new Client_State (Item.Capacity);
      Item.Control.State.Origin_Value := Origin_Value;
      Item.Control.State.Pool.Configure (Pool);
      Item.Control.State.Is_Configured := True;
   exception
      when others =>
         if Item.Control.State /= null
           and then not Item.Control.State.Is_Configured
         then
            Release_State (Item.Control.State);
         end if;
         raise;
   end Configure;

   procedure Configure
     (Item         : in out Client;
      Origin_Value : Origin;
      Backend      : not null access Flyology.IO.TLS.Provider'Class;
      Pool         : Pool_Configuration := Default_Pool_Configuration)
   is
      Retained : Flyology.IO.TLS.Provider_Access := null;
   begin
      if Item.Control.State /= null then
         raise Program_Error with "HTTP client is already configured";
      end if;
      Retained := Flyology.IO.TLS.Retain (Backend.all);
      Item.Control.State := new Client_State (Item.Capacity);
      Item.Control.State.Backend := Retained;
      Retained := null;
      Item.Control.State.Origin_Value := Origin_Value;
      Item.Control.State.Pool.Configure (Pool);
      Item.Control.State.Is_Configured := True;
   exception
      when others =>
         Flyology.IO.TLS.Release (Retained);
         if Item.Control.State /= null
           and then not Item.Control.State.Is_Configured
         then
            Release_State (Item.Control.State);
         end if;
         raise;
   end Configure;

   package Exchange_Internals is
      procedure Translate_Interruption
        (State : not null Client_State_Access;
         Token : access Flyology.Cancellation.Token)
        with No_Return;

      procedure Checkout
        (Item       : in out Client;
         Connection : out Pooled_Connection_Access;
         Slot_Index : out Positive;
         Was_Reused : out Boolean;
         Started    : Ada.Real_Time.Time;
         Timeout    : Duration;
         Token      : access Flyology.Cancellation.Token);
   end Exchange_Internals;

   package body Exchange_Internals is separate;
   use Exchange_Internals;

   procedure Validate_Request (Value : Request) is
      Body_Length : constant Natural :=
        Flyology.Bytes.Length (Value.Body_Value);
   begin
      if Image (Value.Method_Value) = "CONNECT" then
         raise Constraint_Error with "CONNECT requests are unsupported";
      elsif Image (Value.Method_Value) = "TRACE" and then Body_Length > 0 then
         raise Constraint_Error with "TRACE requests cannot contain a body";
      elsif To_String (Value.Target_Value) = "*"
        and then Image (Value.Method_Value) /= "OPTIONS"
      then
         raise Constraint_Error with "asterisk target requires OPTIONS";
      end if;
   end Validate_Request;

   package HTTP_1_Internals is
      function Request_Head
        (State         : Client_State;
         Value         : Request;
         Streaming     : Boolean;
         Stream_Length : Body_Length) return String;

      procedure Send_Streaming_Body
        (Data   : in out Response_Data;
         Source : in out Request_Body_Source'Class;
         Length : Body_Length;
         Trailers : Flyology.HTTP.Headers.List;
         Token  : access Flyology.Cancellation.Token);

      procedure Await_Continue
        (Data         : in out Response_Data;
         Wait_Timeout : Duration;
         Token        : access Flyology.Cancellation.Token;
         Final_Ready  : out Boolean);

      procedure Reset_Attempt (Data : in out Response_Data);

      procedure Read_Final_Head
        (Data  : in out Response_Data;
         Token : access Flyology.Cancellation.Token);

      procedure Select_Body_Mode
        (Data : in out Response_Data; Request_Method : Method);

      procedure Validate_Response
        (Value : Ada.Streams.Stream_Element_Array);

      procedure Read_Response_Body
        (Item     : in out Response;
         Data     : out Ada.Streams.Stream_Element_Array;
         Last     : out Ada.Streams.Stream_Element_Offset;
         Finished : out Boolean;
         Token    : access Flyology.Cancellation.Token);
   end HTTP_1_Internals;

   package body HTTP_1_Internals is separate;
   use HTTP_1_Internals;

   procedure Validate_Response_Bytes_For_Testing
     (Value : Ada.Streams.Stream_Element_Array) is
   begin
      HTTP_1_Internals.Validate_Response (Value);
   end Validate_Response_Bytes_For_Testing;

   function Execute_Internal
     (Item    : aliased in out Client;
      Value   : Request;
      Source  : access Request_Body_Source'Class;
      Length  : Body_Length;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null) return Response
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Connection : Pooled_Connection_Access;
      Slot       : Positive;
      Was_Reused : Boolean;
      Retained_Length : constant Natural :=
        Flyology.Bytes.Length (Value.Body_Value);
      Has_Stream_Body : constant Boolean :=
        Source /= null
          and then (not Length.Is_Known or else Length.Bytes > 0);
      Has_Request_Body : constant Boolean :=
        Retained_Length > 0 or else Has_Stream_Body;
   begin
      if Item.Control.State = null
        or else not Item.Control.State.Is_Configured
      then
         raise Program_Error with "HTTP client is not configured";
      elsif Source /= null
        and then Retained_Length > 0
      then
         raise Constraint_Error with
           "streaming request cannot also contain a retained body";
      elsif Flyology.HTTP.Headers.Count (Value.Trailer_Fields) > 0
        and then (Source = null or else Length.Is_Known)
      then
         raise Constraint_Error with
           "request trailers require an unknown-length streaming body";
      elsif Value.Expect_Continue and then not Has_Request_Body then
         raise Constraint_Error with
           "Expect: 100-continue requires a nonempty request body";
      end if;
      Validate_Request (Value);
      return Result : Response do
         Result.Data := new Response_Data;
         Result.Data.Owner := Item.Control.State;
         Item.Control.State.Lifetime.Retain_Response;
         Result.Data.Retains_Owner := True;
         Result.Data.Started := Started;
         Result.Data.Timeout := Timeout;
         declare
            Retried : Boolean := False;

            function Can_Retry return Boolean is
              ((Source = null
                  or else Source.all in
                    Rewindable_Request_Body_Source'Class)
                 and then Was_Reused
                 and then not Retried
                 and then Is_Idempotent (Value.Method_Value)
                 and then not Result.Data.Saw_Response_Bytes
                 and then not Result.Data.Source_Failed
                 and then
                   (Timeout < 0.0 or else Remaining (Started, Timeout) > 0.0));

            procedure Retry_Stale is
            begin
               Release_Lease (Result.Data.all, False);
               Reset_Attempt (Result.Data.all);
               if Source /= null then
                  if Token /= null and then Token.Requested then
                     raise Flyology.Cancellation.Operation_Cancelled;
                  elsif Timeout >= 0.0
                    and then Remaining (Started, Timeout) <= 0.0
                  then
                     raise Flyology.IO.Timeout_Error;
                  end if;
                  Rewind
                    (Rewindable_Request_Body_Source'Class (Source.all));
               end if;
               Item.Control.State.Pool.Record_Stale_Retry;
               Retried := True;
            end Retry_Stale;
         begin
            loop
               Checkout
                 (Item, Connection, Slot, Was_Reused, Started, Timeout, Token);
               Result.Data.Connection := Connection;
               Result.Data.Slot_Index := Slot;
               begin
                  declare
                     Head : constant String := Request_Head
                       (Item.Control.State.all, Value,
                        Streaming => Source /= null,
                        Stream_Length => Length);
                  begin
                     Connections.Send_All
                       (Result.Data.Connection.Channel, Byte_Array (Head),
                        Remaining (Started, Timeout), Token => Token);
                  end;
                  declare
                     Final_Ready : Boolean := False;
                  begin
                     if Value.Expect_Continue and then Has_Request_Body then
                        Await_Continue
                          (Result.Data.all, Value.Continue_Wait, Token,
                           Final_Ready);
                     end if;
                     if not Final_Ready then
                        if Retained_Length > 0 then
                           Connections.Send_All
                             (Result.Data.Connection.Channel,
                              Flyology.Bytes.To_Array (Value.Body_Value),
                              Remaining (Started, Timeout), Token => Token);
                        elsif Source /= null then
                           Send_Streaming_Body
                             (Result.Data.all, Source.all, Length,
                              Value.Trailer_Fields, Token);
                        end if;
                        Read_Final_Head (Result.Data.all, Token);
                     end if;
                  end;
                  Select_Body_Mode (Result.Data.all, Value.Method_Value);
                  exit;
               exception
                  when Protocol_Error =>
                     if Can_Retry then
                        Retry_Stale;
                     else
                        raise;
                     end if;
                  when Flyology.IO.Device_Error |
                       Flyology.IO.Sockets.Socket_Error |
                       Flyology.IO.TLS.TLS_Error =>
                     if Can_Retry then
                        Retry_Stale;
                     else
                        raise;
                     end if;
               end;
            end loop;
         end;
      end return;
   exception
      when Flyology.Cancellation.Operation_Cancelled =>
         Translate_Interruption (Item.Control.State, Token);
      when others =>
         if Item.Control.State /= null
           and then Item.Control.State.Pool.Is_Stopping
         then
            raise Client_Closed;
         end if;
         raise;
   end Execute_Internal;

   function Execute
     (Item    : aliased in out Client;
      Value   : Request;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null) return Response is
     (Execute_Internal
        (Item, Value, Source => null, Length => Unknown_Length,
         Timeout => Timeout, Token => Token));

   function Execute
     (Item    : aliased in out Client;
      Value   : Request;
      Source  : in out Request_Body_Source'Class;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null) return Response is
     (Execute_Internal
        (Item, Value, Source => Source'Access,
         Length => Declared_Length (Source),
         Timeout => Timeout, Token => Token));

   procedure Require_Response (Item : Response) is
   begin
      if Item.Data = null then
         raise Program_Error with "HTTP response is not initialized";
      end if;
   end Require_Response;

   procedure Require_Trailers (Item : Response) is
   begin
      Require_Response (Item);
      if not Item.Data.Complete then
         raise Program_Error with
           "HTTP response trailers are unavailable before body completion";
      end if;
   end Require_Trailers;

   function Status (Item : Response) return Status_Code is
   begin
      Require_Response (Item);
      return Item.Data.Status_Value;
   end Status;

   function Reason_Phrase (Item : Response) return String is
   begin
      Require_Response (Item);
      return To_String (Item.Data.Reason_Value);
   end Reason_Phrase;

   function Negotiated_Protocol (Item : Response) return Protocol is
   begin
      Require_Response (Item);
      return Item.Data.Protocol_Value;
   end Negotiated_Protocol;

   function Header_Count (Item : Response; Name : String) return Natural is
   begin
      Require_Response (Item);
      return Flyology.HTTP.Headers.Count (Item.Data.Fields, Name);
   end Header_Count;

   function Header_Count (Item : Response) return Natural is
   begin
      Require_Response (Item);
      return Flyology.HTTP.Headers.Count (Item.Data.Fields);
   end Header_Count;

   function Header_Name (Item : Response; Index : Positive) return String is
   begin
      Require_Response (Item);
      return Flyology.HTTP.Headers.Name (Item.Data.Fields, Index);
   end Header_Name;

   function Header_Value (Item : Response; Index : Positive) return String is
   begin
      Require_Response (Item);
      return Flyology.HTTP.Headers.Value (Item.Data.Fields, Index);
   end Header_Value;

   function Header
     (Item : Response; Name : String; Occurrence : Positive := 1) return String
   is
   begin
      Require_Response (Item);
      return Flyology.HTTP.Headers.Value (Item.Data.Fields, Name, Occurrence);
   end Header;

   function Trailer_Count (Item : Response; Name : String) return Natural is
   begin
      Require_Trailers (Item);
      return Flyology.HTTP.Headers.Count (Item.Data.Trailers, Name);
   end Trailer_Count;

   function Trailer_Count (Item : Response) return Natural is
   begin
      Require_Trailers (Item);
      return Flyology.HTTP.Headers.Count (Item.Data.Trailers);
   end Trailer_Count;

   function Trailer_Name (Item : Response; Index : Positive) return String is
   begin
      Require_Trailers (Item);
      return Flyology.HTTP.Headers.Name (Item.Data.Trailers, Index);
   end Trailer_Name;

   function Trailer_Value (Item : Response; Index : Positive) return String is
   begin
      Require_Trailers (Item);
      return Flyology.HTTP.Headers.Value (Item.Data.Trailers, Index);
   end Trailer_Value;

   function Trailer
     (Item : Response; Name : String; Occurrence : Positive := 1) return String
   is
   begin
      Require_Trailers (Item);
      return Flyology.HTTP.Headers.Value
        (Item.Data.Trailers, Name, Occurrence);
   end Trailer;

   procedure Read_Body
     (Item     : in out Response;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Token    : access Flyology.Cancellation.Token := null) is
   begin
      Require_Response (Item);
      HTTP_1_Internals.Read_Response_Body
        (Item, Data, Last, Finished, Token);
   end Read_Body;

   function Body_Complete (Item : Response) return Boolean is
   begin
      Require_Response (Item);
      return Item.Data.Complete;
   end Body_Complete;

   function Read_All
     (Item : in out Response;
      Maximum : Natural := 1_024 * 1_024;
      Token : access Flyology.Cancellation.Token := null)
      return Flyology.Bytes.Unbounded_Bytes
   is
      Result   : Flyology.Bytes.Unbounded_Bytes;
      Buffer   : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Receive_Buffer_Size));
      Last     : Ada.Streams.Stream_Element_Offset;
      Finished : Boolean;
   begin
      loop
         Read_Body (Item, Buffer, Last, Finished, Token);
         if Last >= Buffer'First then
            declare
               Count : constant Natural :=
                 Natural (Last - Buffer'First + 1);
            begin
               if Flyology.Bytes.Length (Result) > Maximum
                 or else Count > Maximum - Flyology.Bytes.Length (Result)
               then
                  if Item.Data /= null
                    and then Item.Data.Connection /= null
                  then
                     Release_Lease (Item.Data.all, False);
                  end if;
                  raise Response_Too_Large;
               end if;
               Flyology.Bytes.Append (Result, Buffer (Buffer'First .. Last));
            end;
         end if;
         exit when Finished;
      end loop;
      return Result;
   end Read_All;

   function Diagnostics (Item : Client) return Client_Diagnostics is
   begin
      if Item.Control.State = null then
         return
           (Transport_Capacity => Item.Capacity,
            Pending_Transports | Active_Exchanges | Reusable_Transports |
              Closing_Transports | Admission_Waiters | Transports_Created |
              Transport_Reuses | Transports_Closed | Stale_Retries |
              Admission_Timeouts => 0);
      end if;
      return Item.Control.State.Pool.Snapshot;
   end Diagnostics;

   procedure Prune_Idle (Item : in out Client) is
      Found      : Boolean;
      Slot_Index : Natural;
      Connection : Pooled_Connection_Access;
   begin
      if Item.Control.State = null then
         return;
      end if;
      loop
         Item.Control.State.Pool.Take_Idle
           (Found, Slot_Index, Connection);
         exit when not Found;
         Close_And_Finish
           (Item.Control.State, Positive (Slot_Index), Connection);
      end loop;
   end Prune_Idle;

   procedure Shutdown (Item : in out Client; Timeout : Duration := 5.0) is
   begin
      if Item.Control.State = null then
         return;
      end if;
      Item.Control.State.Pool.Request_Shutdown;
      Item.Control.State.Manager.Request_Shutdown;
      Interrupt_Active (Item.Control.State);
      Prune_Idle (Item);
      if Timeout < 0.0 then
         Item.Control.State.Pool.Await_Drained;
      else
         select
            Item.Control.State.Pool.Await_Drained;
         or
            delay Timeout;
            raise Flyology.IO.Timeout_Error;
         end select;
      end if;
   end Shutdown;

   overriding procedure Finalize (Item : in out Client_Control) is
      Found      : Boolean;
      Slot_Index : Natural;
      Connection : Pooled_Connection_Access;
      Final_Reference : Boolean := False;
   begin
      if Item.State = null then
         return;
      end if;
      begin
         Item.State.Pool.Request_Shutdown;
         Item.State.Manager.Request_Shutdown;
         Interrupt_Active (Item.State);
         loop
            Item.State.Pool.Take_Idle (Found, Slot_Index, Connection);
            exit when not Found;
            Close_And_Finish
              (Item.State, Positive (Slot_Index), Connection);
         end loop;
      exception
         when others => null;
      end;
      Item.State.Lifetime.Release_Client (Final_Reference);
      if Final_Reference then
         Release_State (Item.State);
      end if;
   end Finalize;

   overriding procedure Finalize (Item : in out Response) is
      Owner           : Client_State_Access;
      Final_Reference : Boolean := False;
   begin
      if Item.Data = null then
         return;
      end if;
      Owner := Item.Data.Owner;
      if Item.Data.Connection /= null then
         Release_Lease (Item.Data.all, False);
      end if;
      if Item.Data.Retains_Owner then
         Item.Data.Retains_Owner := False;
         Owner.Lifetime.Release_Response (Final_Reference);
      end if;
      Free_Response_Data (Item.Data);
      if Final_Reference then
         Release_State (Owner);
      end if;
   exception
      when others =>
         if Item.Data /= null and then Item.Data.Retains_Owner
           and then Owner /= null
         then
            Item.Data.Retains_Owner := False;
            begin
               Owner.Lifetime.Release_Response (Final_Reference);
            exception
               when others => null;
            end;
         end if;
         Free_Response_Data (Item.Data);
         if Final_Reference and then Owner /= null then
            Release_State (Owner);
         end if;
   end Finalize;

end Flyology.HTTP.Client;
