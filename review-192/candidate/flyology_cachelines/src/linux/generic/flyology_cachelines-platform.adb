with Flyology_Cachelines.Linux;
with Flyology_Cachelines.Linux.Facts;

package body Flyology_Cachelines.Platform is

   function Detect return Host_Facts is
      --  sysconf answers for the calling CPU only, so it cannot describe a
      --  class.  It stands in when sysfs describes nothing at all.
      Fallback : constant Flyology_Cachelines.Linux.Cache_Parameters :=
        Flyology_Cachelines.Linux.Detect_From_Sysconf;
   begin
      return Flyology_Cachelines.Linux.Facts.Detected (Fallback);
   exception
      when others =>
         return (Count => 0, Ordering => Unordered, Line_Size => 0, Classes => (others => (others => 0)));
   end Detect;

end Flyology_Cachelines.Platform;
