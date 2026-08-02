with Ada.Finalization;
with Interfaces.C;

package Gnatevl.Wake_Sources is
   pragma Preelaborate;

   type Source is new Ada.Finalization.Limited_Controlled with private;

   --  These operations are intentionally unsynchronized: a Source is owned
   --  by a protected object, which serializes initialization and signalling.
   procedure Ensure (Item : in out Source);
   procedure Signal (Item : in out Source);
   function Descriptor (Item : Source) return Interfaces.C.int;

private
   type Source is new Ada.Finalization.Limited_Controlled with record
      Read_End  : Interfaces.C.int := Interfaces.C.int (-1);
      Write_End : Interfaces.C.int := Interfaces.C.int (-1);
   end record;

   overriding procedure Finalize (Item : in out Source);
end Gnatevl.Wake_Sources;
