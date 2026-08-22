with GNAT.OS_Lib;
with System;

package body Flyology.Sendfile_Bridge is
   package C renames Interfaces.C;

   use type C.int;
   use type C.long;
   use type C.long_long;

   function Darwin_Sendfile
     (File    : C.int;
      Socket  : C.int;
      Offset  : C.long_long;
      Length  : not null access C.long_long;
      Headers : System.Address;
      Flags   : C.int) return C.int;
   pragma Import (C, Darwin_Sendfile, "sendfile");

   function Send_File
     (Socket : C.int; File : C.int; Offset : C.long_long; Length : C.size_t; Error : not null access C.int)
      return C.long
   is
      Sent   : aliased C.long_long := C.long_long (Length);
      Result : C.int;
   begin
      Result := Darwin_Sendfile (File, Socket, Offset, Sent'Access, System.Null_Address, 0);
      if Sent > 0 then
         --  Darwin reports partial progress through len alongside EAGAIN or
         --  EINTR. Progress wins so the caller can advance without replay.
         Error.all := 0;
         return C.long (Sent);
      elsif Result < 0 then
         Error.all := C.int (GNAT.OS_Lib.Errno);
         return -1;
      end if;
      Error.all := 0;
      return 0;
   end Send_File;

end Flyology.Sendfile_Bridge;
