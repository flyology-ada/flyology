with Flyology.Data_Structures.Storage_Types.Immutable;
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

   --  Read-only reference supplied by a container callback.
   subtype Const_Ref is Representation.Const_Ref;

   --  Unpublished builder supplied by an emplacement callback.
   subtype Builder is Representation.Builder;

   --  Construct one independent immutable value.
   --  @param Item Scalar value to store
   --  @return Byte-backed immutable value
   function Create (Item : Interfaces.Unsigned_64) return Value;

   --  Read one published value without copying its backing bytes.
   --  @param Item Active read-only container reference
   --  @return Scalar value loaded from the referenced bytes
   function Value_Of (Item : Const_Ref) return Interfaces.Unsigned_64;

   --  Read an independent immutable value.
   --  @param Item Independent byte-backed value
   --  @return Scalar value loaded from Item
   function Value_Of (Item : Value) return Interfaces.Unsigned_64;

   --  Initialize an unpublished container slot.
   --  @param Item Active emplacement builder
   --  @param Value Scalar value to store before publication
   procedure Set
     (Item : in out Builder; Value : Interfaces.Unsigned_64);
end Flyology.Data_Structures.Storage_Types.Unsigned_64s;
