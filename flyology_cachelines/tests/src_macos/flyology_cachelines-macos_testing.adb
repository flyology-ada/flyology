with Flyology_Cachelines.Macos;

package body Flyology_Cachelines.Macos_Testing is

   function Query (Name : String) return Cache_Query_Result
     renames Flyology_Cachelines.Macos.Query;

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   procedure Run is
      Line     : constant Cache_Query_Result := Query ("hw.cachelinesize");
      Flat     : constant Cache_Query_Result := Query ("hw.l1dcachesize");
      Levels   : constant Cache_Query_Result := Query ("hw.nperflevels");
      Fastest  : constant Cache_Query_Result :=
        Query ("hw.perflevel0.l1dcachesize");
      Reported : constant Cache_Query_Result := L1_Data_Cache_Size;
   begin
      Check (Line.Available, "hw.cachelinesize query failed");
      Check (Flat.Available, "hw.l1dcachesize query failed");
      Check (Reported.Available, "macOS L1 data-cache detection failed");

      --  The same interface answers 32-bit and 64-bit names, and reports no
      --  value for a name the host does not publish as an integer.
      Check
        (not Query ("hw.flyology_cachelines_absent").Available,
         "an absent sysctl name reported a value");
      Check
        (not Query ("kern.ostype").Available,
         "a string-valued sysctl was accepted as a cache quantity");

      if Levels.Available then
         Check
           (Fastest.Available,
            "a host with performance levels published no perflevel0 L1 size");
         Check
           (Reported.Value = Fastest.Value,
            "L1_Data_Cache_Size is not the highest performance level");

         --  hw.l1dcachesize reports the efficiency-core capacity on a
         --  heterogeneous Apple silicon host, so the highest performance
         --  level can never report less than it.
         Check
           (Reported.Value >= Flat.Value,
            "the highest performance level reports less than hw.l1dcachesize");

         if Levels.Value > 1 then
            Check
              (Query ("hw.perflevel1.l1dcachesize").Available,
               "a host with several performance levels published only one");
         end if;
      else
         Check
           (not Fastest.Available,
            "a host without performance levels published perflevel0 geometry");
         Check
           (Reported.Value = Flat.Value,
            "a host without performance levels did not use hw.l1dcachesize");
      end if;

      Check
        (Reported.Value mod Line.Value = 0,
         "the reported L1 capacity is not a whole number of hardware lines");
   end Run;

end Flyology_Cachelines.Macos_Testing;
