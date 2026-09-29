with Flyology.Data_Structures.Storage_Types.Immutable;
with Flyology.Data_Structures.Storage_Types.Elements;
with Interfaces;

--  Provides the built-in immutable native-layout Unsigned_64 value used by
--  typed containers. Value is backed by exactly eight bytes. Create writes an
--  independent immutable value once; Value_Of reads a published zero-copy
--  reference with one aligned scalar load. This layout is stable across the
--  currently tested little-endian targets.

package Flyology.Data_Structures.Storage_Types.Unsigned_64s is
   --  Underlying immutable storage contract accepted by container generics.
   package Representation is new
     Flyology.Data_Structures.Storage_Types.Immutable
       (Byte_Size          => 8,
        Required_Alignment => 8,
        Type_Signature     => 16#4644_5354_5536_3401#,
        Layout_Version     => 1);

   --  Independent immutable eight-byte value.
   subtype Value is Representation.Value;

   --  Read-only reference used by the bound observation operation.
   subtype Const_Ref is Representation.Const_Ref;

   --  Construct one independent immutable value.
   --  @param Item Scalar value to store
   --  @return Byte-backed immutable value
   function Create (Item : Interfaces.Unsigned_64) return Value;
   pragma Inline_Always (Create);

   --  Read one published value without copying its backing bytes.
   --  @param Item Active read-only container reference
   --  @return Scalar value loaded from the referenced bytes
   function Value_Of (Item : Const_Ref) return Interfaces.Unsigned_64;
   pragma Inline_Always (Value_Of);

   --  Read an independent immutable value.
   --  @param Item Independent byte-backed value
   --  @return Scalar value loaded from Item
   function Value_Of (Item : Value) return Interfaces.Unsigned_64;
   pragma Inline_Always (Value_Of);

   --  Write a scalar directly into unpublished storage for Element.
   --  @param Item Active unpublished builder
   --  @param Value Scalar value to write before publication
   --  @exclude
   procedure Set (Item : in out Representation.Builder; Value : Interfaces.Unsigned_64);

   --  Complete statically bound element contract for generic containers.
   package Element is new
     Flyology.Data_Structures.Storage_Types.Elements
       (Representation     => Representation,
        Source_Type        => Interfaces.Unsigned_64,
        Observed_Type      => Interfaces.Unsigned_64,
        Create_Value       => Create,
        Observe_Value      => Value_Of,
        Direct_Constructor => Set'Access);
end Flyology.Data_Structures.Storage_Types.Unsigned_64s;
