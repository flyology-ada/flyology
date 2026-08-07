package body Flyology_Cachelines.Platform is

   function Hardware_Cache_Line_Size return Cache_Query_Result is
     (Unavailable);

   function L1_Data_Cache_Size return Cache_Query_Result is (Unavailable);

end Flyology_Cachelines.Platform;
