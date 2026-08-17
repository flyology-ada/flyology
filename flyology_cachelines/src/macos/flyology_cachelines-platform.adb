with Flyology_Cachelines.Macos;

package body Flyology_Cachelines.Platform is

   --  macOS 12 and later describe a host whose cores are not identical as
   --  ordered performance levels, where hw.perflevel0 is the
   --  highest-performing level.  On Apple silicon the flat hw.l1dcachesize
   --  reports the efficiency-core capacity, which is smaller than the
   --  performance-core capacity, so the highest level is preferred.  A host
   --  that publishes no performance level, including macOS 11 and earlier
   --  and every Intel Mac, has no hw.perflevel0 name and degrades to the flat
   --  name.  Querying hw.nperflevels first would add nothing: the per-level
   --  name exists exactly when the host publishes performance levels.
   function Detect_L1_Data_Cache_Size return Cache_Query_Result is
      Fastest : constant Cache_Query_Result :=
        Flyology_Cachelines.Macos.Query ("hw.perflevel0.l1dcachesize");
   begin
      return
        (if Fastest.Available
         then Fastest
         else Flyology_Cachelines.Macos.Query ("hw.l1dcachesize"));
   end Detect_L1_Data_Cache_Size;

   --  Darwin publishes no per-performance-level line size, and the core types
   --  of a heterogeneous Apple silicon host share one line size.
   Detected_Hardware_Cache_Line_Size : constant Cache_Query_Result :=
     Flyology_Cachelines.Macos.Query ("hw.cachelinesize");
   Detected_L1_Data_Cache_Size : constant Cache_Query_Result :=
     Detect_L1_Data_Cache_Size;

   function Hardware_Cache_Line_Size return Cache_Query_Result is
     (Detected_Hardware_Cache_Line_Size);

   function L1_Data_Cache_Size return Cache_Query_Result is
     (Detected_L1_Data_Cache_Size);

end Flyology_Cachelines.Platform;
