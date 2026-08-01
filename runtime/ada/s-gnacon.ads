with Interfaces.C;

package System.Gnatevl.Contexts is
   pragma Preelaborate;

   type Context is limited private;
   type Context_Access is access all Context;

   function Capture return Context_Access;

   function Create
     (Stack_Size : Interfaces.C.size_t;
      Start      : System.Address;
      Argument   : System.Address;
      Return_To  : Context_Access) return Context_Access;

   procedure Switch (From, To : not null Context_Access);
   procedure Destroy (Item : in out Context_Access);

   function Stack_Base (Item : Context_Access) return System.Address;
   function Stack_Size (Item : Context_Access) return Interfaces.C.size_t;

private
   type Register_Array is
     array (Natural range 0 .. 21) of Interfaces.C.unsigned_long;
   pragma Convention (C, Register_Array);

   type Context is limited record
      Registers   : aliased Register_Array := (others => 0);
      Mapping     : System.Address := System.Null_Address;
      Mapping_Size : Interfaces.C.size_t := 0;
      Stack       : System.Address := System.Null_Address;
      Size         : Interfaces.C.size_t := 0;
      Start        : System.Address := System.Null_Address;
      Argument     : System.Address := System.Null_Address;
      Return_To    : Context_Access := null;
      Owns_Mapping : Boolean := False;
   end record;
end System.Gnatevl.Contexts;
