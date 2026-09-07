with Flyology.Adaptive_Pool_Test_Hooks;

package body Flyology.Adaptive_Pool_Testing is

   procedure Reset is
   begin
      Flyology.Adaptive_Pool_Test_Hooks.Reset;
   end Reset;

   procedure Arm_Release_Contention (After_Releases : Natural := 0) is
   begin
      Flyology.Adaptive_Pool_Test_Hooks.Arm_Release_Contention
        (After_Releases);
   end Arm_Release_Contention;

end Flyology.Adaptive_Pool_Testing;
