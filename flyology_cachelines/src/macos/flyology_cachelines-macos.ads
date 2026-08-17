private package Flyology_Cachelines.Macos is

   --  Read one unsigned integer value from the Darwin sysctl namespace.
   --
   --  Darwin publishes hardware values as either 32-bit or 64-bit unsigned
   --  integers, and the width is not part of a name's stable contract:
   --  hw.l1dcachesize is 64 bits while hw.perflevel0.l1dcachesize is 32.
   --  The width is therefore requested before the value is read, so no
   --  result depends on byte order.  An absent name, a failed call, a
   --  non-integer value, and a value outside Natural all report no host
   --  value rather than raising.
   function Query (Name : String) return Cache_Query_Result;

end Flyology_Cachelines.Macos;
