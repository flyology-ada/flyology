with Fault_Control;
with Flyology;
with Interfaces.C;

procedure Reap_Finalize_Race_Smoke is
   package C renames Interfaces.C;

   use type C.int;

   function Arm_Final_Reap_Exit_Check return C.int;
   pragma Import
     (C,
      Arm_Final_Reap_Exit_Check,
      "flyology_test_arm_final_reap_exit_check");

   task type Finisher is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Finisher;

   task body Finisher is
   begin
      null;
   end Finisher;

begin
   if not Fault_Control.Enabled then
      raise Program_Error with
        "final-reap race test requires FLYOLOGY_TEST_FAULTS=1 runtime";
   end if;
   if Arm_Final_Reap_Exit_Check /= 0 then
      raise Program_Error with "cannot register final-reap exit check";
   end if;

   Fault_Control.Reset;
   Fault_Control.Arm (Fault_Control.Final_Reap_Window, Count => 2);
   declare
      Item : Finisher;
      pragma Unreferenced (Item);
   begin
      null;
   end;
   --  Leaving the block makes the environment task wait on Finisher's master
   --  and finalize its TCB. The wrapper wakes that master immediately before
   --  the scheduler enters the injected final-reap window, so returning from
   --  the main subprogram races finalization with the in-flight reaper.
end Reap_Finalize_Race_Smoke;
