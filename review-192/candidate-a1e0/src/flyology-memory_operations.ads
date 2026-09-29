with Interfaces.C;
with System;

--  Private direct imports for representation-neutral byte operations.

private package Flyology.Memory_Operations
  with Preelaborate
is
   procedure Copy (Target : System.Address; Source : System.Address; Length : Interfaces.C.size_t);
   function Equal
     (Left : System.Address; Right : System.Address; Length : Interfaces.C.size_t) return Boolean;
   procedure Zero (Target : System.Address; Length : Interfaces.C.size_t);
end Flyology.Memory_Operations;
