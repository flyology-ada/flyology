with Interfaces.C;
with System;

package body Flyology_Cachelines.Macos is

   use type Interfaces.C.int;
   use type Interfaces.C.size_t;
   use type Interfaces.Unsigned_64;

   Narrow_Width : constant Interfaces.C.size_t := 4;
   Wide_Width   : constant Interfaces.C.size_t := 8;

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

      --  Read exactly Width bytes of the value into Target.  A reply of a
      --  different length is rejected instead of interpreted.
      function Read
        (Target : System.Address;
         Width  : Interfaces.C.size_t) return Boolean
      is
         Length : aliased Interfaces.C.size_t := Width;
      begin
         return
           Sysctl_By_Name
             (Name      => C_Name'Address,
              Old_Value => Target,
              Old_Len   => Length'Address,
              New_Value => System.Null_Address,
              New_Len   => 0) = 0
           and then Length = Width;
      end Read;

      Width  : aliased Interfaces.C.size_t := 0;
      Narrow : aliased Interfaces.Unsigned_32 := 0;
      Wide   : aliased Interfaces.Unsigned_64 := 0;
      Value  : Interfaces.Unsigned_64;
   begin
      --  A null value buffer asks only for the width of the stored value.
      if Sysctl_By_Name
           (Name      => C_Name'Address,
            Old_Value => System.Null_Address,
            Old_Len   => Width'Address,
            New_Value => System.Null_Address,
            New_Len   => 0) /= 0
      then
         return Unavailable;
      end if;

      if Width = Narrow_Width then
         if not Read (Narrow'Address, Narrow_Width) then
            return Unavailable;
         end if;
         Value := Interfaces.Unsigned_64 (Narrow);
      elsif Width = Wide_Width then
         if not Read (Wide'Address, Wide_Width) then
            return Unavailable;
         end if;
         Value := Wide;
      else
         --  Strings, structures, and other non-integer values are not cache
         --  quantities.
         return Unavailable;
      end if;

      if Value = 0 or else Value > Interfaces.Unsigned_64 (Natural'Last) then
         return Unavailable;
      end if;

      return (Available => True, Value => Natural (Value));
   exception
      when others =>
         return Unavailable;
   end Query;

end Flyology_Cachelines.Macos;
