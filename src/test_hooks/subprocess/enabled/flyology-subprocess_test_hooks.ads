with Interfaces.C;

--  Enabled subprocess test seams selected by the owning project.

private package Flyology.Subprocess_Test_Hooks is

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := True;

   function Fail_Reaper_Allocation return Boolean;
   procedure Set_Fail_Reaper_Allocation (Enabled : Interfaces.C.int);
   pragma Export (C, Set_Fail_Reaper_Allocation, "flyology_test_subprocess_set_fail_reaper_allocation");

   function Fail_Group_Signal return Boolean;
   procedure Set_Fail_Group_Signal (Enabled : Interfaces.C.int);
   pragma Export (C, Set_Fail_Group_Signal, "flyology_test_subprocess_set_fail_group_signal");

   procedure Note_Group_Signal;
   function Group_Signal_Count return Interfaces.C.int;
   pragma Export (C, Group_Signal_Count, "flyology_test_subprocess_group_signal_count");

end Flyology.Subprocess_Test_Hooks;
