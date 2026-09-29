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
   procedure Check_Consistent (Name : String; Result : Flyology_Cachelines.Linux.Cache_Parameters) is
   begin
      if Result.Available then
         Check
           (Result.Total_Size mod Result.Line_Size = 0, Name & " cache size is not a whole number of lines");
      end if;
   end Check_Consistent;

   procedure Check_Core_Classes (Sysfs : Flyology_Cachelines.Linux.Cache_Parameters) is
      Classes : constant Flyology_Cachelines.Linux.Core_Classes :=
        Flyology_Cachelines.Linux.Detect_Core_Classes;
      Matched : Boolean := False;
   begin
      --  Classes are derived from the same sysfs descriptions, so a host that
      --  describes CPU 0 must yield at least the class holding CPU 0.
      if not Sysfs.Available then
         return;
      end if;

      Check (Classes.Count > 0, "core-class detection found no CPU");

      for Index in 1 .. Classes.Count loop
         declare
            Class : constant Flyology_Cachelines.Linux.Core_Class_Parameters :=
              Classes.Classes (Core_Class (Index));
         begin
            Check (Class.Available, "a counted core class has no geometry");
            Check
              (Class.Total_Size mod Class.Line_Size = 0, "a core class size is not a whole number of lines");
            Check (Class.Cores <= Class.CPUs, "a core class reports more cores than CPUs");

            --  Whichever key ordered the classes must be non-increasing.
            if Index > 1 then
               declare
                  Previous : constant Flyology_Cachelines.Linux.Core_Class_Parameters :=
                    Classes.Classes (Core_Class (Index - 1));
               begin
                  case Classes.Ordering is
                     when Host_Reported =>
                        Check
                          (Class.Capacity <= Previous.Capacity,
                           "classes are not ordered by descending capacity");

                     when Inferred      =>
                        Check
                          (Class.Total_Size <= Previous.Total_Size,
                           "classes are not ordered by descending L1 size");

                     when Unordered     =>
                        null;
                  end case;
               end;
            end if;

            if Class.Total_Size = Sysfs.Total_Size and then Class.Line_Size = Sysfs.Line_Size then
               Matched := True;
            end if;
         end;
      end loop;

      Check (Matched, "no core class matches the geometry reported for CPU 0");
   end Check_Core_Classes;

   --  Synthetic topologies exercise grouping, ordering, and the SMT
   --  distinction, none of which a uniform test host can reach.
   procedure Check_Fixtures (Fixture_Root : String) is

      function Classes (Name : String) return Flyology_Cachelines.Linux.Core_Classes
      is (Flyology_Cachelines.Linux.Detect_Core_Classes (Fixture_Root & Name & "/"));

      Hybrid   : constant Flyology_Cachelines.Linux.Core_Classes := Classes ("hybrid");
      Capacity : constant Flyology_Cachelines.Linux.Core_Classes := Classes ("capacity");
      SMT      : constant Flyology_Cachelines.Linux.Core_Classes := Classes ("smt");
      Sparse   : constant Flyology_Cachelines.Linux.Core_Classes := Classes ("sparse");
   begin
      --  No capacity published, so ordering falls to the geometry inference.
      Check (Hybrid.Count = 2, "hybrid fixture did not yield two classes");
      Check (Hybrid.Ordering = Inferred, "hybrid fixture did not report an inferred ordering");
      Check
        (Hybrid.Classes (1).Total_Size = 64 * 1_024 and then Hybrid.Classes (1).Cores = 2,
         "hybrid fixture did not order the larger class first");
      Check (Hybrid.Classes (2).Total_Size = 32 * 1_024, "hybrid fixture did not group the smaller class");

      --  Both classes share one geometry, so only capacity separates them.
      --  Grouping on geometry alone would report a single class of four.
      Check (Capacity.Count = 2, "capacity fixture merged two classes sharing one geometry");
      Check (Capacity.Ordering = Host_Reported, "capacity fixture did not report a host-reported ordering");
      Check
        (Capacity.Classes (1).Capacity = 1_024 and then Capacity.Classes (2).Capacity = 512,
         "capacity fixture did not order by descending capacity");

      --  Each hybrid class shares one L2 across its two cores.
      Check
        (Hybrid.Classes (1).L2_Size = 2 * 1_024 * 1_024 and then Hybrid.Classes (1).L2_CPUs = 2,
         "hybrid fixture did not read the larger class L2");
      Check (Hybrid.Classes (2).L2_Size = 512 * 1_024, "hybrid fixture did not read the smaller class L2");

      --  Four CPUs pairwise sharing one L1 data cache are two cores.
      Check (SMT.Count = 1, "SMT fixture did not yield one class");
      Check
        (SMT.Classes (1).CPUs = 4 and then SMT.Classes (1).Cores = 2,
         "SMT fixture counted sibling CPUs as separate cores");
      Check (SMT.Ordering = Unordered, "a single class did not report an unordered result");

      --  All four CPUs share one L2, which is two cores rather than four.
      Check (SMT.Classes (1).L2_CPUs = 4, "SMT fixture did not count the CPUs sharing one L2");

      --  A private L2 per core must not be reported as shared.
      Check (Sparse.Classes (1).L2_CPUs = 1, "sparse fixture treated a private L2 as shared");

      --  present is "0-1,4-5", so enumeration must reach CPU 5 and skip the
      --  absent CPUs 2 and 3 without counting them.
      Check (Sparse.Count = 1, "sparse fixture did not yield one class");
      Check (Sparse.Classes (1).Cores = 4, "sparse fixture did not enumerate across a gap in the CPU list");
      Check (Sparse.Classes (1).Total_Size = 48 * 1_024, "sparse fixture reported the wrong capacity");
   end Check_Fixtures;

   procedure Run (Fixture_Root : String) is
      Sysconf : constant Flyology_Cachelines.Linux.Cache_Parameters :=
        Flyology_Cachelines.Linux.Detect_From_Sysconf;
      Sysfs   : constant Flyology_Cachelines.Linux.Cache_Parameters :=
        Flyology_Cachelines.Linux.Detect_From_Sysfs;
   begin
      Check
        (Sysconf.Available or else Sysfs.Available, "no Linux cache detection mechanism reported a value");
      Check_Consistent ("sysconf", Sysconf);
      Check_Consistent ("sysfs", Sysfs);
      Check_Core_Classes (Sysfs);

      if Fixture_Root /= "" then
         Check_Fixtures (Fixture_Root);
      end if;
   end Run;

end Flyology_Cachelines.Linux_Testing;
