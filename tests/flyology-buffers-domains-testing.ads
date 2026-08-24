package Flyology.Buffers.Domains.Testing is

   procedure Arm_Allocation_Failure (After_Successful_Allocations : Natural);

   function Live_Pools return Natural;

   procedure Arm_Next_Transfer_Failure;

   procedure Arm_Next_Transfer_Post_Commit_Failure;

   procedure Arm_Next_Release_Failure;

   procedure Arm_Next_Release_Post_Commit_Failure;

   procedure Arm_Next_Acquisition_Pre_Commit_Failure;

   procedure Arm_Next_Acquisition_Post_Commit_Failure;

end Flyology.Buffers.Domains.Testing;
