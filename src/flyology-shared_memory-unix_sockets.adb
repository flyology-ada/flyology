package body Flyology.Shared_Memory.Unix_Sockets is
   use type Byte_Length;

   function C_Send (Socket, Descriptor : C.int) return C.int;
   pragma Import (C, C_Send, "flyology_shm_send_fd");

   function C_Prepare (Socket : C.int) return C.int;
   pragma Import
     (C, C_Prepare, "flyology_shm_prepare_handoff_socket");

   function C_Untrusted_Supported return C.int;
   pragma Import
     (C, C_Untrusted_Supported,
      "flyology_shm_untrusted_handoff_supported");

   function C_Receive
     (Socket : C.int; Descriptor : access C.int) return C.int;
   pragma Import (C, C_Receive, "flyology_shm_receive_fd");

   function C_Validate
     (Descriptor        : C.int;
      Expected_Length   : C.unsigned_long_long;
      Require_Immutable : C.int;
      Properties        : access C.int) return C.int;
   pragma Import (C, C_Validate, "flyology_shm_validate_received");

   function C_Close (Descriptor : C.int) return C.int;
   pragma Import (C, C_Close, "flyology_shm_close");

   function Decode (Value : C.int) return Security_Properties is
      function Has (Power : Natural) return Boolean is
        ((Value / (2 ** Power)) mod 2 = 1);
   begin
      return
        (Close_On_Exec             => Has (0),
         Size_Immutable            => Has (1),
         No_Execute_Seal           => Has (2),
         No_Execute_Seal_Supported => Has (3),
         No_Symlink_Follow         => Has (4),
         Owner_Only_Permissions    => Has (5));
   end Decode;

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
         Ignored := C_Close (Descriptor);
      end if;
   end Poison_And_Close;

   procedure Receive_Validated
     (Socket                 : C.int;
      Expected_Length        : Byte_Length;
      Require_Immutable_Size : Boolean;
      Descriptor             : out C.int;
      Props                  : out C.int)
   is
      Local_Descriptor : aliased C.int := -1;
      Local_Props      : aliased C.int := 0;
      Status           : C.int;
      Ignored          : C.int;
   begin
      Status := C_Receive (Socket, Local_Descriptor'Access);
      if Status /= 0 then
         Raise_Child_Failure ("SCM_RIGHTS receive", Status);
      end if;
      Status := C_Validate
        (Local_Descriptor, C.unsigned_long_long (Expected_Length),
         Boolean'Pos (Require_Immutable_Size), Local_Props'Access);
      if Status /= 0 then
         Ignored := C_Close (Local_Descriptor);
         Local_Descriptor := -1;
         Raise_Child_Failure ("received descriptor validation", Status);
      end if;
      Descriptor := Local_Descriptor;
      Props := Local_Props;
   exception
      when others =>
         if Local_Descriptor >= 0 then
            Ignored := C_Close (Local_Descriptor);
         end if;
         raise;
   end Receive_Validated;

   procedure Adopt
     (Item   : in out Handoff_Channel;
      Socket : in out Socket_Descriptor;
      Trust  : Peer_Trust := Trusted_Peer)
   is
      Status   : C.int;
      Accepted : Boolean;
   begin
      if Socket < 0 then
         raise Validation_Error with "Unix-domain socket is invalid";
      elsif Is_Open (Item) then
         raise Validation_Error with "handoff channel is already open";
      elsif Is_Poisoned (Item) then
         raise Protocol_Error with "handoff channel is poisoned";
      elsif Trust = Untrusted_Peer and then C_Untrusted_Supported = 0 then
         raise Security_Error with
           "untrusted SCM_RIGHTS receipt is unavailable on this host";
      end if;
      Status := C_Prepare (C.int (Socket));
      if Status /= 0 then
         Raise_Child_Failure ("handoff channel adoption", Status);
      end if;
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
         Status := C_Close (Descriptor);
         if Status /= 0 then
            Raise_Child_Failure ("handoff channel close", Status);
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
         Ignored := C_Close (Descriptor);
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
      Status : C.int;
   begin
      if Socket < 0 then
         raise Validation_Error with "Unix-domain socket is invalid";
      elsif not Shared_Memory.Is_Open (Item) then
         raise Validation_Error with "backing object is closed";
      end if;
      Status := C_Send (C.int (Socket), Owned_Descriptor (Item));
      if Status /= 0 then
         Raise_Child_Failure ("SCM_RIGHTS send", Status);
      elsif Ownership = Transfer then
         Close (Item);
      end if;
   end Send;

   procedure Send
     (Channel   : in out Handoff_Channel;
      Item      : in out Backing_Object;
      Ownership : Send_Ownership := Borrow)
   is
      Socket : C.int;
      Trust  : Peer_Trust;
      Status : C.int;
   begin
      if not Shared_Memory.Is_Open (Item) then
         raise Validation_Error with "backing object is closed";
      end if;
      Begin_Operation (Channel, Socket, Trust);
      Status := C_Send (Socket, Owned_Descriptor (Item));
      if Status /= 0 then
         Poison_And_Close (Channel);
         Raise_Child_Failure ("SCM_RIGHTS channel send", Status);
      end if;
      Channel.Owner.Controller.Finish;
      if Ownership = Transfer then
         Shared_Memory.Close (Item);
      end if;
   exception
      when others =>
         if Channel.Owner.Controller.Open then
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
      Props      : C.int := 0;
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
      Adopt_Received (Item, Descriptor, Expected_Length, Decode (Props));
      Descriptor := -1;
   exception
      when others =>
         if Descriptor >= 0 and then not Shared_Memory.Is_Open (Item) then
            declare
               Ignored : constant C.int := C_Close (Descriptor);
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
      Props      : C.int := 0;
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
         Adopt_Received (Item, Descriptor, Expected_Length, Decode (Props));
         Descriptor := -1;
         Channel.Owner.Controller.Finish;
      exception
         when others =>
            if Descriptor >= 0 and then not Shared_Memory.Is_Open (Item) then
               Ignored := C_Close (Descriptor);
            end if;
            Poison_And_Close (Channel);
            raise;
      end;
   end Receive;

end Flyology.Shared_Memory.Unix_Sockets;
