package body Flyology_Cachelines.Linux.Facts is

   function Detected
     (Fallback : Cache_Parameters := No_Cache_Parameters) return Flyology_Cachelines.Platform.Host_Facts
   is
      Classes : constant Core_Classes := Detect_Core_Classes;
      Result  : Flyology_Cachelines.Platform.Host_Facts;
   begin
      if Classes.Count = 0 then
         --  sysfs described no CPU.  Report whatever single class the caller
         --  could still determine, without a core count it cannot support.
         if Fallback.Available then
            Result.Count := 1;
            Result.Line_Size := Fallback.Line_Size;
            Result.Classes (Fastest_Core_Class) :=
              (Line_Size        => Fallback.Line_Size,
               Total_Size       => Fallback.Total_Size,
               Cores            => 0,
               CPUs             => 0,
               L2_Size          => 0,
               L2_Sharing_Cores => 0);
         end if;

         return Result;
      end if;

      Result.Count := Classes.Count;
      Result.Ordering := Classes.Ordering;

      --  Linux reports a line size per class.  The public query is flat, and
      --  the highest-ranked class is the one every unqualified query
      --  describes, so its line size is the one reported.
      Result.Line_Size := Classes.Classes (Fastest_Core_Class).Line_Size;

      for Index in 1 .. Classes.Count loop
         declare
            Class : Core_Class_Parameters renames Classes.Classes (Core_Class (Index));
         begin
            Result.Classes (Core_Class (Index)) :=
              (Line_Size        => Class.Line_Size,
               Total_Size       => Class.Total_Size,
               Cores            => Class.Cores,
               CPUs             => Class.CPUs,
               L2_Size          => Class.L2_Size,
               --  sysfs counts logical CPUs sharing the cache.  This class's
               --  own threads-per-core ratio turns that into a core count.
               L2_Sharing_Cores =>
                 (if Class.L2_CPUs = 0
                  then 0
                  else Natural'Max (Class.L2_CPUs * Class.Cores / Class.CPUs, 1)));
         end;
      end loop;

      return Result;
   exception
      when others =>
         return (Count => 0, Ordering => Unordered, Line_Size => 0, Classes => (others => (others => 0)));
   end Detected;

end Flyology_Cachelines.Linux.Facts;
