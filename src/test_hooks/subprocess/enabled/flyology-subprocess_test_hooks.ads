--  Enabled subprocess test seams selected by the owning project.
private package Flyology.Subprocess_Test_Hooks is

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := True;

   function Fail_Reaper_Allocation return Boolean;

end Flyology.Subprocess_Test_Hooks;
