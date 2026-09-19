--  Internal non-mutating slab lifecycle validation for composite owners.
--  @exclude
generic
package Flyology.Data_Structures.Slab_Pools.Validation with Preelaborate is

   --  Validate that every slot is free without changing stored or local state.
   --  @param Item Exclusively synchronized slab view
   --  @exception Program_Error One or more slots are not free
   --  @exclude
   procedure Validate_Empty (Item : View);

   --  Observe whether every slot is live before a composite owner caches
   --  exhaustion. A transient slot must not be treated as permanently full.
   --  @param Item Attached slab view
   --  @return Whether all slots were observed live
   --  @exclude
   function All_Live (Item : View) return Boolean;

end Flyology.Data_Structures.Slab_Pools.Validation;
