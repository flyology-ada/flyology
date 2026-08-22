with Interfaces.C;

--  Test-only structured-server control compiled with Flyology's own switches.
--  The disabled implementation has no native imports or observable effects.

private package Flyology.Structured_Server_Test_Hooks is
   procedure Barrier (Point : Interfaces.C.int);
   function Check_Activation return Boolean;
end Flyology.Structured_Server_Test_Hooks;
