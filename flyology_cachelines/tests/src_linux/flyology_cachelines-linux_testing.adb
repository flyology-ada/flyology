with Flyology_Cachelines.Linux;

package body Flyology_Cachelines.Linux_Testing is

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   procedure Check_Query
     (Name   : String;
      Result : Flyology_Cachelines.Linux.Cache_Parameters) is
   begin
      Check (Result.Available, Name & " cache detection failed");
      Check
        (Result.Total_Size mod Result.Line_Size = 0,
         Name & " cache size is not a whole number of lines");
   end Check_Query;

   procedure Run is
   begin
      Check_Query ("sysconf", Flyology_Cachelines.Linux.Detect_From_Sysconf);
      Check_Query ("sysfs", Flyology_Cachelines.Linux.Detect_From_Sysfs);
   end Run;

end Flyology_Cachelines.Linux_Testing;
