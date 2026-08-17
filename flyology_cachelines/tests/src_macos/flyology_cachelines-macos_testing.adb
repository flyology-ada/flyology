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

      --  The public class axis must mirror the performance levels exactly.
      declare
         Count : constant Cache_Query_Result := Core_Class_Count;
      begin
         Check (Count.Available, "macOS reported no core class");

         if Levels.Available then
            Check
              (Count.Value =
                 Natural'Min (Levels.Value, Max_Core_Classes),
               "the class count does not match hw.nperflevels");
            Check
              (Core_Class_Ordering =
                 (if Count.Value >= 2 then Host_Reported else Unordered),
               "performance levels were not reported as a host order");
            Check
              (L1_Data_Cache_Size (Fastest_Core_Class).Value = Fastest.Value,
               "class 1 does not describe performance level 0");

            if Count.Value >= 2 then
               --  Level 1 is the efficiency level on Apple silicon, and the
               --  flat sysctl reports exactly that level.
               Check
                 (L1_Data_Cache_Size (2).Value =
                    Query ("hw.perflevel1.l1dcachesize").Value,
                  "class 2 does not describe performance level 1");
               Check
                 (L1_Data_Cache_Size (2).Value = Flat.Value,
                  "the flat sysctl does not match the last level");
            end if;

            for Class in Core_Class range 1 .. Core_Class (Count.Value) loop
               Check
                 (Core_Class_Cores (Class).Available
                    and then Core_Class_CPUs (Class).Available,
                  "a macOS core class reports no core or CPU count");
            end loop;
         else
            Check
              (Count.Value = 1,
               "a host without performance levels reported several classes");
         end if;
      end;
   end Run;

end Flyology_Cachelines.Macos_Testing;
