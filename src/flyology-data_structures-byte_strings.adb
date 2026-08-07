with Flyology.Data_Structures.Storage;
with Interfaces.C;
with System.Storage_Elements;

package body Flyology.Data_Structures.Byte_Strings is
   package Bytes renames Flyology.Data_Structures.Storage;
   package Addressing renames System.Storage_Elements;

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Addressing.Storage_Offset;

   Length_Offset : constant Byte_Count := 48;

   function Required_Storage (Maximum_Length : Positive) return Byte_Count is
     (Layouts.Checked_Add
        (Layouts.Header_Size, Byte_Count (Maximum_Length)));

   procedure Set_View
     (Item : out View;
      Core : Layouts.Local_View;
      Maximum_Length : Interfaces.Unsigned_32) is
   begin
      Item.Core := Core;
      Item.Length_Address := Layouts.Address_At
        (Core, Length_Offset, 8, 8);
      Item.Payload_Address := Layouts.Address_At
        (Core, Layouts.Header_Size, Byte_Count (Maximum_Length), 1);
      Item.Capacity_Value := Maximum_Length;
   end Set_View;

   procedure Initialize
     (Item           : out View;
      Region         : Region_View;
      Location       : Region_Offset;
      Maximum_Length : Positive)
   is
      Core : Layouts.Local_View;
      Stored_Capacity : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Maximum_Length);
   begin
      Layouts.Begin_Initialize
        (Core, Region, Location, Identity,
         Required_Storage (Maximum_Length),
         (Capacity     => Stored_Capacity,
          Element_Size => 1,
          Alignment    => 1,
          Auxiliary    => 0,
          Word_1       => 0,
          Word_2       => 0),
         8);
      Set_View (Item, Core, Stored_Capacity);
      Layouts.Publish (Item.Core);
   end Initialize;

   procedure Attach
     (Item           : out View;
      Region         : Region_View;
      Location       : Region_Offset;
      Maximum_Length : Positive)
   is
      Core   : Layouts.Local_View;
      Header : Layouts.Header_Values;
      Expected : constant Byte_Count := Required_Storage (Maximum_Length);
   begin
      Layouts.Attach (Core, Header, Region, Location, Identity, 8);
      if Header.Capacity /= Interfaces.Unsigned_32 (Maximum_Length)
        or else Header.Element_Size /= 1
        or else Header.Alignment /= 1
        or else Header.Auxiliary /= 0
        or else Header.Word_2 /= 0
        or else Core.Extent /= Expected
        or else Header.Word_1 > Interfaces.Unsigned_64 (Header.Capacity)
      then
         raise Layout_Error with "byte-string layout does not match";
      end if;
      Set_View (Item, Core, Header.Capacity);
   end Attach;

   procedure Detach (Item : in out View) is
   begin
      Layouts.Detach (Item.Core);
      Item.Length_Address := System.Null_Address;
      Item.Payload_Address := System.Null_Address;
      Item.Capacity_Value := 0;
   end Detach;

   function Is_Attached (Item : View) return Boolean is (Item.Core.Attached);

   function Capacity (Item : View) return Natural is
   begin
      if not Item.Core.Attached then
         raise Region_Error with "detached byte-string view";
      end if;
      return Natural (Item.Capacity_Value);
   end Capacity;

   function Stored_Length (Item : View) return Interfaces.Unsigned_64 is
      Result : Interfaces.Unsigned_64;
   begin
      Layouts.Require_Ready (Item.Core);
      Result := Bytes.Read_U64
        (Item.Length_Address);
      if Result > Interfaces.Unsigned_64 (Item.Capacity_Value) then
         raise Layout_Error with "byte-string length is corrupt";
      end if;
      return Result;
   end Stored_Length;

   function Length (Item : View) return Natural is
     (Natural (Stored_Length (Item)));

   function Data_Address
     (Item : View; Offset, Extent : Byte_Count) return System.Address is
   begin
      if Offset > Byte_Count (Item.Capacity_Value)
        or else Extent > Byte_Count (Item.Capacity_Value) - Offset
      then
         raise Layout_Error with "byte-string payload extent is corrupt";
      end if;
      return Item.Payload_Address + Addressing.Storage_Offset (Offset);
   end Data_Address;

   procedure Assign
     (Item : in out View; Data : Ada.Streams.Stream_Element_Array) is
   begin
      Layouts.Require_Ready (Item.Core);
      if Byte_Count (Data'Length) > Byte_Count (Item.Capacity_Value) then
         raise Constraint_Error with "byte string exceeds capacity";
      end if;
      if Data'Length > 0 then
         Bytes.Copy
           (Data_Address (Item, 0, Byte_Count (Data'Length)), Data'Address,
            Interfaces.C.size_t (Data'Length));
      end if;
      Bytes.Write_U64
        (Item.Length_Address, Interfaces.Unsigned_64 (Data'Length));
   end Assign;

   procedure Append
     (Item : in out View; Data : Ada.Streams.Stream_Element_Array)
   is
      Old_Length : constant Interfaces.Unsigned_64 := Stored_Length (Item);
      Added      : constant Byte_Count := Byte_Count (Data'Length);
   begin
      if Added >
        Byte_Count (Item.Capacity_Value) - Byte_Count (Old_Length)
      then
         raise Constraint_Error with "byte-string append exceeds capacity";
      end if;
      if Data'Length > 0 then
         Bytes.Copy
           (Data_Address
              (Item, Byte_Count (Old_Length), Added),
            Data'Address, Interfaces.C.size_t (Data'Length));
      end if;
      Bytes.Write_U64
        (Item.Length_Address, Old_Length + Interfaces.Unsigned_64 (Data'Length));
   end Append;

   procedure Read
     (Item : View; Data : out Ada.Streams.Stream_Element_Array)
   is
      Current : constant Interfaces.Unsigned_64 := Stored_Length (Item);
   begin
      if Byte_Count (Data'Length) /= Byte_Count (Current) then
         raise Constraint_Error with "byte-string destination length differs";
      end if;
      if Data'Length > 0 then
         Bytes.Copy
           (Data'Address, Data_Address (Item, 0, Byte_Count (Current)),
            Interfaces.C.size_t (Data'Length));
      end if;
   end Read;

   procedure Clear (Item : in out View) is
   begin
      Layouts.Require_Ready (Item.Core);
      Bytes.Write_U64 (Item.Length_Address, 0);
   end Clear;

   procedure Destroy (Item : in out View) is
   begin
      Layouts.Mark_Destroyed (Item.Core);
      Detach (Item);
   end Destroy;

end Flyology.Data_Structures.Byte_Strings;
