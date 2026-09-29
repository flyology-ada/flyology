with Interfaces;
with Interfaces.C;
with System;

--  Raw C-buffer access for the OpenSSL ALPN callback. Cursor and selection
--  decisions are delegated to the SPARK policy package.

private package Flyology.TLS_OpenSSL_Raw
  with Preelaborate
is
   function Valid_ALPN_List
     (Protocols : System.Address; Length : Interfaces.C.unsigned) return Interfaces.C.int
   with Export, Convention => C, External_Name => "flyology_tls_openssl_ada_valid_alpn_list";

   --  Return zero for no selection. Otherwise the low eight bits contain the
   --  selected length and the remaining bits contain its offered-list offset.
   function Select_ALPN
     (Server         : System.Address;
      Server_Length  : Interfaces.C.unsigned;
      Offered        : System.Address;
      Offered_Length : Interfaces.C.unsigned) return Interfaces.Unsigned_64
   with Export, Convention => C, External_Name => "flyology_tls_openssl_ada_select_alpn";
end Flyology.TLS_OpenSSL_Raw;
