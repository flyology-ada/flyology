--  Enabled file-watch fault checks selected by the owning project.

private package Flyology.File_Watch_Test_Hooks is
   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := True;

   function Consume_Events_Lost return Boolean;
   function Consume_Remove_Failure return Boolean;
   function Consume_Close_Failure return Boolean;
end Flyology.File_Watch_Test_Hooks;
