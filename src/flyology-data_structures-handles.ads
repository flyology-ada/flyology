with Interfaces;

--  Defines fixed-width generation-stamped handles. Handles contain no native
--  address or Ada access value. They are untrusted scalar input: the owning
--  structure must validate both fields before every use. This package is
--  purely representational and provides no synchronization.
package Flyology.Data_Structures.Handles with Preelaborate is

   --  One-based stored slot index. Zero is reserved as the null sentinel.
   type Slot_Index is new Interfaces.Unsigned_32;

   --  Stored slot generation. Zero is reserved as invalid.
   type Generation is new Interfaces.Unsigned_32;

   --  Generation-stamped slot identity.
   --  @field Slot One-based slot index, or zero for null
   --  @field Stamp Nonzero generation observed when ownership was granted
   type Handle is record
      Slot  : Slot_Index := 0;
      Stamp : Generation := 0;
   end record
     with Convention => C,
          Size       => 64;
   for Handle use record
      Slot  at 0 range 0 .. 31;
      Stamp at 4 range 0 .. 31;
   end record;

   --  Null handle accepted only where a leaf package explicitly says so.
   Null_Handle : constant Handle := (Slot => 0, Stamp => 0);

   --  Report whether Value carries the canonical null representation.
   --  @param Value Handle to inspect
   --  @return True only when both scalar fields are zero
   function Is_Null (Value : Handle) return Boolean is
     (Value = Null_Handle);

end Flyology.Data_Structures.Handles;
