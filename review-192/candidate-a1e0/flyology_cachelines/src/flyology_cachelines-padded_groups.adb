with System.Address_To_Access_Conversions;
with System.Storage_Elements;

package body Flyology_Cachelines.Padded_Groups is

   package Element_Pointers is new System.Address_To_Access_Conversions (Element_Type);

   use type System.Storage_Elements.Integer_Address;

   function Has_Element (Position : Cursor) return Boolean
   is (Position /= No_Element);

   type Iterator is new Iterator_Interfaces.Forward_Iterator with record
      Last : Cursor;
   end record;

   overriding
   function First (Object : Iterator) return Cursor
   is (if Object.Last = No_Element then No_Element else 1);

   overriding
   function Next (Object : Iterator; Position : Cursor) return Cursor
   is (if Position = Object.Last then No_Element else Position + 1);

   procedure Locate
     (Container : Grouped_Array; Position : Positive; Group_Number : out Positive; Slot : out Index) is
   begin
      if Position > Length (Container) then
         raise Constraint_Error with "grouped-array index out of bounds";
      end if;

      Group_Number := (Position - 1) / Group_Length + 1;
      Slot := Index ((Position - 1) mod Group_Length + 1);
   end Locate;

   function Constant_Reference
     (Container : aliased Grouped_Array; Position : Positive) return Constant_Reference_Type
   is
      Group_Number : Positive;
      Slot         : Index;
   begin
      Locate (Container, Position, Group_Number, Slot);
      return Result : Constant_Reference_Type (Container.Groups (Group_Number) (Slot)'Access);
   end Constant_Reference;

   function Reference (Container : aliased in out Grouped_Array; Position : Positive) return Reference_Type is
      Group_Number : Positive;
      Slot         : Index;
   begin
      Locate (Container, Position, Group_Number, Slot);
      return Result : Reference_Type (Container.Groups (Group_Number) (Slot)'Access);
   end Reference;

   function Constant_Reference
     (Container : aliased Grouped_Array; Position : Cursor) return Constant_Reference_Type
   is (Constant_Reference (Container, Positive (Position)));

   function Reference (Container : aliased in out Grouped_Array; Position : Cursor) return Reference_Type
   is (Reference (Container, Positive (Position)));

   function Fast_First (View : Fast_View) return Fast_Cursor
   is (Element_Address => View.Container.Groups (1) (Index'First)'Address,
       Remaining       => Length (View.Container.all),
       Slot            => Index'First);

   function Fast_Next (View : Fast_View; Position : Fast_Cursor) return Fast_Cursor is
      pragma Unreferenced (View);
      Step : constant Positive :=
        (if Position.Slot = Index'Last
         then Group_Size_In_Storage_Elements - (Group_Length - 1) * Element_Stride_In_Storage_Elements
         else Element_Stride_In_Storage_Elements);
   begin
      return
        (Element_Address =>
           System.Storage_Elements.To_Address
             (System.Storage_Elements.To_Integer (Position.Element_Address)
              + System.Storage_Elements.Integer_Address (Step)),
         Remaining       => Position.Remaining - 1,
         Slot            => (if Position.Slot = Index'Last then Index'First else Position.Slot + 1));
   end Fast_Next;

   function Fast_Has_Element (View : Fast_View; Position : Fast_Cursor) return Boolean is
      pragma Unreferenced (View);
   begin
      return Position.Remaining /= 0;
   end Fast_Has_Element;

   function Fast_Reference (View : Fast_View; Position : Fast_Cursor) return Reference_Type is
      pragma Unreferenced (View);
   begin
      return (Element => Element_Pointers.To_Pointer (Position.Element_Address));
   end Fast_Reference;

   function Iterate (Container : Grouped_Array) return Iterator_Interfaces.Forward_Iterator'Class
   is (Iterator'(Last => Cursor (Length (Container))));

   function Create (Element_Count : Positive; Initial_Value : Element_Type) return Grouped_Array is
      Group_Count       : constant Positive := (Element_Count - 1) / Group_Length + 1;
      Last_Group_Length : constant Index := Index ((Element_Count - 1) mod Group_Length + 1);
   begin
      return
        (Group_Count       => Group_Count,
         Last_Group_Length => Last_Group_Length,
         Groups            => (others => (others => Initial_Value)));
   end Create;

end Flyology_Cachelines.Padded_Groups;
