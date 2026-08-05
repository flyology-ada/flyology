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
   end record;
   type Slot_Array is array (Positive range <>) of Slot;

   type Checkout_Result is
     (Checkout_Idle, Checkout_Create, Checkout_Discard, Checkout_Busy,
      Checkout_Closed);
   type Return_Result is (Returned_Idle, Return_Close);

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
      procedure Creation_Failed (Slot_Index : Positive);
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
      entry Await_Drained;
      procedure Wait_Source
        (FD : out Flyology.IO.Descriptor; Can_Checkout : out Boolean);
      procedure Shutdown_Source
        (FD : out Flyology.IO.Descriptor; Requested : out Boolean);
      procedure Register_Waiter;
      procedure Unregister_Waiter;
      procedure Record_Admission_Timeout;
      function Snapshot return Pool_Snapshot;
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
      Checkout_Wake : Flyology.Wake_Sources.Source;
      Checkout_Signalled : Boolean := False;
      Shutdown_Wake : Flyology.Wake_Sources.Source;
   end Pool_Controller;

   protected body Pool_Controller is
      procedure Configure (Value : Pool_Configuration) is
      begin
         if Is_Configured then
            raise Program_Error with "HTTP client pool is already configured";
         end if;
         Policy := Value;
         Policy.Max_Idle := Natural'Min (Value.Max_Idle, Capacity);
         Is_Configured := True;
      end Configure;

      procedure Try_Checkout
        (Now        : Ada.Real_Time.Time;
         Result     : out Checkout_Result;
         Slot_Index : out Natural;
         Connection : out Pooled_Connection_Access)
      is
         Available_After : Boolean := False;
      begin
         Slot_Index := 0;
         Connection := null;
         if Stopping then
            Result := Checkout_Closed;
            return;
         end if;

         for Index in Slots'Range loop
            if Slots (Index).Phase = Idle then
               declare
                  Idle_Age : constant Duration := Ada.Real_Time.To_Duration
                    (Now - Slots (Index).Last_Used);
                  Total_Age : constant Duration := Ada.Real_Time.To_Duration
                    (Now - Slots (Index).Born);
                  Expired : constant Boolean :=
                    (Policy.Idle_Timeout >= 0.0
                       and then Idle_Age >= Policy.Idle_Timeout)
                    or else
                    (Policy.Max_Connection_Age >= 0.0
                       and then Total_Age >= Policy.Max_Connection_Age)
                    or else
                    (Policy.Max_Requests_Per_Connection > 0
                       and then Slots (Index).Request_Count >=
                         Policy.Max_Requests_Per_Connection);
               begin
                  Slot_Index := Index;
                  Connection := Slots (Index).Connection;
                  Idle_Count := Idle_Count - 1;
                  if Expired then
                     Slots (Index).Phase := Closing;
                     Closing_Count := Closing_Count + 1;
                     Result := Checkout_Discard;
                  else
                     Slots (Index).Phase := Leased;
                     Slots (Index).Request_Count :=
                       Slots (Index).Request_Count + 1;
                     Leased_Count := Leased_Count + 1;
                     Reused_Count := Reused_Count + 1;
                     Result := Checkout_Idle;
                  end if;
                  exit;
               end;
            end if;
         end loop;

         if Slot_Index = 0 then
            for Index in Slots'Range loop
               if Slots (Index).Phase = Empty then
                  Slots (Index).Phase := Connecting;
                  Connecting_Count := Connecting_Count + 1;
                  Slot_Index := Index;
                  Result := Checkout_Create;
                  exit;
               end if;
            end loop;
         end if;

         if Slot_Index = 0 then
            Result := Checkout_Busy;
         end if;

         for Item of Slots loop
            if Item.Phase in Empty | Idle then
               Available_After := True;
               exit;
            end if;
         end loop;
         if Checkout_Signalled and then not Available_After then
            Flyology.Wake_Sources.Consume (Checkout_Wake);
            Checkout_Signalled := False;
         end if;
      end Try_Checkout;

      procedure Install
        (Slot_Index : Positive;
         Connection : Pooled_Connection_Access;
         Now        : Ada.Real_Time.Time) is
      begin
         if Slot_Index > Capacity
           or else Slots (Slot_Index).Phase /= Connecting
           or else Connection = null
         then
            raise Program_Error with "invalid HTTP pool connection install";
         end if;
         Slots (Slot_Index) :=
           (Phase         => Leased,
            Connection    => Connection,
            Born          => Now,
            Last_Used     => Now,
            Request_Count => 1);
         Connecting_Count := Connecting_Count - 1;
         Leased_Count := Leased_Count + 1;
         Created_Count := Created_Count + 1;
      end Install;

      procedure Creation_Failed (Slot_Index : Positive) is
      begin
         if Slot_Index > Capacity
           or else Slots (Slot_Index).Phase /= Connecting
         then
            raise Program_Error with "invalid HTTP pool creation failure";
         end if;
         Slots (Slot_Index).Phase := Empty;
         Connecting_Count := Connecting_Count - 1;
         if Flyology.Wake_Sources.Descriptor (Checkout_Wake) >= 0
           and then not Checkout_Signalled
         then
            Flyology.Wake_Sources.Signal (Checkout_Wake);
            Checkout_Signalled := True;
         end if;
      end Creation_Failed;

      procedure Return_Lease
        (Slot_Index : Positive;
         Reusable   : Boolean;
         Now        : Ada.Real_Time.Time;
         Result     : out Return_Result;
         Connection : out Pooled_Connection_Access)
      is
         Total_Age : Duration;
      begin
         if Slot_Index > Capacity
           or else Slots (Slot_Index).Phase /= Leased
         then
            raise Program_Error with "invalid HTTP pool lease return";
         end if;
         Connection := Slots (Slot_Index).Connection;
         Total_Age := Ada.Real_Time.To_Duration
           (Now - Slots (Slot_Index).Born);
         Leased_Count := Leased_Count - 1;
         if Reusable and then not Stopping
           and then Idle_Count < Policy.Max_Idle
           and then
             (Policy.Max_Connection_Age < 0.0
                or else Total_Age < Policy.Max_Connection_Age)
           and then
             (Policy.Max_Requests_Per_Connection = 0
                or else Slots (Slot_Index).Request_Count <
                  Policy.Max_Requests_Per_Connection)
         then
            Slots (Slot_Index).Phase := Idle;
            Slots (Slot_Index).Last_Used := Now;
            Idle_Count := Idle_Count + 1;
            Result := Returned_Idle;
         else
            Slots (Slot_Index).Phase := Closing;
            Closing_Count := Closing_Count + 1;
            Result := Return_Close;
         end if;
         if Flyology.Wake_Sources.Descriptor (Checkout_Wake) >= 0
           and then not Checkout_Signalled
         then
            Flyology.Wake_Sources.Signal (Checkout_Wake);
            Checkout_Signalled := True;
         end if;
      end Return_Lease;

      procedure Finish_Close (Slot_Index : Positive) is
      begin
         if Slot_Index > Capacity
           or else Slots (Slot_Index).Phase /= Closing
         then
            raise Program_Error with "invalid HTTP pool close completion";
         end if;
         Slots (Slot_Index) := (others => <>);
         Closing_Count := Closing_Count - 1;
         Closed_Count := Closed_Count + 1;
         if Flyology.Wake_Sources.Descriptor (Checkout_Wake) >= 0
           and then not Checkout_Signalled
         then
            Flyology.Wake_Sources.Signal (Checkout_Wake);
            Checkout_Signalled := True;
         end if;
      end Finish_Close;

      procedure Take_Idle
        (Found      : out Boolean;
         Slot_Index : out Natural;
         Connection : out Pooled_Connection_Access) is
      begin
         Found := False;
         Slot_Index := 0;
         Connection := null;
         for Index in Slots'Range loop
            if Slots (Index).Phase = Idle then
               Slots (Index).Phase := Closing;
               Idle_Count := Idle_Count - 1;
               Closing_Count := Closing_Count + 1;
               Found := True;
               Slot_Index := Index;
               Connection := Slots (Index).Connection;
               exit;
            end if;
         end loop;
      end Take_Idle;

      procedure Request_Shutdown is
      begin
         if not Stopping then
            Stopping := True;
            Flyology.Wake_Sources.Ensure (Shutdown_Wake);
            Flyology.Wake_Sources.Signal (Shutdown_Wake);
            if Flyology.Wake_Sources.Descriptor (Checkout_Wake) >= 0
              and then not Checkout_Signalled
            then
               Flyology.Wake_Sources.Signal (Checkout_Wake);
               Checkout_Signalled := True;
            end if;
         end if;
      end Request_Shutdown;

      entry Await_Drained
        when Connecting_Count + Leased_Count + Idle_Count + Closing_Count = 0
      is
      begin
         null;
      end Await_Drained;

      procedure Wait_Source
        (FD : out Flyology.IO.Descriptor; Can_Checkout : out Boolean)
      is
      begin
         Can_Checkout := Stopping;
         if not Can_Checkout then
            for Item of Slots loop
               if Item.Phase in Empty | Idle then
                  Can_Checkout := True;
                  exit;
               end if;
            end loop;
         end if;
         if Can_Checkout then
            FD := Flyology.IO.Invalid_Descriptor;
         else
            Flyology.Wake_Sources.Ensure (Checkout_Wake);
            FD := Flyology.Wake_Sources.Descriptor (Checkout_Wake);
         end if;
      end Wait_Source;

      procedure Shutdown_Source
        (FD : out Flyology.IO.Descriptor; Requested : out Boolean) is
      begin
         Requested := Stopping;
         if Stopping then
            FD := Flyology.IO.Invalid_Descriptor;
         else
            Flyology.Wake_Sources.Ensure (Shutdown_Wake);
            FD := Flyology.Wake_Sources.Descriptor (Shutdown_Wake);
         end if;
      end Shutdown_Source;

      procedure Register_Waiter is
      begin
         Waiter_Count := Waiter_Count + 1;
      end Register_Waiter;

      procedure Unregister_Waiter is
      begin
         if Waiter_Count = 0 then
            raise Program_Error with "HTTP pool waiter released twice";
         end if;
         Waiter_Count := Waiter_Count - 1;
      end Unregister_Waiter;

      procedure Record_Admission_Timeout is
      begin
         Timeout_Count := Timeout_Count + 1;
      end Record_Admission_Timeout;

      function Snapshot return Pool_Snapshot is
        (Capacity          => Capacity,
         Connecting        => Connecting_Count,
         Leased            => Leased_Count,
         Idle              => Idle_Count,
         Closing           => Closing_Count,
         Waiters            => Waiter_Count,
         Created            => Created_Count,
         Reused             => Reused_Count,
         Closed             => Closed_Count,
         Admission_Timeouts => Timeout_Count);
   end Pool_Controller;

   type Client_State (Capacity : Positive) is limited record
      Manager       : aliased Connections.Server (Capacity => Capacity);
      Pool          : Pool_Controller (Capacity);
      Origin_Value  : Origin;
      Is_Configured : Boolean := False;
   end record;

   type Body_Mode is (No_Body, Fixed_Body, Chunked_Body, Until_Close_Body);

   type Response_Data is record
      Owner          : Client_State_Access := null;
      Connection     : Pooled_Connection_Access := null;
      Slot_Index     : Natural := 0;
      Status_Value   : Status_Code := 200;
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
      Started        : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Timeout        : Duration := 0.0;
      Token          : access Flyology.Cancellation.Token := null;
   end record;

   procedure Free_State is new Ada.Unchecked_Deallocation
     (Client_State, Client_State_Access);
   procedure Free_Response_Data is new Ada.Unchecked_Deallocation
     (Response_Data, Response_Data_Access);

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
         begin
            Connections.Close (Connection.Channel);
         exception
            when others => null;
         end;
         Free_Connection (Connection);
      end if;
      Owner.Pool.Finish_Close (Slot_Index);
   end Close_And_Finish;

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

   procedure Set_Body (Item : in out Request; Value : String) is
   begin
      Item.Body_Value := Flyology.Bytes.From_Byte_String (Value);
   end Set_Body;

   procedure Set_Body
     (Item : in out Request; Value : Ada.Streams.Stream_Element_Array) is
   begin
      Item.Body_Value := Flyology.Bytes.To_Unbounded_Bytes (Value);
   end Set_Body;

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
            Free_State (Item.Control.State);
         end if;
         raise;
   end Configure;

   procedure Configure
     (Item         : in out Client;
      Origin_Value : Origin;
      Backend      : not null access Flyology.IO.TLS.Provider'Class;
      Pool         : Pool_Configuration := Default_Pool_Configuration)
   is
   begin
      if Item.Control.State /= null then
         raise Program_Error with "HTTP client is already configured";
      end if;
      Item.TLS_Backend := Backend;
      Item.Control.State := new Client_State (Item.Capacity);
      Item.Control.State.Origin_Value := Origin_Value;
      Item.Control.State.Pool.Configure (Pool);
      Item.Control.State.Is_Configured := True;
   exception
      when others =>
         if Item.Control.State /= null
           and then not Item.Control.State.Is_Configured
         then
            Free_State (Item.Control.State);
         end if;
         Item.TLS_Backend := null;
         raise;
   end Configure;

   procedure Interrupt_Sources
     (State   : not null Client_State_Access;
      Token   : access Flyology.Cancellation.Token;
      Sources : out Flyology.IO.Interrupt_Set;
      Count   : out Natural)
   is
      FD        : Flyology.IO.Descriptor;
      Requested : Boolean;
   begin
      Count := 0;
      State.Pool.Shutdown_Source (FD, Requested);
      if Requested then
         raise Client_Closed;
      end if;
      Count := Count + 1;
      Sources (Sources'First + Count - 1) := FD;
      if Token /= null then
         Token.Wait_Source (FD, Requested);
         if Requested then
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
         Count := Count + 1;
         Sources (Sources'First + Count - 1) := FD;
      end if;
   end Interrupt_Sources;

   procedure Translate_Interruption
     (State : not null Client_State_Access;
      Token : access Flyology.Cancellation.Token)
     with No_Return
   is
      FD : Flyology.IO.Descriptor;
      Requested : Boolean;
   begin
      State.Pool.Shutdown_Source (FD, Requested);
      if Requested then
         raise Client_Closed;
      elsif Token /= null and then Token.Requested then
         raise Flyology.Cancellation.Operation_Cancelled;
      else
         raise Flyology.Cancellation.Operation_Cancelled;
      end if;
   end Translate_Interruption;

   procedure Establish
     (Item       : in out Client;
      State      : not null Client_State_Access;
      Connection : in out Pooled_Connection_Access;
      Started    : Ada.Real_Time.Time;
      Timeout    : Duration;
      Token      : access Flyology.Cancellation.Token)
   is
      Socket    : Sockets.Socket_Type;
      Connected : Boolean := False;

      procedure Cleanup is
      begin
         if Sockets.Is_Open (Socket) then
            begin
               Sockets.Close_Socket (Socket);
            exception
               when others => null;
            end;
         end if;
         if Connection /= null then
            begin
               Connections.Close (Connection.Channel);
            exception
               when others => null;
            end;
            Free_Connection (Connection);
         end if;
      end Cleanup;
   begin
      declare
         Sources : Flyology.IO.Interrupt_Set (1 .. 2);
         Count   : Natural;
      begin
         Interrupt_Sources (State, Token, Sources, Count);
         declare
            Addresses : constant Flyology.IO.DNS.Address_Array :=
              Flyology.IO.DNS.Resolve
                (Host (State.Origin_Value),
                 Timeout => Remaining (Started, Timeout),
                 Interrupts => Sources (1 .. Count));
         begin
            for Address of Addresses loop
               begin
                  Sockets.Create_Socket (Socket, Address.Family);
                  Interrupt_Sources (State, Token, Sources, Count);
                  Sockets.Connect
                    (Socket,
                     Sockets.Network_Endpoint
                       (Address, Sockets.Port (Port (State.Origin_Value))),
                     Remaining (Started, Timeout), Sources (1 .. Count));
                  Connected := True;
               exception
                  when Sockets.Operation_Interrupted =>
                     if Sockets.Is_Open (Socket) then
                        Sockets.Close_Socket (Socket);
                     end if;
                     Translate_Interruption (State, Token);
                  when Flyology.IO.Timeout_Error =>
                     if Sockets.Is_Open (Socket) then
                        Sockets.Close_Socket (Socket);
                     end if;
                     raise;
                  when Sockets.Socket_Error | Flyology.IO.Device_Error =>
                     if Sockets.Is_Open (Socket) then
                        begin
                           Sockets.Close_Socket (Socket);
                        exception
                           when others => null;
                        end;
                     end if;
               end;
               exit when Connected;
            end loop;
         end;
      end;

      if not Connected then
         raise Connection_Error with "all resolved HTTP endpoints failed";
      end if;

      Connection := new Pooled_Connection;
      Connections.Take (State.Manager, Socket, Connection.Channel);
      if Scheme (State.Origin_Value) = Secure_HTTPS then
         Flyology.IO.Connections.TLS.Upgrade
           (Connection.Channel, Item.TLS_Backend.all,
            Flyology.IO.TLS.Client, Host (State.Origin_Value),
            Remaining (Started, Timeout), Token);
      end if;
   exception
      when Flyology.IO.DNS.Operation_Cancelled =>
         Cleanup;
         Translate_Interruption (State, Token);
      when Flyology.IO.DNS.Name_Not_Found |
           Flyology.IO.DNS.Resolution_Failed |
           Flyology.IO.DNS.Malformed_Response =>
         Cleanup;
         raise Connection_Error with "HTTP origin resolution failed";
      when Connections.Admission_Closed =>
         Cleanup;
         raise Client_Closed;
      when Flyology.Cancellation.Operation_Cancelled =>
         Cleanup;
         Translate_Interruption (State, Token);
      when others =>
         Cleanup;
         raise;
   end Establish;

   procedure Wait_For_Pool
     (State   : not null Client_State_Access;
      Started : Ada.Real_Time.Time;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      Pool_FD   : Flyology.IO.Descriptor;
      Token_FD  : Flyology.IO.Descriptor := Flyology.IO.Invalid_Descriptor;
      Ready_Now : Boolean;
      Cancelled : Boolean := False;
      Index     : Natural;
   begin
      State.Pool.Wait_Source (Pool_FD, Ready_Now);
      if Ready_Now then
         return;
      end if;
      if Token /= null then
         Token.Wait_Source (Token_FD, Cancelled);
         if Cancelled then
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
      end if;
      if Token = null then
         declare
            Sources : Flyology.IO.Wait_Request_Array (1 .. 1);
         begin
            Sources (1) :=
              (FD => Pool_FD, Condition => Flyology.IO.For_Read);
            Index := Flyology.IO.Wait_Any
              (Sources, Remaining (Started, Timeout));
         end;
      else
         declare
            Sources : Flyology.IO.Wait_Request_Array (1 .. 2);
         begin
            Sources (1) :=
              (FD => Pool_FD, Condition => Flyology.IO.For_Read);
            Sources (2) :=
              (FD => Token_FD, Condition => Flyology.IO.For_Read);
            Index := Flyology.IO.Wait_Any
              (Sources, Remaining (Started, Timeout));
         end;
      end if;
      if Index = 0 then
         State.Pool.Record_Admission_Timeout;
         raise Flyology.IO.Timeout_Error;
      elsif Index = 2 then
         raise Flyology.Cancellation.Operation_Cancelled;
      end if;
   end Wait_For_Pool;

   procedure Checkout
     (Item       : in out Client;
      Connection : out Pooled_Connection_Access;
      Slot_Index : out Positive;
      Started    : Ada.Real_Time.Time;
      Timeout    : Duration;
      Token      : access Flyology.Cancellation.Token)
   is
      Result : Checkout_Result;
      Index  : Natural;
      Value  : Pooled_Connection_Access;
      Waiting : Boolean := False;
   begin
      if Item.Control.State = null
        or else not Item.Control.State.Is_Configured
      then
         raise Program_Error with "HTTP client is not configured";
      end if;
      loop
         Item.Control.State.Pool.Try_Checkout
           (Ada.Real_Time.Clock, Result, Index, Value);
         case Result is
            when Checkout_Idle =>
               if Waiting then
                  Item.Control.State.Pool.Unregister_Waiter;
                  Waiting := False;
               end if;
               Connection := Value;
               Slot_Index := Positive (Index);
               return;
            when Checkout_Create =>
               begin
                  Establish
                    (Item, Item.Control.State, Value, Started, Timeout, Token);
                  Item.Control.State.Pool.Install
                    (Positive (Index), Value, Ada.Real_Time.Clock);
               exception
                  when others =>
                     Item.Control.State.Pool.Creation_Failed
                       (Positive (Index));
                     if Waiting then
                        Item.Control.State.Pool.Unregister_Waiter;
                        Waiting := False;
                     end if;
                     raise;
               end;
               if Waiting then
                  Item.Control.State.Pool.Unregister_Waiter;
                  Waiting := False;
               end if;
               Connection := Value;
               Slot_Index := Positive (Index);
               return;
            when Checkout_Discard =>
               Close_And_Finish
                 (Item.Control.State, Positive (Index), Value);
            when Checkout_Busy =>
               if not Waiting then
                  Item.Control.State.Pool.Register_Waiter;
                  Waiting := True;
               end if;
               Wait_For_Pool
                 (Item.Control.State, Started, Timeout, Token);
            when Checkout_Closed =>
               if Waiting then
                  Item.Control.State.Pool.Unregister_Waiter;
                  Waiting := False;
               end if;
               raise Client_Closed;
         end case;
      end loop;
   exception
      when others =>
         if Waiting then
            begin
               Item.Control.State.Pool.Unregister_Waiter;
            exception
               when others => null;
            end;
         end if;
         raise;
   end Checkout;

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

   function Request_Head
     (State : Client_State; Value : Request) return String
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
      if Body_Length > 0 then
         Append (Result, "Content-Length: " & Decimal (Body_Length) & CRLF);
      end if;
      Append (Result, CRLF);
      return To_String (Result);
   end Request_Head;

   procedure Receive_More
     (Data : in out Response_Data; Peer_Closed : out Boolean)
   is
      Buffer : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Receive_Buffer_Size));
      Last   : Ada.Streams.Stream_Element_Offset;
   begin
      Connections.Receive
        (Data.Connection.Channel, Buffer, Last,
         Remaining (Data.Started, Data.Timeout), Token => Data.Token);
      Peer_Closed := Last < Buffer'First;
      if not Peer_Closed then
         Append (Data.Pending, Byte_String (Buffer (Buffer'First .. Last)));
      end if;
   end Receive_More;

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

   procedure Read_Final_Head (Data : in out Response_Data) is
      Closed : Boolean;
      Informational : Natural := 0;
   begin
      loop
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
                  exit;
               elsif Text'Length >=
                 Flyology.HTTP.Headers.Default_Max_Bytes
               then
                  raise Response_Too_Large;
               end if;
            end;
            Receive_More (Data, Closed);
            if Closed then
               raise Protocol_Error with
                 "peer closed during HTTP response head";
            end if;
         end loop;

         exit when Data.Status_Value not in 100 .. 199;
         if Data.Status_Value = 101 then
            raise Protocol_Error with "HTTP protocol upgrade is unsupported";
         elsif Flyology.HTTP.Headers.Count (Data.Fields, "Content-Length") > 0
           or else Flyology.HTTP.Headers.Count
             (Data.Fields, "Transfer-Encoding") > 0
         then
            raise Protocol_Error with
              "informational HTTP response contains body framing";
         end if;
         Informational := Informational + 1;
         if Informational > Max_Informational_Responses then
            raise Protocol_Error with "too many informational HTTP responses";
         end if;
      end loop;
   end Read_Final_Head;

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

   function Execute
     (Item    : aliased in out Client;
      Value   : Request;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null) return Response
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Connection : Pooled_Connection_Access;
      Slot       : Positive;
   begin
      if Item.Control.State = null
        or else not Item.Control.State.Is_Configured
      then
         raise Program_Error with "HTTP client is not configured";
      end if;
      Validate_Request (Value);
      return Result : Response do
         Result.Data := new Response_Data;
         Result.Data.Started := Started;
         Result.Data.Timeout := Timeout;
         Result.Data.Token := Token;
         Checkout (Item, Connection, Slot, Started, Timeout, Token);
         Result.Data.Owner := Item.Control.State;
         Result.Data.Connection := Connection;
         Result.Data.Slot_Index := Slot;
         declare
            Head : constant String := Request_Head
              (Item.Control.State.all, Value);
         begin
            Connections.Send_All
              (Result.Data.Connection.Channel, Byte_Array (Head),
               Remaining (Started, Timeout), Token => Token);
         end;
         if Flyology.Bytes.Length (Value.Body_Value) > 0 then
            Connections.Send_All
              (Result.Data.Connection.Channel,
               Flyology.Bytes.To_Array (Value.Body_Value),
               Remaining (Started, Timeout), Token => Token);
         end if;
         Read_Final_Head (Result.Data.all);
         Select_Body_Mode (Result.Data.all, Value.Method_Value);
      end return;
   exception
      when Flyology.Cancellation.Operation_Cancelled =>
         Translate_Interruption (Item.Control.State, Token);
   end Execute;

   function Status (Item : Response) return Status_Code is
   begin
      if Item.Data = null then
         raise Program_Error with "HTTP response is not initialized";
      end if;
      return Item.Data.Status_Value;
   end Status;

   function Negotiated_Protocol (Item : Response) return Protocol is
   begin
      if Item.Data = null then
         raise Program_Error with "HTTP response is not initialized";
      end if;
      return Item.Data.Protocol_Value;
   end Negotiated_Protocol;

   function Header_Count (Item : Response; Name : String) return Natural is
   begin
      if Item.Data = null then
         return 0;
      end if;
      return Flyology.HTTP.Headers.Count (Item.Data.Fields, Name);
   end Header_Count;

   function Header
     (Item : Response; Name : String; Occurrence : Positive := 1) return String
   is
   begin
      if Item.Data = null then
         return "";
      end if;
      return Flyology.HTTP.Headers.Value (Item.Data.Fields, Name, Occurrence);
   end Header;

   function Trailer_Count (Item : Response; Name : String) return Natural is
   begin
      if Item.Data = null then
         return 0;
      end if;
      return Flyology.HTTP.Headers.Count (Item.Data.Trailers, Name);
   end Trailer_Count;

   function Trailer
     (Item : Response; Name : String; Occurrence : Positive := 1) return String
   is
   begin
      if Item.Data = null then
         return "";
      end if;
      return Flyology.HTTP.Headers.Value
        (Item.Data.Trailers, Name, Occurrence);
   end Trailer;

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
     (Data : in out Response_Data; Minimum : Positive)
   is
      Closed : Boolean;
   begin
      while Length (Data.Pending) < Minimum loop
         Receive_More (Data, Closed);
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
     (Data : in out Response_Data; Line : out Unbounded_String)
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
         Receive_More (Data, Closed);
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

   procedure Read_Body
     (Item     : in out Response;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean)
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

      case Item.Data.Mode is
         when No_Body =>
            Release_Lease (Item.Data.all, Item.Data.Reusable);

         when Fixed_Body =>
            while Used < Natural (Data'Length)
              and then Item.Data.Remaining_Body > 0
            loop
               if Length (Item.Data.Pending) = 0 then
                  Receive_More (Item.Data.all, Closed);
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
                  Receive_More (Item.Data.all, Closed);
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
                     Receive_More (Item.Data.all, Closed);
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
                  Ensure_Pending (Item.Data.all, CRLF'Length);
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
                     Read_Chunk_Line (Item.Data.all, Line);
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
                     Read_Chunk_Line (Item.Data.all, Line);
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
         Translate_Interruption (Item.Data.Owner, Item.Data.Token);
      when others =>
         if Item.Data /= null and then Item.Data.Connection /= null then
            Release_Lease (Item.Data.all, False);
         end if;
         raise;
   end Read_Body;

   function Body_Complete (Item : Response) return Boolean is
     (Item.Data = null or else Item.Data.Complete);

   function Read_All
     (Item : in out Response;
      Maximum : Natural := 1_024 * 1_024) return Flyology.Bytes.Unbounded_Bytes
   is
      Result   : Flyology.Bytes.Unbounded_Bytes;
      Buffer   : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Receive_Buffer_Size));
      Last     : Ada.Streams.Stream_Element_Offset;
      Finished : Boolean;
   begin
      loop
         Read_Body (Item, Buffer, Last, Finished);
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

   function Pool_State (Item : Client) return Pool_Snapshot is
   begin
      if Item.Control.State = null then
         return
           (Capacity => Item.Capacity, Connecting | Leased | Idle | Closing |
              Waiters | Created | Reused | Closed | Admission_Timeouts => 0);
      end if;
      return Item.Control.State.Pool.Snapshot;
   end Pool_State;

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
      Snapshot : Pool_Snapshot;
      Found      : Boolean;
      Slot_Index : Natural;
      Connection : Pooled_Connection_Access;
   begin
      if Item.State = null then
         return;
      end if;
      begin
         Item.State.Pool.Request_Shutdown;
         Item.State.Manager.Request_Shutdown;
         loop
            Item.State.Pool.Take_Idle (Found, Slot_Index, Connection);
            exit when not Found;
            Close_And_Finish
              (Item.State, Positive (Slot_Index), Connection);
         end loop;
      exception
         when others => null;
      end;
      Snapshot := Item.State.Pool.Snapshot;
      if Snapshot.Connecting = 0 and then Snapshot.Leased = 0
        and then Snapshot.Idle = 0 and then Snapshot.Closing = 0
      then
         Free_State (Item.State);
      end if;
   end Finalize;

   overriding procedure Finalize (Item : in out Response) is
   begin
      if Item.Data = null then
         return;
      end if;
      if Item.Data.Connection /= null then
         Release_Lease (Item.Data.all, False);
      end if;
      Free_Response_Data (Item.Data);
   exception
      when others =>
         Free_Response_Data (Item.Data);
   end Finalize;

end Flyology.HTTP.Client;
