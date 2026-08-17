with Flyology_Cachelines.Linux;

package body Flyology_Cachelines.Linux_Testing is

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   --  A detector that reports a value must report a consistent one.  Neither
   --  detector is required on its own: glibc answers _SC_LEVEL1_DCACHE_* from
   --  CPUID on x86-64 but reports zero on aarch64, where sysfs is the only
   --  mechanism.  The production detector composes the two, so the test
   --  requires the composition rather than either part.
   procedure Check_Consistent
     (Name   : String;
      Result : Flyology_Cachelines.Linux.Cache_Parameters) is
   begin
      if Result.Available then
         Check
           (Result.Total_Size mod Result.Line_Size = 0,
            Name & " cache size is not a whole number of lines");
      end if;
   end Check_Consistent;

   procedure Run is
      Sysconf : constant Flyology_Cachelines.Linux.Cache_Parameters :=
        Flyology_Cachelines.Linux.Detect_From_Sysconf;
      Sysfs   : constant Flyology_Cachelines.Linux.Cache_Parameters :=
        Flyology_Cachelines.Linux.Detect_From_Sysfs;
   begin
      Check
        (Sysconf.Available or else Sysfs.Available,
         "no Linux cache detection mechanism reported a value");
      Check_Consistent ("sysconf", Sysconf);
      Check_Consistent ("sysfs", Sysfs);
   end Run;

end Flyology_Cachelines.Linux_Testing;
