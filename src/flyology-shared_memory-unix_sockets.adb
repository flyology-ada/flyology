with Flyology.Shared_Memory_Native;
with Flyology.Shared_Memory_Policy;
with GNAT.OS_Lib;
with Interfaces;

package body Flyology.Shared_Memory.Unix_Sockets is
   package Native renames Flyology.Shared_Memory_Native;
   package Policy renames Flyology.Shared_Memory_Policy;

   use type Byte_Length;
   use type C.long;
   use type C.size_t;
   use type Interfaces.Unsigned_32;

   function Current_Error return C.int is (C.int (GNAT.OS_Lib.Errno));

   procedure Raise_Child_Failure (Operation : String; Code : C.int) is
   begin
      if Code = -5 then
         raise Protocol_Error with Operation & ": invalid handoff protocol";
      elsif Code = -1 then
         raise Validation_Error with Operation & ": exact size does not match";
      elsif Code = -2 then
         raise Validation_Error with
           Operation & ": object type does not match";
      elsif Code = -3 then
         raise Security_Error with
           Operation & ": required security property is unavailable";
      else
         raise Operating_System_Error with
           Operation & " failed (errno" & C.int'Image (Code) & ")";
      end if;
   end Raise_Child_Failure;

   procedure Raise_Current (Operation : String) is
   begin
      Raise_Child_Failure (Operation, Current_Error);
   end Raise_Current;

   function Has_Flag (Value, Flag : C.int) return Boolean is
     ((Interfaces.Unsigned_32 (Value) and Interfaces.Unsigned_32 (Flag)) /= 0);

   procedure Ensure_Close_On_Exec (Descriptor : C.int) is
      Flags : C.int := Native.Get_Descriptor_Flags (Descriptor);
   begin
      if Flags < 0 then
         Raise_Current ("handoff descriptor flag inspection");
      elsif not Has_Flag (Flags, Native.Descriptor_Close_On_Exec) then
         Flags := Flags + Native.Descriptor_Close_On_Exec;
         if Native.Set_Descriptor_Flags (Descriptor, Flags) /= 0 then
            Raise_Current ("handoff descriptor close-on-exec setup");
         end if;
      end if;
   end Ensure_Close_On_Exec;

   procedure Prepare_Handoff_Socket (Socket : C.int) is
      Kind, Local_Family, Peer_Family : C.int;
   begin
      if Native.Socket_Type (Socket, Kind) /= 0 then
         if Current_Error = Native.Error_Not_Socket then
            Raise_Child_Failure ("handoff socket validation", -5);
         else
            Raise_Current ("handoff socket type inspection");
         end if;
      elsif Kind /= Native.Stream_Socket_Type then
         Raise_Child_Failure ("handoff socket validation", -5);
      end if;
      if Native.Local_Socket_Family (Socket, Local_Family) /= 0 then
         Raise_Current ("handoff local socket inspection");
      elsif Native.Peer_Socket_Family (Socket, Peer_Family) /= 0 then
         if Current_Error = Native.Error_Not_Connected then
            Raise_Child_Failure ("handoff socket validation", -5);
         else
            Raise_Current ("handoff peer socket inspection");
         end if;
      elsif Local_Family /= Native.Unix_Socket_Family
        or else Peer_Family /= Native.Unix_Socket_Family
      then
         Raise_Child_Failure ("handoff socket validation", -5);
      end if;
      Ensure_Close_On_Exec (Socket);
      if Native.Enable_No_SIGPIPE (Socket) /= 0 then
         Raise_Current ("handoff SIGPIPE suppression");
      end if;
   end Prepare_Handoff_Socket;

   procedure Send_One (Socket, Descriptor : C.int) is
      Amount : C.long;
      Error  : C.int;
   begin
      Prepare_Handoff_Socket (Socket);
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
            Raise_Child_Failure ("SCM_RIGHTS send", Native.Error_IO);
         end if;
      end if;
   end Send_One;

   procedure Close_Descriptors
     (Descriptors : in out Native.Descriptor_Array;
      Count       : C.size_t)
   is
      Ignored : C.int;
      Last : constant C.size_t :=
        C.size_t'Min (Count, Descriptors'Length);
   begin
      if Last = 0 then
         return;
      end if;
      for Index in C.size_t range 0 .. Last - 1 loop
         if Descriptors (Index) >= 0 then
            Ignored := Native.Close (Descriptors (Index));
            Descriptors (Index) := -1;
         end if;
      end loop;
   end Close_Descriptors;

   protected body Channel_Controller is
      procedure Adopt
        (Descriptor : C.int;
         Trust      : Peer_Trust;
         Accepted   : out Boolean) is
      begin
         Accepted := State = Closed;
         if Accepted then
            Descriptor_Value := Descriptor;
            Trust_Value := Trust;
            State := Ready;
         end if;
      end Adopt;

      procedure Try_Begin
        (Descriptor : out C.int;
         Trust      : out Peer_Trust;
         Result     : out Begin_Result) is
      begin
         Descriptor := -1;
         Trust := Trust_Value;
         case State is
            when Ready =>
               State := Busy;
               Descriptor := Descriptor_Value;
               Result := Acquired;
            when Closed =>
               Result := Was_Closed;
            when Busy =>
               Result := Was_Busy;
            when Poisoned =>
               Result := Was_Poisoned;
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

      function Open return Boolean is (State = Ready or else State = Busy);

      function Failed return Boolean is (State = Poisoned);

      function Busy_Now return Boolean is (State = Busy);
   end Channel_Controller;

   procedure Begin_Operation
     (Item       : in out Handoff_Channel;
      Descriptor : out C.int;
      Trust      : out Peer_Trust)
   is
      Result : Begin_Result;
   begin
      Item.Owner.Controller.Try_Begin (Descriptor, Trust, Result);
      case Result is
         when Acquired =>
            null;
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
      Ignored    : C.int;
   begin
      Item.Owner.Controller.Poison (Descriptor);
      if Descriptor >= 0 then
         Ignored := Native.Close (Descriptor);
      end if;
   end Poison_And_Close;

   procedure Receive_Validated
     (Socket                 : C.int;
      Expected_Length        : Byte_Length;
      Require_Immutable_Size : Boolean;
      Descriptor             : out C.int;
      Props                  : out Security_Properties)
   is
      Descriptors : Native.Descriptor_Array (0 .. 511) := (others => -1);
      Count       : C.size_t := 0;
      Payload     : Interfaces.Unsigned_8 := 0;
      Message_Flags : C.int := 0;
      Malformed   : Boolean := False;
      Amount      : C.long;
      Error       : C.int := 0;
      Local_Descriptor : C.int := -1;
   begin
      Prepare_Handoff_Socket (Socket);
      loop
         Amount := Native.Receive_Descriptors_Once
           (Socket, Native.Message_Close_On_Exec, Descriptors, Count,
            Payload, Message_Flags, Malformed);
         exit when Amount >= 0;
         Error := Current_Error;
         exit when Error /= Native.Error_Interrupted;
      end loop;
      if Amount < 0 then
         Raise_Child_Failure ("SCM_RIGHTS receive", Error);
      elsif Count > Descriptors'Length
        or else not Policy.Valid_Handoff
          (Long_Long_Integer (Amount), Payload,
           Interfaces.Unsigned_64 (Count), Malformed,
           Has_Flag (Message_Flags, Native.Message_Control_Truncated),
           Has_Flag (Message_Flags, Native.Message_Truncated))
      then
         Close_Descriptors (Descriptors, Count);
         Raise_Child_Failure ("SCM_RIGHTS receive", -5);
      end if;
      Local_Descriptor := Descriptors (0);
      Descriptors (0) := -1;
      Validate_Received
        (Local_Descriptor, Expected_Length, Require_Immutable_Size, Props);
      Descriptor := Local_Descriptor;
      Local_Descriptor := -1;
   exception
      when others =>
         Close_Descriptors (Descriptors, Count);
         if Local_Descriptor >= 0 then
            declare
               Ignored : constant C.int := Native.Close (Local_Descriptor);
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         end if;
         raise;
   end Receive_Validated;

   procedure Adopt
     (Item   : in out Handoff_Channel;
      Socket : in out Socket_Descriptor;
      Trust  : Peer_Trust := Trusted_Peer)
   is
      Accepted : Boolean;
   begin
      if Socket < 0 then
         raise Validation_Error with "Unix-domain socket is invalid";
      elsif Is_Open (Item) then
         raise Validation_Error with "handoff channel is already open";
      elsif Is_Poisoned (Item) then
         raise Protocol_Error with "handoff channel is poisoned";
      elsif Trust = Untrusted_Peer
        and then not Native.Untrusted_Handoff_Supported
      then
         raise Security_Error with
           "untrusted SCM_RIGHTS receipt is unavailable on this host";
      end if;
      Prepare_Handoff_Socket (C.int (Socket));
      Item.Owner.Controller.Adopt (C.int (Socket), Trust, Accepted);
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

   function Is_Open (Item : Handoff_Channel) return Boolean is
     (Item.Owner.Controller.Open);

   function Is_Poisoned (Item : Handoff_Channel) return Boolean is
     (Item.Owner.Controller.Failed);

   overriding procedure Finalize (Item : in out Channel_Owner) is
      Descriptor : C.int;
      Busy_Now   : Boolean;
      Ignored    : C.int;
   begin
      Item.Controller.Take_For_Close (Descriptor, Busy_Now);
      if Busy_Now then
         Item.Controller.Poison (Descriptor);
      end if;
      if Descriptor >= 0 then
         Ignored := Native.Close (Descriptor);
      end if;
   exception
      when others =>
         null;
   end Finalize;

   procedure Send
     (Socket    : Socket_Descriptor;
      Item      : in out Backing_Object;
      Ownership : Send_Ownership := Borrow)
   is
   begin
      if Socket < 0 then
         raise Validation_Error with "Unix-domain socket is invalid";
      elsif not Shared_Memory.Is_Open (Item) then
         raise Validation_Error with "backing object is closed";
      end if;
      Send_One (C.int (Socket), Owned_Descriptor (Item));
      if Ownership = Transfer then
         Close (Item);
      end if;
   end Send;

   procedure Send
     (Channel   : in out Handoff_Channel;
      Item      : in out Backing_Object;
      Ownership : Send_Ownership := Borrow)
   is
      Socket   : C.int;
      Trust    : Peer_Trust;
      Acquired : Boolean := False;
   begin
      if not Shared_Memory.Is_Open (Item) then
         raise Validation_Error with "backing object is closed";
      end if;
      Begin_Operation (Channel, Socket, Trust);
      Acquired := True;
      begin
         Send_One (Socket, Owned_Descriptor (Item));
      exception
         when others =>
            Poison_And_Close (Channel);
            raise;
      end;
      Channel.Owner.Controller.Finish;
      Acquired := False;
      if Ownership = Transfer then
         Shared_Memory.Close (Item);
      end if;
   exception
      when others =>
         if Acquired and then Channel.Owner.Controller.Open then
            Channel.Owner.Controller.Finish;
         end if;
         raise;
   end Send;

   procedure Receive
     (Socket                 : Socket_Descriptor;
      Expected_Length        : Byte_Length;
      Item                   : in out Backing_Object;
      Require_Immutable_Size : Boolean := False)
   is
      Descriptor : C.int := -1;
      Props      : Security_Properties;
   begin
      if Socket < 0 then
         raise Validation_Error with "Unix-domain socket is invalid";
      elsif Is_Open (Item) then
         raise Validation_Error with
           "receive target already owns a descriptor";
      elsif Expected_Length = 0 then
         raise Constraint_Error with
           "received shared-memory length is not natively representable";
      end if;

      Receive_Validated
        (C.int (Socket), Expected_Length, Require_Immutable_Size,
         Descriptor, Props);
      Adopt_Received (Item, Descriptor, Expected_Length, Props);
      Descriptor := -1;
   exception
      when others =>
         if Descriptor >= 0 and then not Shared_Memory.Is_Open (Item) then
            declare
               Ignored : constant C.int := Native.Close (Descriptor);
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         end if;
         raise;
   end Receive;

   procedure Receive
     (Channel                : in out Handoff_Channel;
      Expected_Length        : Byte_Length;
      Item                   : in out Backing_Object;
      Require_Immutable_Size : Boolean := False)
   is
      Socket     : C.int;
      Trust      : Peer_Trust;
      Descriptor : C.int := -1;
      Props      : Security_Properties;
      Ignored    : C.int;
   begin
      if Shared_Memory.Is_Open (Item) then
         raise Validation_Error with
           "receive target already owns a descriptor";
      elsif Expected_Length = 0 then
         raise Constraint_Error with
           "received shared-memory length is not natively representable";
      end if;
      Begin_Operation (Channel, Socket, Trust);
      begin
         Receive_Validated
           (Socket, Expected_Length,
            Require_Immutable_Size or else Trust = Untrusted_Peer,
            Descriptor, Props);
         Adopt_Received (Item, Descriptor, Expected_Length, Props);
         Descriptor := -1;
         Channel.Owner.Controller.Finish;
      exception
         when others =>
            if Descriptor >= 0 and then not Shared_Memory.Is_Open (Item) then
               Ignored := Native.Close (Descriptor);
            end if;
            Poison_And_Close (Channel);
            raise;
      end;
   end Receive;

end Flyology.Shared_Memory.Unix_Sockets;
