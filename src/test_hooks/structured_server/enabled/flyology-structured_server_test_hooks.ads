with Interfaces.C;

--  Enabled structured-server test control selected by the owning project.

private package Flyology.Structured_Server_Test_Hooks is
   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := True;

   procedure Barrier (Point : Interfaces.C.int);
   function Check_Activation return Boolean;
end Flyology.Structured_Server_Test_Hooks;
