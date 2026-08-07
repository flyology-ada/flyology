with Interfaces.C;
with System;

package body Flyology_Cachelines.Platform is

   use type Interfaces.C.int;
   use type Interfaces.C.size_t;

   function Sysctl_By_Name
     (Name      : System.Address;
      Old_Value : System.Address;
      Old_Len   : System.Address;
      New_Value : System.Address;
      New_Len   : Interfaces.C.size_t) return Interfaces.C.int
     with Import,
          Convention    => C,
          External_Name => "sysctlbyname";

   function Query (Name : String) return Cache_Query_Result is
      C_Name : aliased constant Interfaces.C.char_array :=
        Interfaces.C.To_C (Name);
      Value  : aliased Interfaces.C.size_t := 0;
      Length : aliased Interfaces.C.size_t :=
        Interfaces.C.size_t (Value'Size / System.Storage_Unit);
      Result : constant Interfaces.C.int :=
        Sysctl_By_Name
          (Name      => C_Name'Address,
           Old_Value => Value'Address,
           Old_Len   => Length'Address,
           New_Value => System.Null_Address,
           New_Len   => 0);
   begin
      if Result /= 0
        or else Value = 0
        or else Value > Interfaces.C.size_t (Natural'Last)
      then
         return Unavailable;
      end if;

      return (Available => True, Value => Natural (Value));
   exception
      when others =>
         return Unavailable;
   end Query;

   Detected_Hardware_Cache_Line_Size : constant Cache_Query_Result :=
     Query ("hw.cachelinesize");
   Detected_L1_Data_Cache_Size : constant Cache_Query_Result :=
     Query ("hw.l1dcachesize");

   function Hardware_Cache_Line_Size return Cache_Query_Result is
     (Detected_Hardware_Cache_Line_Size);

   function L1_Data_Cache_Size return Cache_Query_Result is
     (Detected_L1_Data_Cache_Size);

end Flyology_Cachelines.Platform;
