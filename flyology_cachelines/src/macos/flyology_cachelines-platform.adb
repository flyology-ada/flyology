with Flyology_Cachelines.Macos;

package body Flyology_Cachelines.Platform is

   --  Name of a per-performance-level sysctl.  Level 0 is the
   --  highest-performing level, so it corresponds to Fastest_Core_Class.
   function Level_Name (Class : Core_Class; Leaf : String) return String is
      Level : constant Natural := Natural (Class) - 1;
      Image : constant String := Natural'Image (Level);
   begin
      return
        "hw.perflevel" & Image (Image'First + 1 .. Image'Last) & "." & Leaf;
   end Level_Name;

   function Detect return Host_Facts is
      Result : Host_Facts;

      Levels : constant Cache_Query_Result :=
        Flyology_Cachelines.Macos.Query ("hw.nperflevels");
      Line   : constant Cache_Query_Result :=
        Flyology_Cachelines.Macos.Query ("hw.cachelinesize");

      --  macOS 11 and earlier and every Intel Mac publish no performance
      --  level.  Such a host has one class, described by the flat names.
      Flat_Size : constant Cache_Query_Result :=
        Flyology_Cachelines.Macos.Query ("hw.l1dcachesize");
      Flat_Cores : constant Cache_Query_Result :=
        Flyology_Cachelines.Macos.Query ("hw.physicalcpu");
      Flat_CPUs : constant Cache_Query_Result :=
        Flyology_Cachelines.Macos.Query ("hw.logicalcpu");
   begin
      Result.Line_Size := Value_Or (Line, 0);

      if Levels.Available and then Levels.Value >= 1 then
         for Class in Core_Class range
           Fastest_Core_Class ..
             Core_Class (Natural'Min (Levels.Value, Max_Core_Classes))
         loop
            declare
               Size : constant Cache_Query_Result :=
                 Flyology_Cachelines.Macos.Query
                   (Level_Name (Class, "l1dcachesize"));
            begin
               exit when not Size.Available;

               declare
                  Cores : constant Natural :=
                    Value_Or
                      (Flyology_Cachelines.Macos.Query
                         (Level_Name (Class, "physicalcpu")), 0);
                  CPUs  : constant Natural :=
                    Value_Or
                      (Flyology_Cachelines.Macos.Query
                         (Level_Name (Class, "logicalcpu")), 0);

                  --  cpusperl2 counts logical CPUs, so it becomes a core
                  --  count through this level's threads-per-core ratio.
                  Per_L2 : constant Natural :=
                    Value_Or
                      (Flyology_Cachelines.Macos.Query
                         (Level_Name (Class, "cpusperl2")), 0);
               begin
                  Result.Count := Natural (Class);
                  Result.Classes (Class) :=
                    (Line_Size        => Result.Line_Size,
                     Total_Size       => Size.Value,
                     Cores            => Cores,
                     CPUs             => CPUs,
                     L2_Size          =>
                       Value_Or
                         (Flyology_Cachelines.Macos.Query
                            (Level_Name (Class, "l2cachesize")), 0),
                     L2_Sharing_Cores =>
                       (if Per_L2 = 0 or else Cores = 0 or else CPUs = 0
                        then 0
                        else Natural'Max (Per_L2 * Cores / CPUs, 1)));
               end;
            end;
         end loop;
      end if;

      --  A host publishing no performance level has one class.  Its flat
      --  hw.l2cachesize is the same value hw.l1dcachesize is: correct on a
      --  host whose cores are alike, which is the only host reaching here.
      if Result.Count = 0 and then Flat_Size.Available then
         Result.Count := 1;
         Result.Classes (Fastest_Core_Class) :=
           (Line_Size        => Result.Line_Size,
            Total_Size       => Flat_Size.Value,
            Cores            => Value_Or (Flat_Cores, 0),
            CPUs             => Value_Or (Flat_CPUs, 0),
            L2_Size          =>
              Value_Or (Flyology_Cachelines.Macos.Query ("hw.l2cachesize"), 0),
            L2_Sharing_Cores => 0);
      end if;

      --  Performance levels are the host's own rank, so any order among two
      --  or more of them is reported rather than inferred.
      Result.Ordering :=
        (if Result.Count >= 2 then Host_Reported else Unordered);

      return Result;
   exception
      when others =>
         return (Count     => 0,
                 Ordering  => Unordered,
                 Line_Size => 0,
                 Classes   => (others => (others => 0)));
   end Detect;

end Flyology_Cachelines.Platform;
