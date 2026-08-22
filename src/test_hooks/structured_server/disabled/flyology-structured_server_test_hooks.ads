with Interfaces.C;

--  Disabled structured-server test seams selected by the owning project. The
--  imported-only declarations make a missed static guard visible to symbol
--  inspection without supplying any production implementation.
private package Flyology.Structured_Server_Test_Hooks is

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := False;

   procedure Barrier (Point : Interfaces.C.int)
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_structured_server_barrier";
   function Check_Activation return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_structured_server_activation";

end Flyology.Structured_Server_Test_Hooks;
