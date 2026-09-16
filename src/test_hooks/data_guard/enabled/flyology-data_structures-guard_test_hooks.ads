with Flyology.Data_Structures.Layouts;
with System;

--  Owner-stack observation at the actual successful guard CAS boundary.
--  The test installs an observer while all callers are quiescent, and keeps
--  its storage alive until every observed call has completed.

private package Flyology.Data_Structures.Guard_Test_Hooks
  with Preelaborate
is
   --  Literal Enabled : constant Boolean := True; statically selected by GPR.
   Enabled : constant Boolean := True;
   type Observer is access procedure (Core : Layouts.Local_View; Guard : System.Address);
   procedure Reset;
   procedure Set_Observer (Value : Observer);
   procedure After_CAS (Core : Layouts.Local_View; Guard : System.Address);
end Flyology.Data_Structures.Guard_Test_Hooks;
