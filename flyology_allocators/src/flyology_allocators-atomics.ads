with Interfaces;
with System;

--  Narrow private runtime atomic bridge. All callers pass naturally
--  aligned addresses inside validated region extents.
private package Flyology_Allocators.Atomics with Preelaborate is
   function Supported return Boolean;
   function Load_Acquire_U32
     (Address : System.Address) return Interfaces.Unsigned_32;
   procedure Store_Release_U32
     (Address : System.Address; Value : Interfaces.Unsigned_32);
   function Compare_Exchange_U32
     (Address  : System.Address;
      Expected : in out Interfaces.Unsigned_32;
      Desired  : Interfaces.Unsigned_32) return Boolean;
   pragma Inline_Always
     (Supported, Load_Acquire_U32, Store_Release_U32,
      Compare_Exchange_U32);
end Flyology_Allocators.Atomics;
