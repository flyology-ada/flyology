with Flyology.Data_Structures.Storage;
with Interfaces.C;
with System.Storage_Elements;

package body Flyology.Data_Structures.Vectors is
   package Bytes renames Flyology.Data_Structures.Storage;
   package Addressing renames System.Storage_Elements;

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Addressing.Integer_Address;
   use type Addressing.Storage_Offset;
   use type System.Address;

   Length_Offset : constant Byte_Count := 48;

   procedure Geometry
     (Capacity     : Positive;
      Element_Size : Positive;
      Stride       : out Byte_Count;
      Extent       : out Byte_Count) is
   begin
      Stride := Layouts.Align_Up (Byte_Count (Element_Size), 8);
      Extent := Layouts.Checked_Add
        (Layouts.Header_Size,
         Layouts.Checked_Multiply (Byte_Count (Capacity), Stride));
   end Geometry;

   function Required_Storage
     (Capacity : Positive; Element_Size : Positive) return Byte_Count
   is
      Stride : Byte_Count;
      Extent : Byte_Count;
   begin
      Geometry (Capacity, Element_Size, Stride, Extent);
      return Extent;
   end Required_Storage;

   procedure Set_View
     (Item : out View; Core : Layouts.Local_View;
      Capacity, Element_Size : Interfaces.Unsigned_32;
      Stride : Byte_Count) is
   begin
      Item.Core := Core;
      Item.Length_Address := Layouts.Address_At
        (Core, Length_Offset, 8, 8);
      Item.Payload_Address := Layouts.Address_At
        (Core, Layouts.Header_Size,
         Core.Extent - Layouts.Header_Size, 1);
      Item.Payload_Extent := Core.Extent - Layouts.Header_Size;
      Item.Capacity_Value := Capacity;
      Item.Element_Value := Element_Size;
      Item.Stride := Stride;
   end Set_View;

   procedure Initialize
     (Item         : out View;
      Region       : Region_View;
      Location     : Region_Offset;
      Capacity     : Positive;
      Element_Size : Positive)
   is
      Core : Layouts.Local_View;
      Stride, Extent : Byte_Count;
   begin
      Geometry (Capacity, Element_Size, Stride, Extent);
      Layouts.Begin_Initialize
        (Core, Region, Location, Identity, Extent,
         (Capacity     => Interfaces.Unsigned_32 (Capacity),
          Element_Size => Interfaces.Unsigned_32 (Element_Size),
          Alignment    => 8,
          Auxiliary    => 0,
          Word_1       => 0,
          Word_2       => Interfaces.Unsigned_64 (Stride)),
         8);
      Set_View
        (Item, Core, Interfaces.Unsigned_32 (Capacity),
         Interfaces.Unsigned_32 (Element_Size), Stride);
      Layouts.Publish (Item.Core);
   end Initialize;

   procedure Attach
     (Item         : out View;
      Region       : Region_View;
      Location     : Region_Offset;
      Capacity     : Positive;
      Element_Size : Positive)
   is
      Core : Layouts.Local_View;
      Header : Layouts.Header_Values;
      Stride, Extent : Byte_Count;
   begin
      Geometry (Capacity, Element_Size, Stride, Extent);
      Layouts.Attach (Core, Header, Region, Location, Identity, 8);
      if Header.Capacity /= Interfaces.Unsigned_32 (Capacity)
        or else Header.Element_Size /= Interfaces.Unsigned_32 (Element_Size)
        or else Header.Alignment /= 8
        or else Header.Auxiliary /= 0
        or else Header.Word_2 /= Interfaces.Unsigned_64 (Stride)
        or else Header.Word_1 > Interfaces.Unsigned_64 (Header.Capacity)
        or else Core.Extent /= Extent
      then
         raise Layout_Error with "vector layout does not match";
      end if;
      Set_View
        (Item, Core, Header.Capacity, Header.Element_Size, Stride);
   end Attach;

   procedure Detach (Item : in out View) is
   begin
      Layouts.Detach (Item.Core);
      Item.Length_Address := System.Null_Address;
      Item.Payload_Address := System.Null_Address;
      Item.Payload_Extent := 0;
      Item.Capacity_Value := 0;
      Item.Element_Value := 0;
      Item.Stride := 0;
   end Detach;

   function Is_Attached (Item : View) return Boolean is (Item.Core.Attached);

   function Capacity (Item : View) return Natural is
   begin
      if not Item.Core.Attached then
         raise Region_Error with "detached vector view";
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
         raise Layout_Error with "vector length is corrupt";
      end if;
      return Result;
   end Stored_Length;

   function Length (Item : View) return Natural is
     (Natural (Stored_Length (Item)));

   procedure Check_Data (Item : View; Length : Natural) is
   begin
      if Byte_Count (Length) /= Byte_Count (Item.Element_Value) then
         raise Constraint_Error with "vector element length does not match";
      end if;
   end Check_Data;

   function Element_Address
     (Item : View; Index : Interfaces.Unsigned_64) return System.Address
   is
      Relative   : Byte_Count;
      Base_Value : Addressing.Integer_Address;
   begin
      if not Item.Core.Attached
        or else Item.Payload_Address = System.Null_Address
      then
         raise Region_Error with "detached vector view";
      elsif Index >= Interfaces.Unsigned_64 (Item.Capacity_Value) then
         raise Layout_Error with "vector element index exceeds payload";
      end if;

      Relative := Layouts.Checked_Multiply
        (Byte_Count (Index), Item.Stride);
      if Relative > Item.Payload_Extent
        or else Byte_Count (Item.Element_Value) >
          Item.Payload_Extent - Relative
      then
         raise Layout_Error with "vector element extent is corrupt";
      elsif Relative > Byte_Count (Addressing.Storage_Offset'Last) then
         raise Region_Error with "vector element offset is not native";
      end if;

      Base_Value := Addressing.To_Integer (Item.Payload_Address);
      if Relative > Byte_Count (Addressing.Integer_Address'Last - Base_Value)
      then
         raise Region_Error with "vector element address overflows";
      end if;
      return Item.Payload_Address + Addressing.Storage_Offset (Relative);
   end Element_Address;

   procedure Try_Append
     (Item     : in out View;
      Data     : Ada.Streams.Stream_Element_Array;
      Appended : out Boolean)
   is
      Current : constant Interfaces.Unsigned_64 := Stored_Length (Item);
   begin
      Check_Data (Item, Data'Length);
      if Current = Interfaces.Unsigned_64 (Item.Capacity_Value) then
         Appended := False;
         return;
      end if;
      Bytes.Copy
        (Element_Address (Item, Current), Data'Address,
         Interfaces.C.size_t (Data'Length));
      Bytes.Write_U64
        (Item.Length_Address, Current + 1);
      Appended := True;
   end Try_Append;

   procedure Check_Index (Item : View; Index : Positive) is
   begin
      if Interfaces.Unsigned_64 (Index) > Stored_Length (Item) then
         raise Constraint_Error with "vector index is out of range";
      end if;
   end Check_Index;

   procedure Read
     (Item  : View;
      Index : Positive;
      Data  : out Ada.Streams.Stream_Element_Array) is
   begin
      Check_Data (Item, Data'Length);
      Check_Index (Item, Index);
      Bytes.Copy
        (Data'Address,
         Element_Address (Item, Interfaces.Unsigned_64 (Index - 1)),
         Interfaces.C.size_t (Data'Length));
   end Read;

   procedure Replace
     (Item  : in out View;
      Index : Positive;
      Data  : Ada.Streams.Stream_Element_Array) is
   begin
      Check_Data (Item, Data'Length);
      Check_Index (Item, Index);
      Bytes.Copy
        (Element_Address (Item, Interfaces.Unsigned_64 (Index - 1)),
         Data'Address, Interfaces.C.size_t (Data'Length));
   end Replace;

   procedure Try_Pop
     (Item   : in out View;
      Data   : out Ada.Streams.Stream_Element_Array;
      Popped : out Boolean)
   is
      Current : Interfaces.Unsigned_64;
   begin
      Check_Data (Item, Data'Length);
      Current := Stored_Length (Item);
      if Current = 0 then
         Popped := False;
         return;
      end if;
      Bytes.Copy
        (Data'Address, Element_Address (Item, Current - 1),
         Interfaces.C.size_t (Data'Length));
      Bytes.Write_U64
        (Item.Length_Address, Current - 1);
      Popped := True;
   end Try_Pop;

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

end Flyology.Data_Structures.Vectors;
