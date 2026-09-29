with System;

generic
   type Element_Type is private;
package Flyology_Cachelines.Padded is

   --  Wraps a value in an independently spaced storage object.
   --  @formal Element_Type The definite type to store.

   pragma Warnings (Off, "suspiciously large alignment specified for ""Padded""");

   --  A value isolated by the destructive-interference spacing policy.
   --
   --  Padded controls storage placement only.  It does not make access to
   --  Value atomic, synchronized, or safe between tasks.  Callers must use
   --  the same synchronization that Element_Type would otherwise require.
   --
   --  Every object starts on a destructive-interference boundary, and its
   --  object size is rounded up by GNAT to a whole number of such boundaries.
   --  Consequently, adjacent values in arrays cannot falsely share a boundary.
   --  @field Value The wrapped value. Access requires the same synchronization
   --  as direct access to Element_Type.
   type Padded is record
      Value : Element_Type;
   end record
   with Alignment => Destructive_Interference_Size;
   pragma Warnings (On, "suspiciously large alignment specified for ""Padded""");

   --  Object size of Padded in System.Storage_Unit elements.
   Padded_Size_In_Storage_Elements : constant Positive := Padded'Object_Size / System.Storage_Unit;

   --  Wrap a value in padded storage.
   --  @param Value The value to wrap.
   --  @return A padded object containing Value.
   function Create (Value : Element_Type) return Padded
   is ((Value => Value));

   --  Extract the value from padded storage.
   --  @param Item The padded object to read.
   --  @return The contained value.
   function Unwrap (Item : Padded) return Element_Type
   is (Item.Value);

end Flyology_Cachelines.Padded;
