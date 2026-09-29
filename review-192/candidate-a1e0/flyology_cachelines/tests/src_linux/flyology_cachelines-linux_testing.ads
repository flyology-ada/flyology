private package Flyology_Cachelines.Linux_Testing is

   --  Fixture_Root names a directory holding synthetic sysfs CPU
   --  descriptions.  It is empty when the caller supplies none, and the
   --  fixture checks are then skipped.
   procedure Run (Fixture_Root : String);

end Flyology_Cachelines.Linux_Testing;
