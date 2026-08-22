with Interfaces.C;

--  Enabled connection test seams selected by the owning project. Native test
--  controls widen narrowly identified ownership and readiness race windows.
private package Flyology.Connection_Test_Hooks is

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := True;

   procedure Barrier (Point : Interfaces.C.int);
   procedure One_Shot_Barrier (Point : Interfaces.C.int);
   function Receive_Limit (Requested : Interfaces.C.int) return Interfaces.C.int;
   procedure Raw_Accept_Return_Barrier;
   function Fail_Next_Capacity_Release_Wake return Boolean;

end Flyology.Connection_Test_Hooks;
