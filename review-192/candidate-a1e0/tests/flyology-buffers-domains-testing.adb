with Flyology.Buffer_Test_Hooks;
with Interfaces;

package body Flyology.Buffers.Domains.Testing is
   use type Interfaces.Unsigned_64;

   function Next_Reservation (Reservation : Pool_Reservation) return Pool_Reservation is
   begin
      if not Is_Valid (Reservation)
        or else Reservation.Generation = Reservation_Generation'Last
      then
         raise Constraint_Error with "reservation has no test successor";
      end if;
      return
        (Pool       => Reservation.Pool,
         Generation => Reservation.Generation + 1);
   end Next_Reservation;

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

   procedure Arm_Next_Reservation_Final_Generation is
   begin
      Flyology.Buffer_Test_Hooks.Arm_Next_Domain_Reservation_Final_Generation;
   end Arm_Next_Reservation_Final_Generation;

   procedure Arm_Next_Reservation_Publication_Failure is
   begin
      Flyology.Buffer_Test_Hooks.Arm_Next_Domain_Reservation_Publication_Failure;
   end Arm_Next_Reservation_Publication_Failure;

   procedure Arm_Next_Release_Claim_Gap_Failure is
   begin
      Flyology.Buffer_Test_Hooks.Arm_Next_Domain_Release_Claim_Gap_Failure;
   end Arm_Next_Release_Claim_Gap_Failure;

   procedure Arm_Next_Prepare_Release_Publication_Failure is
   begin
      Flyology.Buffer_Test_Hooks.Arm_Next_Domain_Prepare_Release_Publication_Failure;
   end Arm_Next_Prepare_Release_Publication_Failure;

   procedure Arm_Next_Acknowledge_Post_Commit_Failure is
   begin
      Flyology.Buffer_Test_Hooks.Arm_Next_Domain_Acknowledge_Post_Commit_Failure;
   end Arm_Next_Acknowledge_Post_Commit_Failure;

end Flyology.Buffers.Domains.Testing;
