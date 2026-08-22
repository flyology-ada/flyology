with System.Storage_Elements;

package body Flyology.Data_Structures.Regions is
   package Storage renames System.Storage_Elements;

   use type Storage.Integer_Address;
   use type System.Address;

   procedure Attach (Item : in out View; Base : System.Address; Length : Byte_Count) is
      Base_Value : Storage.Integer_Address;
   begin
      if Base = System.Null_Address then
         raise Region_Error with "cannot attach a null backing-region base";
      elsif Length = 0 then
         raise Region_Error with "cannot attach an empty backing region";
      elsif Length - 1 > Byte_Count (Storage.Storage_Offset'Last) then
         raise Region_Error with "backing region is not natively indexable";
      end if;

      Base_Value := Storage.To_Integer (Base);
      if Length - 1 > Byte_Count (Storage.Integer_Address'Last - Base_Value) then
         raise Region_Error with "backing-region address range overflows";
      end if;

      Item.Base := Base;
      Item.Length_Value := Length;
      Item.Attached := True;
   end Attach;

   procedure Detach (Item : in out View) is
   begin
      Item.Base := System.Null_Address;
      Item.Length_Value := 0;
      Item.Attached := False;
   end Detach;

   function Is_Attached (Item : View) return Boolean
   is (Item.Attached);

   function Length (Item : View) return Byte_Count
   is (if Item.Attached then Item.Length_Value else 0);

   procedure Validate (Item : View; Offset : Region_Offset; Extent : Byte_Count; Alignment : Byte_Count := 1)
   is
      Address : System.Address;
      pragma Unreferenced (Address);
   begin
      if Offset = Null_Offset then
         raise Region_Error with "null backing-region offset";
      end if;
      Address := Checked_Address (Item.Base, Item.Length_Value, Item.Attached, Offset, Extent, Alignment);
   end Validate;

end Flyology.Data_Structures.Regions;
