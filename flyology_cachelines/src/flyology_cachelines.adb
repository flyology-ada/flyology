with Flyology_Cachelines.Platform;

package body Flyology_Cachelines is

   function Hardware_Cache_Line_Size return Cache_Query_Result is
     (Flyology_Cachelines.Platform.Hardware_Cache_Line_Size);

   function L1_Data_Cache_Size return Cache_Query_Result is
     (Flyology_Cachelines.Platform.L1_Data_Cache_Size);

   function L1_Data_Cache_Slots return Cache_Query_Result is
      Size : constant Cache_Query_Result := L1_Data_Cache_Size;
   begin
      return
        (if Size.Available
         then
           (Available => True,
            Value     => Size.Value / Destructive_Interference_Size)
         else Unavailable);
   end L1_Data_Cache_Slots;

   function Value_Or
     (Result   : Cache_Query_Result;
      Fallback : Natural) return Natural is
     (if Result.Available then Result.Value else Fallback);

end Flyology_Cachelines;
