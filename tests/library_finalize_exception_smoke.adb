with Flyology;
with Flyology.Process_Lifecycle;
with Interfaces.C;
with Library_Finalize_Exception_Fixture;

procedure Library_Finalize_Exception_Smoke is
   package C renames Interfaces.C;
   package Lifecycle renames Flyology.Process_Lifecycle;

   use type C.int;
   use type Lifecycle.Event_Runtime_State;

   task Starter
     with CPU => 1 is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Starter;

   task body Starter is
   begin
      null;
   end Starter;

   function Arm_Exit_Check (State, Groups : C.int) return C.int;
   pragma Import (C, Arm_Exit_Check, "flyology_test_arm_exit_check");

begin
   if Lifecycle.State /= Lifecycle.Running
     or else Lifecycle.Created_Groups /= 1
     or else Arm_Exit_Check (3, 0) /= 0
   then
      raise Program_Error with "exceptional-finalization precondition failed";
   end if;
   Library_Finalize_Exception_Fixture.Arm;
end Library_Finalize_Exception_Smoke;
