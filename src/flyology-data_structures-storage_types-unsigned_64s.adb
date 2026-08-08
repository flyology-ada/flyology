with Ada.Unchecked_Conversion;

package body Flyology.Data_Structures.Storage_Types.Unsigned_64s is
   function To_Value is new Ada.Unchecked_Conversion
     (Interfaces.Unsigned_64, Value);

   function To_Unsigned_64 is new Ada.Unchecked_Conversion
     (Value, Interfaces.Unsigned_64);

   function Create (Item : Interfaces.Unsigned_64) return Value is
     (To_Value (Item));

   function Value_Of (Item : Const_Ref) return Interfaces.Unsigned_64 is
     (Representation.Load_U64 (Item, 0));

   function Value_Of (Item : Value) return Interfaces.Unsigned_64 is
     (To_Unsigned_64 (Item));

   procedure Set
     (Item : in out Builder; Value : Interfaces.Unsigned_64) is
   begin
      Representation.Store_U64 (Item, 0, Value);
   end Set;
end Flyology.Data_Structures.Storage_Types.Unsigned_64s;
