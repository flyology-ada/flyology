package body Flyology.Sendfile_Bridge is

   function Guarded_Send_File
     (Socket : Interfaces.C.int;
      File   : Interfaces.C.int;
      Offset : Interfaces.C.long_long;
      Length : Interfaces.C.size_t;
      Error  : not null access Interfaces.C.int) return Interfaces.C.long;
   pragma Import
     (C, Guarded_Send_File, "flyology_linux_guarded_sendfile");

   function Send_File
     (Socket : Interfaces.C.int;
      File   : Interfaces.C.int;
      Offset : Interfaces.C.long_long;
      Length : Interfaces.C.size_t;
      Error  : not null access Interfaces.C.int) return Interfaces.C.long is
     (Guarded_Send_File (Socket, File, Offset, Length, Error));

end Flyology.Sendfile_Bridge;
