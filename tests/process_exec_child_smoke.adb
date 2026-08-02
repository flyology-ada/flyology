with Gnatevl.Process_Lifecycle;
with Interfaces.C;

procedure Process_Exec_Child_Smoke is
   package C renames Interfaces.C;
   package Lifecycle renames Gnatevl.Process_Lifecycle;

   use type C.int;
   use type Lifecycle.Event_Runtime_State;

   function Arm_Exit_Check (State, Groups : C.int) return C.int;
   pragma Import
     (C, Arm_Exit_Check, "gnatevl_test_arm_exit_check");

   task Native_Activation;
   task body Native_Activation is
   begin
      null;
   end Native_Activation;
begin
   if Lifecycle.State /= Lifecycle.Dormant
     or else Lifecycle.Created_Groups /= 0
     or else Arm_Exit_Check (3, 0) /= 0
   then
      raise Program_Error with "exec did not create a fresh runtime";
   end if;
end Process_Exec_Child_Smoke;
