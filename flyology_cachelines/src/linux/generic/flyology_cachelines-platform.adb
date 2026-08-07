with Flyology_Cachelines.Linux;

package body Flyology_Cachelines.Platform is

   function Detect return Flyology_Cachelines.Linux.Cache_Parameters is
      Result : constant Flyology_Cachelines.Linux.Cache_Parameters :=
        Flyology_Cachelines.Linux.Detect_From_Sysconf;
   begin
      return
        (if Result.Available
         then Result
         else Flyology_Cachelines.Linux.Detect_From_Sysfs);
   exception
      when others =>
         return Flyology_Cachelines.Linux.No_Cache_Parameters;
   end Detect;

   Detected_Cache : constant Flyology_Cachelines.Linux.Cache_Parameters := Detect;

   function Hardware_Cache_Line_Size return Cache_Query_Result is
     (if Detected_Cache.Available
      then (Available => True, Value => Detected_Cache.Line_Size)
      else Unavailable);

   function L1_Data_Cache_Size return Cache_Query_Result is
     (if Detected_Cache.Available
      then (Available => True, Value => Detected_Cache.Total_Size)
      else Unavailable);

end Flyology_Cachelines.Platform;
