package body Flyology.Shared_Memory.Unix_Sockets is
   package C renames Interfaces.C;

   use type Byte_Length;

   function C_Send (Socket, Descriptor : C.int) return C.int;
   pragma Import (C, C_Send, "flyology_shm_send_fd");

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
      if Code = -1 then
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

   procedure Send
     (Socket    : Socket_Descriptor;
      Item      : in out Backing_Object;
      Ownership : Send_Ownership := Borrow)
   is
      Status : C.int;
   begin
      if Socket < 0 then
         raise Validation_Error with "Unix-domain socket is invalid";
      end if;
      Status := C_Send (C.int (Socket), Owned_Descriptor (Item));
      if Status /= 0 then
         Raise_Child_Failure ("SCM_RIGHTS send", Status);
      elsif Ownership = Transfer then
         Close (Item);
      end if;
   end Send;

   procedure Receive
     (Socket                 : Socket_Descriptor;
      Expected_Length        : Byte_Length;
      Item                   : in out Backing_Object;
      Require_Immutable_Size : Boolean := False)
   is
      Descriptor : aliased C.int := -1;
      Props      : aliased C.int := 0;
      Status     : C.int;
      Ignored    : C.int;
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

      Status := C_Receive (C.int (Socket), Descriptor'Access);
      if Status /= 0 then
         Raise_Child_Failure ("SCM_RIGHTS receive", Status);
      end if;
      Status := C_Validate
        (Descriptor, C.unsigned_long_long (Expected_Length),
         Boolean'Pos (Require_Immutable_Size), Props'Access);
      if Status /= 0 then
         Ignored := C_Close (Descriptor);
         Descriptor := -1;
         Raise_Child_Failure ("received descriptor validation", Status);
      end if;
      Adopt_Received (Item, Descriptor, Expected_Length, Decode (Props));
   exception
      when others =>
         if Descriptor >= 0 and then not Is_Open (Item) then
            Ignored := C_Close (Descriptor);
         end if;
         raise;
   end Receive;

end Flyology.Shared_Memory.Unix_Sockets;
