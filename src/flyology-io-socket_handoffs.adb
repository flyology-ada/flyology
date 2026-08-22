with Ada.Exceptions;
with Flyology.Shared_Memory_Native;
with GNAT.OS_Lib;
with Interfaces.C;

package body Flyology.IO.Socket_Handoffs is
   package Native renames Flyology.Shared_Memory_Native;
   package Sockets renames Flyology.IO.Sockets;
   package C renames Interfaces.C;

   use type C.int;
   use type Ada.Exceptions.Exception_Id;
   use type Descriptor_Handoffs.Socket_Descriptor;

   procedure Raise_Translated
     (Occurrence : Ada.Exceptions.Exception_Occurrence)
   is
      Message : constant String :=
        Ada.Exceptions.Exception_Message (Occurrence);
   begin
      if Ada.Exceptions.Exception_Identity (Occurrence) =
        Descriptor_Handoffs.Protocol_Error'Identity
      then
         raise Protocol_Error with Message;
      elsif Ada.Exceptions.Exception_Identity (Occurrence) =
        Descriptor_Handoffs.Channel_Busy'Identity
      then
         raise Channel_Busy with Message;
      elsif Ada.Exceptions.Exception_Identity (Occurrence) =
        Descriptor_Handoffs.Validation_Error'Identity
      then
         raise Validation_Error with Message;
      elsif Ada.Exceptions.Exception_Identity (Occurrence) =
        Descriptor_Handoffs.Security_Error'Identity
      then
         raise Security_Error with Message;
      else
         raise Operating_System_Error with Message;
      end if;
   end Raise_Translated;

   procedure Close_Raw (Descriptor : in out C.int) is
      Ignored : C.int;
   begin
      if Descriptor >= 0 then
         Ignored := Native.Close (Descriptor);
         Descriptor := -1;
      end if;
   end Close_Raw;

   procedure Validate_Listener (Descriptor : C.int) is
      Kind      : C.int;
      Accepting : C.int;
   begin
      if Native.Socket_Type (Descriptor, Kind) /= 0 then
         raise Validation_Error with "capability is not a socket";
      elsif Kind /= Native.Stream_Socket_Type then
         raise Validation_Error with "socket is not a stream";
      elsif Native.Socket_Accepting (Descriptor, Accepting) /= 0 then
         raise Operating_System_Error with
           "listener state inspection failed (errno" &
           C.int'Image (C.int (GNAT.OS_Lib.Errno)) & ")";
      elsif Accepting = 0 then
         raise Validation_Error with "socket is not listening";
      end if;
   end Validate_Listener;

   procedure Adopt
     (Item   : in out Handoff_Channel;
      Socket : in out Sockets.Socket_Type;
      Trust  : Peer_Trust := Trusted_Peer)
   is
      Raw     : Flyology.IO.Descriptor;
      Carrier : Descriptor_Handoffs.Socket_Descriptor;
   begin
      if not Sockets.Is_Open (Socket) then
         raise Validation_Error with "handoff carrier is closed";
      end if;
      Sockets.Release (Socket, Raw);
      Carrier := Descriptor_Handoffs.Socket_Descriptor (Raw);
      Raw := Flyology.IO.Invalid_Descriptor;
      begin
         Descriptor_Handoffs.Adopt
           (Item.Owner.Value,
            Carrier,
            (if Trust = Trusted_Peer then
                Descriptor_Handoffs.Trusted_Peer
             else Descriptor_Handoffs.Untrusted_Peer));
      exception
         when Error : others =>
            if Carrier >= 0 then
               Raw := Flyology.IO.Descriptor (Carrier);
               Carrier := -1;
               Sockets.Adopt (Raw, Socket);
            end if;
            Raise_Translated (Error);
      end;
   end Adopt;

   procedure Close (Item : in out Handoff_Channel) is
   begin
      Descriptor_Handoffs.Close (Item.Owner.Value);
   exception
      when Error : others => Raise_Translated (Error);
   end Close;

   function Is_Open (Item : Handoff_Channel) return Boolean is
     (Descriptor_Handoffs.Is_Open (Item.Owner.Value));

   function Is_Poisoned (Item : Handoff_Channel) return Boolean is
     (Descriptor_Handoffs.Is_Poisoned (Item.Owner.Value));

   procedure Send_Listener
     (Channel   : in out Handoff_Channel;
      Item      : in out Sockets.Socket_Type;
      Ownership : Send_Ownership := Borrow)
   is
      Descriptor : Flyology.IO.Descriptor;
   begin
      if not Sockets.Is_Open (Item) then
         raise Validation_Error with "listener is closed";
      end if;
      Descriptor := Sockets.Native_Descriptor (Item);
      Validate_Listener (C.int (Descriptor));
      begin
         Descriptor_Handoffs.Send
           (Channel.Owner.Value, C.int (Descriptor));
      exception
         when Error : others => Raise_Translated (Error);
      end;
      if Ownership = Transfer then
         begin
            Sockets.Close_Socket (Item);
         exception
            when Error : others =>
               raise Operating_System_Error with
                 Ada.Exceptions.Exception_Message (Error);
         end;
      end if;
   end Send_Listener;

   procedure Receive_Listener
     (Channel : in out Handoff_Channel;
      Item    : in out Sockets.Socket_Type)
   is
      Raw       : C.int := -1;
      Descriptor : Flyology.IO.Descriptor;
   begin
      if Sockets.Is_Open (Item) then
         raise Validation_Error with "listener target is already open";
      end if;
      begin
         Descriptor_Handoffs.Receive (Channel.Owner.Value, Raw);
      exception
         when Error : others => Raise_Translated (Error);
      end;
      Validate_Listener (Raw);

      Descriptor := Flyology.IO.Descriptor (Raw);
      Raw := -1;
      Sockets.Adopt (Descriptor, Item);
      begin
         Sockets.Prepare (Item);
      exception
         when others =>
            Sockets.Close_Socket (Item);
            raise;
      end;
   exception
      when Error : others =>
         Close_Raw (Raw);
         if Sockets.Is_Open (Item) then
            begin
               Sockets.Close_Socket (Item);
            exception
               when others => null;
            end;
         end if;
         if Descriptor_Handoffs.Is_Open (Channel.Owner.Value) then
            begin
               Descriptor_Handoffs.Poison (Channel.Owner.Value);
            exception
               when others => null;
            end;
         end if;
         if Ada.Exceptions.Exception_Identity (Error) =
              Validation_Error'Identity
           or else Ada.Exceptions.Exception_Identity (Error) =
              Operating_System_Error'Identity
           or else Ada.Exceptions.Exception_Identity (Error) =
              Protocol_Error'Identity
           or else Ada.Exceptions.Exception_Identity (Error) =
              Channel_Busy'Identity
           or else Ada.Exceptions.Exception_Identity (Error) =
              Security_Error'Identity
         then
            Ada.Exceptions.Reraise_Occurrence (Error);
         else
            raise Operating_System_Error with
              Ada.Exceptions.Exception_Message (Error);
         end if;
   end Receive_Listener;

end Flyology.IO.Socket_Handoffs;
