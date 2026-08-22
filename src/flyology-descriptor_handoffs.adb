with Flyology.Shared_Memory_Native;
with GNAT.OS_Lib;
with Interfaces;

package body Flyology.Descriptor_Handoffs is
   package Native renames Flyology.Shared_Memory_Native;

   use type C.long;
   use type C.size_t;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_32;

   function Current_Error return C.int is (C.int (GNAT.OS_Lib.Errno));

   procedure Raise_Current (Operation : String) is
   begin
      raise Operating_System_Error with
        Operation & " failed (errno" & C.int'Image (Current_Error) & ")";
   end Raise_Current;

   function Has_Flag (Value, Flag : C.int) return Boolean is
     ((Interfaces.Unsigned_32 (Value) and Interfaces.Unsigned_32 (Flag)) /= 0);

   procedure Ensure_Close_On_Exec (Descriptor : C.int) is
      Flags : C.int := Native.Get_Descriptor_Flags (Descriptor);
   begin
      if Flags < 0 then
         Raise_Current ("descriptor flag inspection");
      elsif not Has_Flag (Flags, Native.Descriptor_Close_On_Exec) then
         Flags := Flags + Native.Descriptor_Close_On_Exec;
         if Native.Set_Descriptor_Flags (Descriptor, Flags) /= 0 then
            Raise_Current ("descriptor close-on-exec setup");
         end if;
      end if;
   end Ensure_Close_On_Exec;

   procedure Prepare_Channel (Socket : C.int) is
      Kind, Local_Family, Peer_Family : C.int;
   begin
      if Native.Socket_Type (Socket, Kind) /= 0 then
         if Current_Error = Native.Error_Not_Socket then
            raise Protocol_Error with "handoff carrier is not a socket";
         end if;
         Raise_Current ("handoff socket type inspection");
      elsif Kind /= Native.Stream_Socket_Type then
         raise Protocol_Error with "handoff carrier is not a stream socket";
      end if;
      if Native.Local_Socket_Family (Socket, Local_Family) /= 0 then
         Raise_Current ("handoff local socket inspection");
      elsif Native.Peer_Socket_Family (Socket, Peer_Family) /= 0 then
         if Current_Error = Native.Error_Not_Connected then
            raise Protocol_Error with "handoff carrier is not connected";
         end if;
         Raise_Current ("handoff peer socket inspection");
      elsif Local_Family /= Native.Unix_Socket_Family or else
        Peer_Family /= Native.Unix_Socket_Family
      then
         raise Protocol_Error with "handoff carrier is not AF_UNIX";
      end if;
      Ensure_Close_On_Exec (Socket);
      if Native.Enable_No_SIGPIPE (Socket) /= 0 then
         Raise_Current ("handoff SIGPIPE suppression");
      end if;
   end Prepare_Channel;

   procedure Close_Descriptor (Descriptor : in out C.int) is
      Ignored : C.int;
   begin
      if Descriptor >= 0 then
         Ignored := Native.Close (Descriptor);
         Descriptor := -1;
      end if;
   end Close_Descriptor;

   protected body Channel_Controller is
      procedure Adopt
        (Descriptor : C.int;
         Accepted   : out Boolean) is
      begin
         Accepted := State = Closed;
         if Accepted then
            Descriptor_Value := Descriptor;
            State := Ready;
         end if;
      end Adopt;

      procedure Try_Begin
        (Descriptor : out C.int;
         Result     : out Begin_Result) is
      begin
         Descriptor := -1;
         case State is
            when Ready =>
               State := Busy;
               Descriptor := Descriptor_Value;
               Result := Acquired;
            when Closed => Result := Was_Closed;
            when Busy => Result := Was_Busy;
            when Poisoned => Result := Was_Poisoned;
         end case;
      end Try_Begin;

      procedure Finish is
      begin
         if State = Busy then
            State := Ready;
         end if;
      end Finish;

      procedure Poison (Descriptor : out C.int) is
      begin
         Descriptor := Descriptor_Value;
         Descriptor_Value := -1;
         State := Poisoned;
      end Poison;

      procedure Take_For_Close
        (Descriptor : out C.int;
         Busy_Now   : out Boolean) is
      begin
         Busy_Now := State = Busy;
         if Busy_Now then
            Descriptor := -1;
         else
            Descriptor := Descriptor_Value;
            Descriptor_Value := -1;
            State := Closed;
         end if;
      end Take_For_Close;

      function Open return Boolean is (State in Ready | Busy);
      function Failed return Boolean is (State = Poisoned);
   end Channel_Controller;

   procedure Begin_Operation
     (Item       : in out Handoff_Channel;
      Descriptor : out C.int)
   is
      Result : Begin_Result;
   begin
      Item.Owner.Controller.Try_Begin (Descriptor, Result);
      case Result is
         when Acquired => null;
         when Was_Closed =>
            raise Validation_Error with "handoff channel is closed";
         when Was_Busy =>
            raise Channel_Busy with "handoff channel is already in use";
         when Was_Poisoned =>
            raise Protocol_Error with "handoff channel is poisoned";
      end case;
   end Begin_Operation;

   procedure Poison_And_Close (Item : in out Handoff_Channel) is
      Descriptor : C.int;
   begin
      Item.Owner.Controller.Poison (Descriptor);
      Close_Descriptor (Descriptor);
   end Poison_And_Close;

   procedure Validate_Carrier
     (Socket : Socket_Descriptor;
      Trust  : Peer_Trust := Trusted_Peer)
   is
   begin
      if Socket < 0 then
         raise Validation_Error with "Unix-domain socket is invalid";
      elsif Trust = Untrusted_Peer and then
        not Native.Untrusted_Handoff_Supported
      then
         raise Security_Error with
           "untrusted descriptor handoff is unavailable on this host";
      end if;
      Prepare_Channel (C.int (Socket));
   end Validate_Carrier;

   procedure Adopt
     (Item   : in out Handoff_Channel;
      Socket : in out Socket_Descriptor;
      Trust  : Peer_Trust := Trusted_Peer)
   is
      Accepted : Boolean;
   begin
      if Is_Open (Item) then
         raise Validation_Error with "handoff channel is already open";
      elsif Is_Poisoned (Item) then
         raise Protocol_Error with "handoff channel is poisoned";
      end if;
      Validate_Carrier (Socket, Trust);
      Item.Owner.Controller.Adopt (C.int (Socket), Accepted);
      if not Accepted then
         raise Validation_Error with "handoff channel is already open";
      end if;
      Socket := -1;
   end Adopt;

   procedure Close (Item : in out Handoff_Channel) is
      Descriptor : C.int;
      Busy_Now   : Boolean;
      Status     : C.int;
   begin
      Item.Owner.Controller.Take_For_Close (Descriptor, Busy_Now);
      if Busy_Now then
         raise Channel_Busy with "handoff channel is already in use";
      elsif Descriptor >= 0 then
         Status := Native.Close (Descriptor);
         if Status /= 0 then
            Raise_Current ("handoff channel close");
         end if;
      end if;
   end Close;

   procedure Poison (Item : in out Handoff_Channel) is
   begin
      Poison_And_Close (Item);
   end Poison;

   function Is_Open (Item : Handoff_Channel) return Boolean is
     (Item.Owner.Controller.Open);

   function Is_Poisoned (Item : Handoff_Channel) return Boolean is
     (Item.Owner.Controller.Failed);

   overriding procedure Finalize (Item : in out Channel_Owner) is
      Descriptor : C.int;
      Busy_Now   : Boolean;
   begin
      Item.Controller.Take_For_Close (Descriptor, Busy_Now);
      if Busy_Now then
         Item.Controller.Poison (Descriptor);
      end if;
      Close_Descriptor (Descriptor);
   exception
      when others => null;
   end Finalize;

   procedure Send
     (Channel    : in out Handoff_Channel;
      Descriptor : C.int)
   is
      Socket   : C.int;
      Amount   : C.long;
      Error    : C.int;
      Acquired : Boolean := False;
   begin
      if Descriptor < 0 then
         raise Validation_Error with "handoff descriptor is invalid";
      end if;
      Begin_Operation (Channel, Socket);
      Acquired := True;
      loop
         Amount := Native.Send_Descriptor_Once (Socket, Descriptor);
         exit when Amount >= 0;
         Error := Current_Error;
         exit when Error /= Native.Error_Interrupted;
      end loop;
      if Amount /= 1 then
         if Amount < 0 then
            Raise_Current ("SCM_RIGHTS send");
         else
            raise Protocol_Error with "SCM_RIGHTS send was not atomic";
         end if;
      end if;
      Channel.Owner.Controller.Finish;
      Acquired := False;
   exception
      when others =>
         if Acquired then
            Poison_And_Close (Channel);
         end if;
         raise;
   end Send;

   procedure Receive
     (Channel    : in out Handoff_Channel;
      Descriptor : out C.int)
   is
      Socket      : C.int;
      Descriptors : Native.Descriptor_Array (0 .. 511) := (others => -1);
      Count       : C.size_t := 0;
      Payload     : Interfaces.Unsigned_8 := 0;
      Flags       : C.int := 0;
      Malformed   : Boolean := False;
      Amount      : C.long;
      Error       : C.int;
      Acquired    : Boolean := False;
      Result      : C.int := -1;
   begin
      Descriptor := -1;
      Begin_Operation (Channel, Socket);
      Acquired := True;
      loop
         Amount := Native.Receive_Descriptors_Once
           (Socket, Native.Message_Close_On_Exec, Descriptors, Count,
            Payload, Flags, Malformed);
         exit when Amount >= 0;
         Error := Current_Error;
         exit when Error /= Native.Error_Interrupted;
      end loop;
      if Amount < 0 then
         Raise_Current ("SCM_RIGHTS receive");
      elsif Amount /= 1 or else Payload = 0 or else Count /= 1 or else
        Malformed or else
        Has_Flag (Flags, Native.Message_Control_Truncated) or else
        Has_Flag (Flags, Native.Message_Truncated)
      then
         raise Protocol_Error with "invalid SCM_RIGHTS record";
      end if;
      Result := Descriptors (0);
      Descriptors (0) := -1;
      Ensure_Close_On_Exec (Result);
      Descriptor := Result;
      Result := -1;
      Channel.Owner.Controller.Finish;
      Acquired := False;
   exception
      when others =>
         Close_Descriptor (Result);
         for Index in Descriptors'Range loop
            Close_Descriptor (Descriptors (Index));
         end loop;
         if Acquired then
            Poison_And_Close (Channel);
         end if;
         raise;
   end Receive;

end Flyology.Descriptor_Handoffs;
