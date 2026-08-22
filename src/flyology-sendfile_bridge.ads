with Interfaces.C;

--  Internal platform binding for one positional sendfile attempt.

private package Flyology.Sendfile_Bridge
  with Preelaborate
is

   function Send_File
     (Socket : Interfaces.C.int;
      File   : Interfaces.C.int;
      Offset : Interfaces.C.long_long;
      Length : Interfaces.C.size_t;
      Error  : not null access Interfaces.C.int) return Interfaces.C.long;

end Flyology.Sendfile_Bridge;
