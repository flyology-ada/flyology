package body Flyology.Data_Structures.Storage_Types.Elements is
   function Create (Item : Source) return Value
   is (Create_Value (Item));

   procedure Construct (Item : in out Builder; Data : Source) is
   begin
      if Direct_Constructor = null then
         Representation.Assign (Item, Create_Value (Data));
      else
         Direct_Constructor.all (Item, Data);
      end if;
   end Construct;

   function Observe (Item : Const_Ref) return Observed
   is (Observe_Value (Item));
end Flyology.Data_Structures.Storage_Types.Elements;
