package body Flyology.Buffer_Test_Hooks is

   protected State is
      procedure Arm_Acquisition;
      procedure Consume_Acquisition (Armed : out Boolean);
      procedure Arm_Allocation_Failure (After_Successful_Allocations : Natural);
      procedure Consume_Allocation_Failure (Fail : out Boolean);
      procedure Note_Allocated;
      procedure Note_Freed;
      function Live_Pools return Natural;
      procedure Arm_Transfer_Failure;
      procedure Consume_Transfer_Failure (Fail : out Boolean);
      procedure Arm_Transfer_Post_Commit_Failure;
      procedure Consume_Transfer_Post_Commit_Failure (Fail : out Boolean);
      procedure Arm_Release_Failure;
      procedure Consume_Release_Failure (Fail : out Boolean);
      procedure Arm_Release_Post_Commit_Failure;
      procedure Consume_Release_Post_Commit_Failure (Fail : out Boolean);
      procedure Arm_Acquisition_Pre_Commit_Failure;
      procedure Consume_Acquisition_Pre_Commit_Failure (Fail : out Boolean);
      procedure Arm_Acquisition_Post_Commit_Failure;
      procedure Consume_Acquisition_Post_Commit_Failure (Fail : out Boolean);
   private
      Acquisition_Armed          : Boolean := False;
      Allocation_Failure_Armed   : Boolean := False;
      Allocations_Before_Failure : Natural := 0;
      Domain_Pools_Live          : Natural := 0;
      Transfer_Failure_Armed     : Boolean := False;
      Transfer_Post_Commit_Armed : Boolean := False;
      Release_Failure_Armed      : Boolean := False;
      Release_Post_Commit_Armed  : Boolean := False;
      Acquisition_Pre_Armed      : Boolean := False;
      Acquisition_Post_Armed     : Boolean := False;
   end State;

   protected body State is
      procedure Arm_Acquisition is
      begin
         Acquisition_Armed := True;
      end Arm_Acquisition;

      procedure Consume_Acquisition (Armed : out Boolean) is
      begin
         Armed := Acquisition_Armed;
         Acquisition_Armed := False;
      end Consume_Acquisition;

      procedure Arm_Allocation_Failure (After_Successful_Allocations : Natural) is
      begin
         Allocation_Failure_Armed := True;
         Allocations_Before_Failure := After_Successful_Allocations;
      end Arm_Allocation_Failure;

      procedure Consume_Allocation_Failure (Fail : out Boolean) is
      begin
         Fail := Allocation_Failure_Armed and then Allocations_Before_Failure = 0;
         if Fail then
            Allocation_Failure_Armed := False;
         elsif Allocation_Failure_Armed then
            Allocations_Before_Failure := Allocations_Before_Failure - 1;
         end if;
      end Consume_Allocation_Failure;

      procedure Note_Allocated is
      begin
         Domain_Pools_Live := Domain_Pools_Live + 1;
      end Note_Allocated;

      procedure Note_Freed is
      begin
         if Domain_Pools_Live = 0 then
            raise Program_Error with "buffer domain pool test count underflow";
         end if;
         Domain_Pools_Live := Domain_Pools_Live - 1;
      end Note_Freed;

      function Live_Pools return Natural
      is (Domain_Pools_Live);

      procedure Arm_Transfer_Failure is
      begin
         Transfer_Failure_Armed := True;
      end Arm_Transfer_Failure;

      procedure Consume_Transfer_Failure (Fail : out Boolean) is
      begin
         Fail := Transfer_Failure_Armed;
         Transfer_Failure_Armed := False;
      end Consume_Transfer_Failure;

      procedure Arm_Transfer_Post_Commit_Failure is
      begin
         Transfer_Post_Commit_Armed := True;
      end Arm_Transfer_Post_Commit_Failure;

      procedure Consume_Transfer_Post_Commit_Failure (Fail : out Boolean) is
      begin
         Fail := Transfer_Post_Commit_Armed;
         Transfer_Post_Commit_Armed := False;
      end Consume_Transfer_Post_Commit_Failure;

      procedure Arm_Release_Failure is
      begin
         Release_Failure_Armed := True;
      end Arm_Release_Failure;

      procedure Consume_Release_Failure (Fail : out Boolean) is
      begin
         Fail := Release_Failure_Armed;
         Release_Failure_Armed := False;
      end Consume_Release_Failure;

      procedure Arm_Release_Post_Commit_Failure is
      begin
         Release_Post_Commit_Armed := True;
      end Arm_Release_Post_Commit_Failure;

      procedure Consume_Release_Post_Commit_Failure (Fail : out Boolean) is
      begin
         Fail := Release_Post_Commit_Armed;
         Release_Post_Commit_Armed := False;
      end Consume_Release_Post_Commit_Failure;

      procedure Arm_Acquisition_Pre_Commit_Failure is
      begin
         Acquisition_Pre_Armed := True;
      end Arm_Acquisition_Pre_Commit_Failure;

      procedure Consume_Acquisition_Pre_Commit_Failure (Fail : out Boolean) is
      begin
         Fail := Acquisition_Pre_Armed;
         Acquisition_Pre_Armed := False;
      end Consume_Acquisition_Pre_Commit_Failure;

      procedure Arm_Acquisition_Post_Commit_Failure is
      begin
         Acquisition_Post_Armed := True;
      end Arm_Acquisition_Post_Commit_Failure;

      procedure Consume_Acquisition_Post_Commit_Failure (Fail : out Boolean) is
      begin
         Fail := Acquisition_Post_Armed;
         Acquisition_Post_Armed := False;
      end Consume_Acquisition_Post_Commit_Failure;
   end State;

   procedure Arm_Next_Acquisition_Near_Exhaustion is
   begin
      State.Arm_Acquisition;
   end Arm_Next_Acquisition_Near_Exhaustion;

   function Consume_Next_Acquisition_Near_Exhaustion return Boolean is
      Armed : Boolean;
   begin
      State.Consume_Acquisition (Armed);
      return Armed;
   end Consume_Next_Acquisition_Near_Exhaustion;

   procedure Arm_Domain_Allocation_Failure (After_Successful_Allocations : Natural) is
   begin
      State.Arm_Allocation_Failure (After_Successful_Allocations);
   end Arm_Domain_Allocation_Failure;

   function Consume_Domain_Allocation_Failure return Boolean is
      Fail : Boolean;
   begin
      State.Consume_Allocation_Failure (Fail);
      return Fail;
   end Consume_Domain_Allocation_Failure;

   procedure Note_Domain_Pool_Allocated is
   begin
      State.Note_Allocated;
   end Note_Domain_Pool_Allocated;

   procedure Note_Domain_Pool_Freed is
   begin
      State.Note_Freed;
   end Note_Domain_Pool_Freed;

   function Live_Domain_Pools return Natural
   is (State.Live_Pools);

   procedure Arm_Next_Domain_Transfer_Failure is
   begin
      State.Arm_Transfer_Failure;
   end Arm_Next_Domain_Transfer_Failure;

   function Consume_Next_Domain_Transfer_Failure return Boolean is
      Fail : Boolean;
   begin
      State.Consume_Transfer_Failure (Fail);
      return Fail;
   end Consume_Next_Domain_Transfer_Failure;

   procedure Arm_Next_Domain_Transfer_Post_Commit_Failure is
   begin
      State.Arm_Transfer_Post_Commit_Failure;
   end Arm_Next_Domain_Transfer_Post_Commit_Failure;

   function Consume_Next_Domain_Transfer_Post_Commit_Failure return Boolean is
      Fail : Boolean;
   begin
      State.Consume_Transfer_Post_Commit_Failure (Fail);
      return Fail;
   end Consume_Next_Domain_Transfer_Post_Commit_Failure;

   procedure Arm_Next_Domain_Release_Failure is
   begin
      State.Arm_Release_Failure;
   end Arm_Next_Domain_Release_Failure;

   function Consume_Next_Domain_Release_Failure return Boolean is
      Fail : Boolean;
   begin
      State.Consume_Release_Failure (Fail);
      return Fail;
   end Consume_Next_Domain_Release_Failure;

   procedure Arm_Next_Domain_Release_Post_Commit_Failure is
   begin
      State.Arm_Release_Post_Commit_Failure;
   end Arm_Next_Domain_Release_Post_Commit_Failure;

   function Consume_Next_Domain_Release_Post_Commit_Failure return Boolean is
      Fail : Boolean;
   begin
      State.Consume_Release_Post_Commit_Failure (Fail);
      return Fail;
   end Consume_Next_Domain_Release_Post_Commit_Failure;

   procedure Arm_Next_Domain_Acquisition_Pre_Commit_Failure is
   begin
      State.Arm_Acquisition_Pre_Commit_Failure;
   end Arm_Next_Domain_Acquisition_Pre_Commit_Failure;

   function Consume_Next_Domain_Acquisition_Pre_Commit_Failure return Boolean is
      Fail : Boolean;
   begin
      State.Consume_Acquisition_Pre_Commit_Failure (Fail);
      return Fail;
   end Consume_Next_Domain_Acquisition_Pre_Commit_Failure;

   procedure Arm_Next_Domain_Acquisition_Post_Commit_Failure is
   begin
      State.Arm_Acquisition_Post_Commit_Failure;
   end Arm_Next_Domain_Acquisition_Post_Commit_Failure;

   function Consume_Next_Domain_Acquisition_Post_Commit_Failure return Boolean is
      Fail : Boolean;
   begin
      State.Consume_Acquisition_Post_Commit_Failure (Fail);
      return Fail;
   end Consume_Next_Domain_Acquisition_Post_Commit_Failure;

end Flyology.Buffer_Test_Hooks;
