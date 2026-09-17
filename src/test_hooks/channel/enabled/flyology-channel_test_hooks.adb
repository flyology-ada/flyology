package body Flyology.Channel_Test_Hooks is

   Armed                 : Boolean := False
   with Atomic;
   Arrived               : Boolean := False
   with Atomic;
   Buffer_Commit_Armed   : Boolean := False
   with Atomic;
   Buffer_Commit_Arrived : Boolean := False
   with Atomic;
   Signal_Claim_Armed    : Boolean := False
   with Atomic;
   Signal_Claim_Arrived  : Boolean := False
   with Atomic;
   Signal_Claim_Released : Boolean := False
   with Atomic;
   Buffer_Signal_Failure : Boolean := False
   with Atomic;

   procedure Reset is
   begin
      Armed := False;
      Arrived := False;
      Buffer_Commit_Armed := False;
      Buffer_Commit_Arrived := False;
      Signal_Claim_Armed := False;
      Signal_Claim_Arrived := False;
      Signal_Claim_Released := False;
      Buffer_Signal_Failure := False;
   end Reset;

   procedure Arm_Before_Send is
   begin
      Arrived := False;
      Armed := True;
   end Arm_Before_Send;

   procedure Before_Send_Barrier is
   begin
      if Armed then
         Arrived := True;
         while Armed loop
            delay 0.0;
         end loop;
      end if;
   end Before_Send_Barrier;

   function Before_Send_Reached return Boolean
   is (Arrived);

   procedure Release_Before_Send is
   begin
      Armed := False;
   end Release_Before_Send;

   procedure Arm_After_Buffer_Commit is
   begin
      Buffer_Commit_Arrived := False;
      Buffer_Commit_Armed := True;
   end Arm_After_Buffer_Commit;

   procedure After_Buffer_Commit_Barrier is
   begin
      if Buffer_Commit_Armed then
         Buffer_Commit_Arrived := True;
         while Buffer_Commit_Armed loop
            delay 0.0;
         end loop;
      end if;
   end After_Buffer_Commit_Barrier;

   function Buffer_Commit_Reached return Boolean
   is (Buffer_Commit_Arrived);

   procedure Release_After_Buffer_Commit is
   begin
      Buffer_Commit_Armed := False;
   end Release_After_Buffer_Commit;

   procedure Arm_After_Signal_Claim is
   begin
      Signal_Claim_Arrived := False;
      Signal_Claim_Released := False;
      Signal_Claim_Armed := True;
   end Arm_After_Signal_Claim;

   procedure After_Signal_Claim_Barrier is
   begin
      if Signal_Claim_Armed then
         Signal_Claim_Arrived := True;
         while Signal_Claim_Armed loop
            delay 0.0;
         end loop;
      end if;
   end After_Signal_Claim_Barrier;

   function Signal_Claim_Reached return Boolean
   is (Signal_Claim_Arrived);

   function Signal_Claim_Was_Released return Boolean
   is (Signal_Claim_Released);

   procedure Release_After_Signal_Claim is
   begin
      Signal_Claim_Released := True;
      Signal_Claim_Armed := False;
   end Release_After_Signal_Claim;

   procedure Arm_Next_Buffer_Signal_Failure is
   begin
      Buffer_Signal_Failure := True;
   end Arm_Next_Buffer_Signal_Failure;

   function Fail_Next_Buffer_Signal return Boolean is
   begin
      if Buffer_Signal_Failure then
         Buffer_Signal_Failure := False;
         return True;
      end if;
      return False;
   end Fail_Next_Buffer_Signal;

end Flyology.Channel_Test_Hooks;
