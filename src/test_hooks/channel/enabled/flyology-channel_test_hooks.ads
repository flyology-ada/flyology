--  Enabled channel test control selected by the owning project.

private package Flyology.Channel_Test_Hooks is
   pragma Preelaborate;

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := True;

   procedure Reset;
   procedure Arm_Before_Send;
   procedure Before_Send_Barrier;
   function Before_Send_Reached return Boolean;
   procedure Release_Before_Send;

end Flyology.Channel_Test_Hooks;
