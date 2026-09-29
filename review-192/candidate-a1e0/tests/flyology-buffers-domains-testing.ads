package Flyology.Buffers.Domains.Testing is

   function Next_Reservation (Reservation : Pool_Reservation) return Pool_Reservation;

   procedure Arm_Allocation_Failure (After_Successful_Allocations : Natural);

   function Live_Pools return Natural;

   procedure Arm_Next_Transfer_Failure;

   procedure Arm_Next_Transfer_Post_Commit_Failure;

   procedure Arm_Next_Release_Failure;

   procedure Arm_Next_Release_Post_Commit_Failure;

   procedure Arm_Next_Acquisition_Pre_Commit_Failure;

   procedure Arm_Next_Acquisition_Post_Commit_Failure;

   --  The next successful reservation in this process uses the final
   --  generation. Tests must serialize reservation attempts while armed.
   procedure Arm_Next_Reservation_Final_Generation;

   procedure Arm_Next_Reservation_Publication_Failure;

   procedure Arm_Next_Release_Claim_Gap_Failure;

   procedure Arm_Next_Prepare_Release_Publication_Failure;

   procedure Arm_Next_Acknowledge_Post_Commit_Failure;

end Flyology.Buffers.Domains.Testing;
