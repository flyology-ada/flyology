package body Flyology.Data_Structures.Slab_Pools.Validation is

   procedure Validate_Empty (Item : View) is
   begin
      Flyology.Data_Structures.Slab_Pools.Validate_Empty (Item);
   end Validate_Empty;

   function All_Live (Item : View) return Boolean
   is (Flyology.Data_Structures.Slab_Pools.All_Live (Item));

end Flyology.Data_Structures.Slab_Pools.Validation;
