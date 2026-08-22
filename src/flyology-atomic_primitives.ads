with Interfaces;
with System;

--  Shared private process-capable atomic primitives. Callers validate natural
--  alignment and complete extents before supplying an address.

private package Flyology.Atomic_Primitives
  with Preelaborate
is
   function Load_Acquire_U32 (Address : System.Address) return Interfaces.Unsigned_32;
   function Load_Acquire_U64 (Address : System.Address) return Interfaces.Unsigned_64;
   procedure Store_Release_U32 (Address : System.Address; Value : Interfaces.Unsigned_32);
   procedure Store_Release_U64 (Address : System.Address; Value : Interfaces.Unsigned_64);
   function Compare_Exchange_U32
     (Address : System.Address; Expected : in out Interfaces.Unsigned_32; Desired : Interfaces.Unsigned_32)
      return Boolean;
   pragma
     Inline_Always
       (Load_Acquire_U32, Load_Acquire_U64, Store_Release_U32, Store_Release_U64, Compare_Exchange_U32);
end Flyology.Atomic_Primitives;
