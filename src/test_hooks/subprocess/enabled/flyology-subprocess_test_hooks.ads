with Interfaces.C;

--  Enabled subprocess test seams selected by the owning project.

private package Flyology.Subprocess_Test_Hooks is

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := True;

   function Fail_Reaper_Allocation return Boolean;

   procedure After_Reap;
   procedure Note_Group_Signal;

   procedure Arm_Reap_Barrier;
   pragma Export (C, Arm_Reap_Barrier, "flyology_test_subprocess_arm_reap_barrier");
   procedure Await_Reap_Barrier;
   pragma Export (C, Await_Reap_Barrier, "flyology_test_subprocess_await_reap_barrier");
   procedure Release_Reap_Barrier;
   pragma Export (C, Release_Reap_Barrier, "flyology_test_subprocess_release_reap_barrier");
   function Group_Signal_Count return Interfaces.C.int;
   pragma Export (C, Group_Signal_Count, "flyology_test_subprocess_group_signal_count");

end Flyology.Subprocess_Test_Hooks;
