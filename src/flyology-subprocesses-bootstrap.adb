with Ada.Exceptions;
with Flyology.Descriptor_Handoffs;
with Interfaces.C;

package body Flyology.Subprocesses.Bootstrap is
   package C renames Interfaces.C;
   package Descriptor_Handoffs renames Flyology.Descriptor_Handoffs;

   use type Ada.Exceptions.Exception_Id;
   use type Socket_Handoffs.Peer_Trust;

   type Descriptor_Pair is array (Natural range 0 .. 1) of aliased C.int with Convention => C;

   function C_Duplicate_Above (Descriptor : C.int; Minimum : C.int) return C.int;
   pragma Import (C, C_Duplicate_Above, "flyology_subprocess_duplicate_above");

   function C_Close (Descriptor : C.int) return C.int;
   pragma Import (C, C_Close, "close");

   procedure Close_Raw (Descriptor : in out C.int) is
      Ignored : C.int;
   begin
      if Descriptor >= 0 then
         Ignored := C_Close (Descriptor);
         Descriptor := -1;
      end if;
   end Close_Raw;

   procedure Close_Pair (Pair : in out Descriptor_Pair) is
   begin
      for Descriptor of Pair loop
         Close_Raw (Descriptor);
      end loop;
   end Close_Pair;

   procedure Release_Above_Bootstrap (Socket : in out Sockets.Socket_Type; Descriptor : out C.int) is
      Raw         : Flyology.IO.Descriptor;
      Replacement : C.int;
   begin
      Sockets.Release (Socket, Raw);
      Descriptor := C.int (Raw);
      if Descriptor <= C.int (Child_Capability_Descriptor) then
         Replacement := C_Duplicate_Above (Descriptor, C.int (Child_Capability_Descriptor) + 1);
         if Replacement < 0 then
            raise Spawn_Error with "cannot relocate subprocess bootstrap descriptor";
         end if;
         Close_Raw (Descriptor);
         Descriptor := Replacement;
      end if;
   end Release_Above_Bootstrap;

   procedure Validate_Control (Descriptor : C.int; Trust : Socket_Handoffs.Peer_Trust) is
   begin
      Descriptor_Handoffs.Validate_Carrier
        (Descriptor_Handoffs.Socket_Descriptor (Descriptor),
         (if Trust = Socket_Handoffs.Trusted_Peer
          then Descriptor_Handoffs.Trusted_Peer
          else Descriptor_Handoffs.Untrusted_Peer));
   end Validate_Control;

   procedure Spawn
     (Item         : Command;
      Child        : in out Process;
      Control      : in out Sockets.Socket_Type;
      Capabilities : in out Socket_Handoffs.Handoff_Channel)
   is
      Control_Pair             : aliased Descriptor_Pair := (others => -1);
      Capability_Pair          : aliased Descriptor_Pair := (others => -1);
      Control_Parent_Socket    : Sockets.Socket_Type;
      Control_Child_Socket     : Sockets.Socket_Type;
      Capability_Parent_Socket : Sockets.Socket_Type;
      Capability_Child_Socket  : Sockets.Socket_Type;
      Control_Raw              : Flyology.IO.Descriptor;
      Capability_Raw           : Flyology.IO.Descriptor;
      Capability_Socket        : Sockets.Socket_Type;

      procedure Cleanup_Result is
      begin
         if Socket_Handoffs.Is_Open (Capabilities) then
            begin
               Socket_Handoffs.Close (Capabilities);
            exception
               when others =>
                  null;
            end;
         end if;
         if Sockets.Is_Open (Control) then
            begin
               Sockets.Close_Socket (Control);
            exception
               when others =>
                  null;
            end;
         end if;
         if Is_Open (Child) then
            begin
               Close (Child);
            exception
               when others =>
                  null;
            end;
         end if;
      end Cleanup_Result;
   begin
      if Is_Open (Child) or else Sockets.Is_Open (Control) or else Socket_Handoffs.Is_Open (Capabilities) then
         raise Program_Error with "bootstrap spawn target is already open";
      end if;
      begin
         Sockets.Create_Socket_Pair (Control_Parent_Socket, Control_Child_Socket);
         Sockets.Create_Socket_Pair (Capability_Parent_Socket, Capability_Child_Socket);
         Release_Above_Bootstrap (Control_Parent_Socket, Control_Pair (0));
         Release_Above_Bootstrap (Control_Child_Socket, Control_Pair (1));
         Release_Above_Bootstrap (Capability_Parent_Socket, Capability_Pair (0));
         Release_Above_Bootstrap (Capability_Child_Socket, Capability_Pair (1));
      exception
         when Error : others =>
            Close_Pair (Control_Pair);
            Close_Pair (Capability_Pair);
            if Ada.Exceptions.Exception_Identity (Error) = Storage_Error'Identity then
               Ada.Exceptions.Reraise_Occurrence (Error);
            end if;
            raise Spawn_Error
              with "cannot create subprocess bootstrap channels: " & Ada.Exceptions.Exception_Message (Error);
      end;
      if Control_Pair (0) <= C.int (Child_Capability_Descriptor)
        or else Control_Pair (1) <= C.int (Child_Capability_Descriptor)
        or else Capability_Pair (0) <= C.int (Child_Capability_Descriptor)
        or else Capability_Pair (1) <= C.int (Child_Capability_Descriptor)
      then
         Close_Pair (Control_Pair);
         Close_Pair (Capability_Pair);
         raise Spawn_Error with "subprocess bootstrap descriptor relocation was incomplete";
      end if;

      begin
         Spawn_Internal
           (Item,
            Child,
            Control_Pair (0),
            Control_Pair (1),
            Capability_Pair (0),
            Capability_Pair (1),
            Pipe_Output => False,
            Pipe_Error  => False);
         Close_Standard_Input (Child);
         Close_Raw (Control_Pair (1));
         Close_Raw (Capability_Pair (1));

         Validate_Control (Control_Pair (0), Socket_Handoffs.Trusted_Peer);
         Control_Raw := Flyology.IO.Descriptor (Control_Pair (0));
         Control_Pair (0) := -1;
         Sockets.Adopt (Control_Raw, Control);

         Capability_Raw := Flyology.IO.Descriptor (Capability_Pair (0));
         Capability_Pair (0) := -1;
         Sockets.Adopt (Capability_Raw, Capability_Socket);
         Socket_Handoffs.Adopt (Capabilities, Capability_Socket, Socket_Handoffs.Trusted_Peer);
      exception
         when Error : others =>
            Close_Pair (Control_Pair);
            Close_Pair (Capability_Pair);
            Cleanup_Result;
            if Ada.Exceptions.Exception_Identity (Error) = Spawn_Error'Identity
              or else Ada.Exceptions.Exception_Identity (Error) = Storage_Error'Identity
              or else Ada.Exceptions.Exception_Identity (Error) = Program_Error'Identity
            then
               Ada.Exceptions.Reraise_Occurrence (Error);
            else
               raise Bootstrap_Error with Ada.Exceptions.Exception_Message (Error);
            end if;
      end;
   end Spawn;

   procedure Adopt_Inherited
     (Control      : in out Sockets.Socket_Type;
      Capabilities : in out Socket_Handoffs.Handoff_Channel;
      Trust        : Socket_Handoffs.Peer_Trust := Socket_Handoffs.Trusted_Peer)
   is
      Control_Raw       : Flyology.IO.Descriptor := Child_Control_Descriptor;
      Capability_Raw    : Flyology.IO.Descriptor := Child_Capability_Descriptor;
      Capability_Socket : Sockets.Socket_Type;
   begin
      if Sockets.Is_Open (Control) or else Socket_Handoffs.Is_Open (Capabilities) then
         raise Program_Error with "bootstrap adoption target is already open";
      end if;
      begin
         Validate_Control (C.int (Control_Raw), Trust);
         Sockets.Adopt (Control_Raw, Control);
         Sockets.Adopt (Capability_Raw, Capability_Socket);
         Socket_Handoffs.Adopt (Capabilities, Capability_Socket, Trust);
      exception
         when Error : others =>
            if Control_Raw >= 0 then
               declare
                  Raw : C.int := C.int (Control_Raw);
               begin
                  Close_Raw (Raw);
                  Control_Raw := Flyology.IO.Invalid_Descriptor;
               end;
            elsif Sockets.Is_Open (Control) then
               begin
                  Sockets.Close_Socket (Control);
               exception
                  when others =>
                     null;
               end;
            end if;
            if Capability_Raw >= 0 then
               declare
                  Raw : C.int := C.int (Capability_Raw);
               begin
                  Close_Raw (Raw);
                  Capability_Raw := Flyology.IO.Invalid_Descriptor;
               end;
            end if;
            if Socket_Handoffs.Is_Open (Capabilities) then
               begin
                  Socket_Handoffs.Close (Capabilities);
               exception
                  when others =>
                     null;
               end;
            end if;
            raise Bootstrap_Error with Ada.Exceptions.Exception_Message (Error);
      end;
   end Adopt_Inherited;
end Flyology.Subprocesses.Bootstrap;
