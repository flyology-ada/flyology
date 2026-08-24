--  Enabled buffer test seams selected by the owning project.
private package Flyology.Buffer_Test_Hooks is

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := True;

   procedure Arm_Next_Acquisition_Near_Exhaustion;

   function Consume_Next_Acquisition_Near_Exhaustion return Boolean;

   procedure Arm_Domain_Allocation_Failure (After_Successful_Allocations : Natural);

   function Consume_Domain_Allocation_Failure return Boolean;

   procedure Note_Domain_Pool_Allocated;

   procedure Note_Domain_Pool_Freed;

   function Live_Domain_Pools return Natural;

   procedure Arm_Next_Domain_Transfer_Failure;

   function Consume_Next_Domain_Transfer_Failure return Boolean;

   procedure Arm_Next_Domain_Transfer_Post_Commit_Failure;

   function Consume_Next_Domain_Transfer_Post_Commit_Failure return Boolean;

   procedure Arm_Next_Domain_Release_Failure;

   function Consume_Next_Domain_Release_Failure return Boolean;

   procedure Arm_Next_Domain_Release_Post_Commit_Failure;

   function Consume_Next_Domain_Release_Post_Commit_Failure return Boolean;

   procedure Arm_Next_Domain_Acquisition_Pre_Commit_Failure;

   function Consume_Next_Domain_Acquisition_Pre_Commit_Failure return Boolean;

   procedure Arm_Next_Domain_Acquisition_Post_Commit_Failure;

   function Consume_Next_Domain_Acquisition_Post_Commit_Failure return Boolean;

   procedure Arm_Next_Domain_Reservation_Final_Generation;

   function Consume_Next_Domain_Reservation_Final_Generation return Boolean;

   procedure Arm_Next_Domain_Reservation_Publication_Failure;

   function Consume_Next_Domain_Reservation_Publication_Failure return Boolean;

   procedure Arm_Next_Domain_Release_Claim_Gap_Failure;

   function Consume_Next_Domain_Release_Claim_Gap_Failure return Boolean;

   procedure Arm_Next_Domain_Prepare_Release_Publication_Failure;

   function Consume_Next_Domain_Prepare_Release_Publication_Failure return Boolean;

   procedure Arm_Next_Domain_Acknowledge_Post_Commit_Failure;

   function Consume_Next_Domain_Acknowledge_Post_Commit_Failure return Boolean;

end Flyology.Buffer_Test_Hooks;
