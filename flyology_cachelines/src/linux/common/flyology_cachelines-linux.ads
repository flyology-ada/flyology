private package Flyology_Cachelines.Linux is

   type Cache_Parameters (Available : Boolean := False) is record
      case Available is
         when True =>
            Line_Size  : Positive;
            Total_Size : Positive;
         when False =>
            null;
      end case;
   end record;

   No_Cache_Parameters : constant Cache_Parameters := (Available => False);

   function Detect_From_Sysconf return Cache_Parameters;

   function Detect_From_Sysfs return Cache_Parameters;

end Flyology_Cachelines.Linux;
