with Interfaces;
with Interfaces.C;
with System;

--  Narrow private byte/scalar bridge. Algorithms validate every address and
--  extent in Ada before calling these representation-neutral copies.

private package Flyology_Allocators.Storage
  with Preelaborate
is
   function Read_U8 (Address : System.Address) return Interfaces.Unsigned_8;
   function Read_U32 (Address : System.Address) return Interfaces.Unsigned_32;
   function Read_U64 (Address : System.Address) return Interfaces.Unsigned_64;
   procedure Write_U32 (Address : System.Address; Value : Interfaces.Unsigned_32);
   procedure Write_U64 (Address : System.Address; Value : Interfaces.Unsigned_64);
   procedure Write_U8 (Address : System.Address; Value : Interfaces.Unsigned_8);
   procedure Copy (Target : System.Address; Source : System.Address; Length : Interfaces.C.size_t);
   function Equal
     (Left : System.Address; Right : System.Address; Length : Interfaces.C.size_t) return Boolean;
   pragma Inline_Always (Read_U8, Read_U32, Read_U64, Write_U8, Write_U32, Write_U64, Copy, Equal);
end Flyology_Allocators.Storage;
