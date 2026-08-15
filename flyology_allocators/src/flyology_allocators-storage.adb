with System.Address_To_Access_Conversions;

package body Flyology_Allocators.Storage is
   use type Interfaces.C.int;
   use type Interfaces.C.size_t;

   type Eight_Bytes is array (Natural range 0 .. 7) of Interfaces.Unsigned_8
     with Component_Size => 8, Size => 64, Alignment => 1;

   package U8_Access is new System.Address_To_Access_Conversions
     (Interfaces.Unsigned_8);
   package U32_Access is new System.Address_To_Access_Conversions
     (Interfaces.Unsigned_32);
   package U64_Access is new System.Address_To_Access_Conversions
     (Interfaces.Unsigned_64);
   package Eight_Access is new System.Address_To_Access_Conversions
     (Eight_Bytes);

   function C_Move
     (Target : System.Address;
      Source : System.Address;
      Length : Interfaces.C.size_t) return System.Address;
   pragma Import (C, C_Move, "memmove");

   function C_Equal
     (Left   : System.Address;
      Right  : System.Address;
      Length : Interfaces.C.size_t) return Interfaces.C.int;
   pragma Import (C, C_Equal, "memcmp");
   function Read_U8
     (Address : System.Address) return Interfaces.Unsigned_8 is
     (U8_Access.To_Pointer (Address).all);

   function Read_U32
     (Address : System.Address) return Interfaces.Unsigned_32 is
     (U32_Access.To_Pointer (Address).all);

   function Read_U64
     (Address : System.Address) return Interfaces.Unsigned_64 is
     (U64_Access.To_Pointer (Address).all);

   procedure Write_U8
     (Address : System.Address; Value : Interfaces.Unsigned_8) is
   begin
      U8_Access.To_Pointer (Address).all := Value;
   end Write_U8;

   procedure Write_U32
     (Address : System.Address; Value : Interfaces.Unsigned_32) is
   begin
      U32_Access.To_Pointer (Address).all := Value;
   end Write_U32;

   procedure Write_U64
     (Address : System.Address; Value : Interfaces.Unsigned_64) is
   begin
      U64_Access.To_Pointer (Address).all := Value;
   end Write_U64;

   procedure Copy
      (Target : System.Address;
       Source : System.Address;
      Length : Interfaces.C.size_t) is
   begin
      if Length = 8 then
         Eight_Access.To_Pointer (Target).all :=
           Eight_Access.To_Pointer (Source).all;
         return;
      end if;
      declare
         Ignored : constant System.Address := C_Move (Target, Source, Length);
         pragma Unreferenced (Ignored);
      begin
         null;
      end;
   end Copy;

   function Equal
      (Left   : System.Address;
       Right  : System.Address;
      Length : Interfaces.C.size_t) return Boolean is
     (C_Equal (Left, Right, Length) = 0);

end Flyology_Allocators.Storage;
