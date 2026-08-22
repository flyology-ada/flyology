with Flyology.Atomic_Primitives;
with System.Storage_Elements;

package body Flyology.Shared_Memory.Testing is
   use type System.Storage_Elements.Storage_Offset;

   function Base (Item : Mapping) return System.Address
   is (Item.State.Base);

   function Base_Value (Item : Mapping) return Interfaces.Unsigned_64
   is (Interfaces.Unsigned_64 (System.Storage_Elements.To_Integer (Item.State.Base)));

   function Descriptor (Item : Backing_Object) return Interfaces.C.int
   is (Owned_Descriptor (Item));

   procedure Store_Release_U32 (Item : Mapping; Offset : Byte_Length; Value : Interfaces.Unsigned_32) is
   begin
      Flyology.Atomic_Primitives.Store_Release_U32
        (Item.State.Base + System.Storage_Elements.Storage_Offset (Offset), Value);
   end Store_Release_U32;

   procedure Store_Release_U64 (Item : Mapping; Offset : Byte_Length; Value : Interfaces.Unsigned_64) is
   begin
      Flyology.Atomic_Primitives.Store_Release_U64
        (Item.State.Base + System.Storage_Elements.Storage_Offset (Offset), Value);
   end Store_Release_U64;
end Flyology.Shared_Memory.Testing;
