package body Flyology.Memory_Operations is
   use type Interfaces.C.int;

   function C_Copy
     (Target : System.Address; Source : System.Address; Length : Interfaces.C.size_t) return System.Address;
   pragma Import (C, C_Copy, "memcpy");
   function C_Equal
     (Left : System.Address; Right : System.Address; Length : Interfaces.C.size_t) return Interfaces.C.int;
   pragma Import (C, C_Equal, "memcmp");
   function C_Zero
     (Target : System.Address; Value : Interfaces.C.int; Length : Interfaces.C.size_t) return System.Address;
   pragma Import (C, C_Zero, "memset");

   procedure Copy (Target : System.Address; Source : System.Address; Length : Interfaces.C.size_t) is
      Ignored : constant System.Address := C_Copy (Target, Source, Length);
      pragma Unreferenced (Ignored);
   begin
      null;
   end Copy;

   function Equal (Left : System.Address; Right : System.Address; Length : Interfaces.C.size_t) return Boolean
   is (C_Equal (Left, Right, Length) = 0);

   procedure Zero (Target : System.Address; Length : Interfaces.C.size_t) is
      Ignored : constant System.Address := C_Zero (Target, 0, Length);
      pragma Unreferenced (Ignored);
   begin
      null;
   end Zero;
end Flyology.Memory_Operations;
