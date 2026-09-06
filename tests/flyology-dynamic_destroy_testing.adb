with Flyology.Dynamic_Destroy_Test_Hooks;

package body Flyology.Dynamic_Destroy_Testing is

   procedure Reset is
   begin
      Flyology.Dynamic_Destroy_Test_Hooks.Reset;
   end Reset;

   procedure Arm_Current_Release_Contention is
   begin
      Flyology.Dynamic_Destroy_Test_Hooks.Arm_Current_Release_Contention;
   end Arm_Current_Release_Contention;

end Flyology.Dynamic_Destroy_Testing;
