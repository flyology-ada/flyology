--  Enabled buffer test seams selected by the owning project.
private package Flyology.Buffer_Test_Hooks is

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := True;

   procedure Arm_Next_Acquisition_Near_Exhaustion;

   function Consume_Next_Acquisition_Near_Exhaustion return Boolean;

end Flyology.Buffer_Test_Hooks;
