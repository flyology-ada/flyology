--  Disabled subprocess test seams selected by the owning project. The
--  imported-only declaration makes a missed static guard visible to symbol
--  inspection without supplying any production implementation.
private package Flyology.Subprocess_Test_Hooks is

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := False;

   function Fail_Reaper_Allocation return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_subprocess_reaper";

end Flyology.Subprocess_Test_Hooks;
