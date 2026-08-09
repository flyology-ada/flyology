with Interfaces;
with Interfaces.C;
with System;

--  Test-only native mapping observations. This unit is built only into the
--  runtime smoke-test archive and is absent from the production library.
package Flyology.Shared_Memory.Testing is
   function Base (Item : Mapping) return System.Address;
   function Base_Value (Item : Mapping) return Interfaces.Unsigned_64;
   function Descriptor (Item : Backing_Object) return Interfaces.C.int;
   procedure Store_Release_U32
     (Item   : Mapping;
      Offset : Byte_Length;
      Value  : Interfaces.Unsigned_32);
   procedure Store_Release_U64
     (Item   : Mapping;
      Offset : Byte_Length;
      Value  : Interfaces.Unsigned_64);
end Flyology.Shared_Memory.Testing;
