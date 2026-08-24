with Flyology.Buffer_Test_Hooks;

package body Flyology.Buffers.Domains.Testing is

   procedure Arm_Allocation_Failure (After_Successful_Allocations : Natural) is
   begin
      Flyology.Buffer_Test_Hooks.Arm_Domain_Allocation_Failure (After_Successful_Allocations);
   end Arm_Allocation_Failure;

   function Live_Pools return Natural
   is (Flyology.Buffer_Test_Hooks.Live_Domain_Pools);

   procedure Arm_Next_Transfer_Failure is
   begin
      Flyology.Buffer_Test_Hooks.Arm_Next_Domain_Transfer_Failure;
   end Arm_Next_Transfer_Failure;

   procedure Arm_Next_Transfer_Post_Commit_Failure is
   begin
      Flyology.Buffer_Test_Hooks.Arm_Next_Domain_Transfer_Post_Commit_Failure;
   end Arm_Next_Transfer_Post_Commit_Failure;

   procedure Arm_Next_Release_Failure is
   begin
      Flyology.Buffer_Test_Hooks.Arm_Next_Domain_Release_Failure;
   end Arm_Next_Release_Failure;

   procedure Arm_Next_Release_Post_Commit_Failure is
   begin
      Flyology.Buffer_Test_Hooks.Arm_Next_Domain_Release_Post_Commit_Failure;
   end Arm_Next_Release_Post_Commit_Failure;

   procedure Arm_Next_Acquisition_Pre_Commit_Failure is
   begin
      Flyology.Buffer_Test_Hooks.Arm_Next_Domain_Acquisition_Pre_Commit_Failure;
   end Arm_Next_Acquisition_Pre_Commit_Failure;

   procedure Arm_Next_Acquisition_Post_Commit_Failure is
   begin
      Flyology.Buffer_Test_Hooks.Arm_Next_Domain_Acquisition_Post_Commit_Failure;
   end Arm_Next_Acquisition_Post_Commit_Failure;

end Flyology.Buffers.Domains.Testing;
