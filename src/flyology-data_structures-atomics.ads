with Interfaces;
with System;

--  Narrow private process-capable atomic bridge. All callers pass naturally
--  aligned addresses inside validated region extents.
private package Flyology.Data_Structures.Atomics with Preelaborate is
   function Supported return Boolean;
   function Load_Acquire_U32
     (Address : System.Address) return Interfaces.Unsigned_32;
   function Load_Acquire_U64
     (Address : System.Address) return Interfaces.Unsigned_64;
   function Load_Relaxed_U64
     (Address : System.Address) return Interfaces.Unsigned_64;
   procedure Store_Release_U32
     (Address : System.Address; Value : Interfaces.Unsigned_32);
   procedure Store_Release_U64
     (Address : System.Address; Value : Interfaces.Unsigned_64);
   function Compare_Exchange_U32
     (Address  : System.Address;
      Expected : in out Interfaces.Unsigned_32;
      Desired  : Interfaces.Unsigned_32) return Boolean;
   function Compare_Exchange_U64
     (Address  : System.Address;
      Expected : in out Interfaces.Unsigned_64;
      Desired  : Interfaces.Unsigned_64) return Boolean;
   pragma Inline_Always
     (Supported, Load_Acquire_U32, Load_Acquire_U64, Load_Relaxed_U64,
      Store_Release_U32, Store_Release_U64, Compare_Exchange_U32,
      Compare_Exchange_U64);
end Flyology.Data_Structures.Atomics;
