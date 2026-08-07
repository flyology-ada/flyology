with System.Storage_Elements;

package body Flyology.Data_Structures is
   package Addressing renames System.Storage_Elements;

   use type Addressing.Integer_Address;
   use type Addressing.Storage_Offset;
   use type System.Address;

   function Checked_Address
     (Base        : System.Address;
      Length      : Byte_Count;
      Is_Attached : Boolean;
      Offset      : Region_Offset;
      Extent      : Byte_Count;
      Alignment   : Byte_Count) return System.Address
   is
      Base_Value : Addressing.Integer_Address;
      At_Value   : Addressing.Integer_Address;
   begin
      if not Is_Attached or else Base = System.Null_Address then
         raise Region_Error with "detached backing-region view";
      elsif Extent = 0 then
         raise Region_Error with "zero-sized backing-region slice";
      elsif Alignment = 0
        or else (Alignment and (Alignment - 1)) /= 0
      then
         raise Region_Error with "invalid backing-region alignment";
      elsif Byte_Count (Offset) > Length
        or else Extent > Length - Byte_Count (Offset)
      then
         raise Region_Error with "backing-region slice is out of bounds";
      elsif Byte_Count (Offset) >
        Byte_Count (Addressing.Storage_Offset'Last)
      then
         raise Region_Error with "backing-region offset is not native";
      end if;

      Base_Value := Addressing.To_Integer (Base);
      if Byte_Count (Offset) >
        Byte_Count (Addressing.Integer_Address'Last - Base_Value)
      then
         raise Region_Error with "backing-region address overflows";
      end if;
      At_Value := Base_Value + Addressing.Integer_Address (Offset);
      if At_Value mod Addressing.Integer_Address (Alignment) /= 0 then
         raise Region_Error with "backing-region slice is misaligned";
      end if;
      return Base + Addressing.Storage_Offset (Offset);
   end Checked_Address;

end Flyology.Data_Structures;
