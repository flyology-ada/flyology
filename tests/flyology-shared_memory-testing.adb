with System.Storage_Elements;

package body Flyology.Shared_Memory.Testing is
   function Base (Item : Mapping) return System.Address is
     (Item.State.Base);

   function Base_Value (Item : Mapping) return Interfaces.Unsigned_64 is
     (Interfaces.Unsigned_64
        (System.Storage_Elements.To_Integer (Item.State.Base)));

   function Descriptor (Item : Backing_Object) return Interfaces.C.int is
     (Owned_Descriptor (Item));
end Flyology.Shared_Memory.Testing;
