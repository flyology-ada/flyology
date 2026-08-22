with Flyology.Data_Structures.Storage;
with Interfaces.C;
with System.Storage_Elements;

package body Flyology.Data_Structures.Storage_Types.Immutable is
   package Bytes renames Flyology.Data_Structures.Storage;
   package Addressing renames System.Storage_Elements;

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Addressing.Integer_Address;
   use type System.Address;

   procedure Check_Contract (Storage : Immutable_Storage_View) is
   begin
      if Type_Signature = 0
        or else Layout_Version = 0
        or else Required_Alignment not in 1 | 2 | 4 | 8 | 16 | 32 | 64
        or else Storage.Base = System.Null_Address
        or else Storage.Extent /= Byte_Count (Byte_Size)
        or else Storage.Signature /= Type_Signature
        or else Storage.Version /= Layout_Version
        or else Addressing.To_Integer (Storage.Base) mod Addressing.Integer_Address (Required_Alignment) /= 0
      then
         raise Layout_Error with "immutable element storage contract mismatch";
      end if;
   end Check_Contract;
   pragma Inline_Always (Check_Contract);

   function Field_Address (Base : System.Address; Offset, Extent, Alignment : Natural) return System.Address
   is
      Address : Addressing.Integer_Address;
   begin
      if Base = System.Null_Address
        or else Extent = 0
        or else Offset > Byte_Size
        or else Extent > Byte_Size - Offset
      then
         raise Constraint_Error with "immutable element field is out of range";
      end if;
      Address := Addressing.To_Integer (Base);
      if Address > Addressing.Integer_Address'Last - Addressing.Integer_Address (Offset) then
         raise Region_Error with "immutable element field address overflows";
      end if;
      Address := Address + Addressing.Integer_Address (Offset);
      if Alignment > 1 and then Address mod Addressing.Integer_Address (Alignment) /= 0 then
         raise Constraint_Error with "immutable element field is misaligned";
      end if;
      return Addressing.To_Address (Address);
   end Field_Address;
   pragma Inline_Always (Field_Address);

   function Start return Value_Builder
   is (Data => (others => 0), Active => True);

   function Freeze (Item : in out Value_Builder) return Value is
   begin
      if not Item.Active then
         raise Program_Error with "immutable value builder is inactive";
      end if;
      Item.Active := False;
      return Item.Data;
   end Freeze;

   procedure Require (Item : Const_Ref) is
   begin
      if not Item.Active or else Item.Base = System.Null_Address then
         raise Program_Error with "immutable element reference is inactive";
      end if;
   end Require;
   pragma Inline_Always (Require);

   procedure Require (Item : Builder) is
   begin
      if not Item.Active or else Item.Base = System.Null_Address then
         raise Program_Error with "immutable element builder is inactive";
      end if;
   end Require;
   pragma Inline_Always (Require);

   procedure Require (Item : Value_Builder) is
   begin
      if not Item.Active then
         raise Program_Error with "immutable value builder is inactive";
      end if;
   end Require;
   pragma Inline_Always (Require);

   function Load_U8 (Item : Const_Ref; Offset : Natural) return Interfaces.Unsigned_8 is
   begin
      Require (Item);
      return Bytes.Read_U8 (Field_Address (Item.Base, Offset, 1, 1));
   end Load_U8;

   function Load_U32 (Item : Const_Ref; Offset : Natural) return Interfaces.Unsigned_32 is
   begin
      Require (Item);
      return Bytes.Read_U32 (Field_Address (Item.Base, Offset, 4, 4));
   end Load_U32;

   function Load_U64 (Item : Const_Ref; Offset : Natural) return Interfaces.Unsigned_64 is
   begin
      Require (Item);
      return Bytes.Read_U64 (Field_Address (Item.Base, Offset, 8, 8));
   end Load_U64;

   procedure Store_U8 (Item : in out Builder; Offset : Natural; Data : Interfaces.Unsigned_8) is
   begin
      Require (Item);
      Bytes.Write_U8 (Field_Address (Item.Base, Offset, 1, 1), Data);
   end Store_U8;

   procedure Store_U32 (Item : in out Builder; Offset : Natural; Data : Interfaces.Unsigned_32) is
   begin
      Require (Item);
      Bytes.Write_U32 (Field_Address (Item.Base, Offset, 4, 4), Data);
   end Store_U32;

   procedure Store_U64 (Item : in out Builder; Offset : Natural; Data : Interfaces.Unsigned_64) is
   begin
      Require (Item);
      Bytes.Write_U64 (Field_Address (Item.Base, Offset, 8, 8), Data);
   end Store_U64;

   procedure Store_U8 (Item : in out Value_Builder; Offset : Natural; Data : Interfaces.Unsigned_8) is
   begin
      Require (Item);
      if Offset >= Byte_Size then
         raise Constraint_Error with "immutable element field is out of range";
      end if;
      Item.Data (Offset) := Data;
   end Store_U8;

   procedure Store_U32 (Item : in out Value_Builder; Offset : Natural; Data : Interfaces.Unsigned_32) is
   begin
      Require (Item);
      Bytes.Copy (Field_Address (Item.Data'Address, Offset, 4, 1), Data'Address, Interfaces.C.size_t (4));
   end Store_U32;

   procedure Store_U64 (Item : in out Value_Builder; Offset : Natural; Data : Interfaces.Unsigned_64) is
   begin
      Require (Item);
      Bytes.Copy (Field_Address (Item.Data'Address, Offset, 8, 1), Data'Address, Interfaces.C.size_t (8));
   end Store_U64;

   procedure Copy_To (Item : Value; Target : Immutable_Storage_View) is
   begin
      Check_Contract (Target);
      if not Target.Writable then
         raise Program_Error with "immutable element target is read-only";
      end if;
      Bytes.Copy (Target.Base, Item'Address, Interfaces.C.size_t (Byte_Size));
   end Copy_To;

   procedure Assign (Item : in out Builder; Data : Value) is
   begin
      Require (Item);
      Bytes.Copy (Item.Base, Data'Address, Interfaces.C.size_t (Byte_Size));
   end Assign;

   procedure Copy (Source : Immutable_Storage_View; Target : Immutable_Storage_View) is
   begin
      Check_Contract (Source);
      Check_Contract (Target);
      if not Target.Writable then
         raise Program_Error with "immutable element target is read-only";
      end if;
      Bytes.Copy (Target.Base, Source.Base, Interfaces.C.size_t (Byte_Size));
   end Copy;

   function Copy_From (Source : Immutable_Storage_View) return Value is
      Result : Value := (others => 0);
   begin
      Check_Contract (Source);
      Bytes.Copy (Result'Address, Source.Base, Interfaces.C.size_t (Byte_Size));
      return Result;
   end Copy_From;

   procedure Bind (Item : out Const_Ref; Source : Immutable_Storage_View) is
   begin
      Check_Contract (Source);
      Item.Base := Source.Base;
      Item.Active := True;
   end Bind;

   procedure Bind (Item : out Builder; Target : Immutable_Storage_View) is
   begin
      Check_Contract (Target);
      if not Target.Writable then
         raise Program_Error with "immutable element builder is read-only";
      end if;
      Item.Base := Target.Base;
      Item.Active := True;
   end Bind;

   function Hash (Item : Value) return Interfaces.Unsigned_64 is
      Result : Interfaces.Unsigned_64 := 16#CBF2_9CE4_8422_2325#;
   begin
      for Byte of Item loop
         Result := (Result xor Interfaces.Unsigned_64 (Byte)) * 16#0000_0100_0000_01B3#;
      end loop;
      return Result;
   end Hash;

   function Hash (Item : Const_Ref) return Interfaces.Unsigned_64 is
      Result : Interfaces.Unsigned_64 := 16#CBF2_9CE4_8422_2325#;
   begin
      Require (Item);
      for Offset in Natural range 0 .. Byte_Size - 1 loop
         Result :=
           (Result xor Interfaces.Unsigned_64 (Bytes.Read_U8 (Field_Address (Item.Base, Offset, 1, 1))))
           * 16#0000_0100_0000_01B3#;
      end loop;
      return Result;
   end Hash;

   function Equivalent (Left : Value; Right : Const_Ref) return Boolean is
   begin
      Require (Right);
      return Bytes.Equal (Left'Address, Right.Base, Interfaces.C.size_t (Byte_Size));
   end Equivalent;

   function Equivalent (Left : Const_Ref; Right : Const_Ref) return Boolean is
   begin
      Require (Left);
      Require (Right);
      return Bytes.Equal (Left.Base, Right.Base, Interfaces.C.size_t (Byte_Size));
   end Equivalent;

end Flyology.Data_Structures.Storage_Types.Immutable;
