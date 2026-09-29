--  Internal non-mutating slab lifecycle validation for composite owners.
--  @exclude
generic
package Flyology.Data_Structures.Slab_Pools.Validation with Preelaborate is

   --  Validate that every slot is free without changing stored or local state.
   --  @param Item Exclusively synchronized slab view
   --  @exception Program_Error One or more slots are not free
   --  @exclude
   procedure Validate_Empty (Item : View);

end Flyology.Data_Structures.Slab_Pools.Validation;
