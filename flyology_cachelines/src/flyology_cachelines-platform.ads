private package Flyology_Cachelines.Platform is

   --  What the host reports about one core class.  A zero field is a value
   --  the host did not supply.
   type Class_Facts is record
      Line_Size  : Natural := 0;
      Total_Size : Natural := 0;
      Cores      : Natural := 0;
      CPUs       : Natural := 0;
   end record;

   type Class_Facts_Table is array (Core_Class) of Class_Facts;

   --  Everything one host inspection yields.  Count is zero when the host
   --  described no class, and Line_Size is the flat hardware line size, which
   --  no supported platform reports per class.
   type Host_Facts is record
      Count     : Natural        := 0;
      Ordering  : Class_Ordering := Unordered;
      Line_Size : Natural        := 0;
      Classes   : Class_Facts_Table;
   end record;

   --  Inspect the host once.
   --
   --  This is a plain function of what the operating system reports, with no
   --  cached state of its own: the root package body decides when to call it
   --  and holds the result.  It never raises; anything it cannot determine
   --  comes back as zero.
   function Detect return Host_Facts;

end Flyology_Cachelines.Platform;
