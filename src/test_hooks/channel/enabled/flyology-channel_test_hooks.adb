package body Flyology.Channel_Test_Hooks is

   Armed                             : Boolean := False
   with Atomic;
   Arrived                           : Boolean := False
   with Atomic;
   Buffer_Commit_Armed               : Boolean := False
   with Atomic;
   Buffer_Commit_Arrived             : Boolean := False
   with Atomic;
   Signal_Claim_Armed                : Boolean := False
   with Atomic;
   Signal_Claim_Arrived              : Boolean := False
   with Atomic;
   Signal_Claim_Released             : Boolean := False
   with Atomic;
   Buffer_Signal_Failure             : Boolean := False
   with Atomic;
   Bounded_Signal_Interrupt          : Boolean := False
   with Atomic;
   Bounded_Signal_Interrupt_Was_Used : Boolean := False
   with Atomic;
   Bounded_Signal_Failure            : Boolean := False
   with Atomic;
   Bounded_Signal_Failure_Was_Used   : Boolean := False
   with Atomic;
   Bounded_Failure_Ack_Armed         : Boolean := False
   with Atomic;
   Bounded_Failure_Ack_Arrived       : Boolean := False
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
      Bounded_Signal_Interrupt := False;
      Bounded_Signal_Interrupt_Was_Used := False;
      Bounded_Signal_Failure := False;
      Bounded_Signal_Failure_Was_Used := False;
      Bounded_Failure_Ack_Armed := False;
      Bounded_Failure_Ack_Arrived := False;
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

   procedure Arm_Next_Bounded_Signal_Interrupt is
   begin
      Bounded_Signal_Interrupt_Was_Used := False;
      Bounded_Signal_Interrupt := True;
   end Arm_Next_Bounded_Signal_Interrupt;

   function Take_Bounded_Signal_Interrupt return Boolean is
   begin
      if Bounded_Signal_Interrupt then
         Bounded_Signal_Interrupt := False;
         Bounded_Signal_Interrupt_Was_Used := True;
         return True;
      end if;
      return False;
   end Take_Bounded_Signal_Interrupt;

   function Bounded_Signal_Interrupt_Observed return Boolean
   is (Bounded_Signal_Interrupt_Was_Used);

   procedure Arm_Next_Bounded_Signal_Failure is
   begin
      Bounded_Signal_Failure_Was_Used := False;
      Bounded_Signal_Failure := True;
   end Arm_Next_Bounded_Signal_Failure;

   function Take_Bounded_Signal_Failure return Boolean is
   begin
      if Bounded_Signal_Failure then
         Bounded_Signal_Failure := False;
         Bounded_Signal_Failure_Was_Used := True;
         return True;
      end if;
      return False;
   end Take_Bounded_Signal_Failure;

   function Bounded_Signal_Failure_Observed return Boolean
   is (Bounded_Signal_Failure_Was_Used);

   procedure Arm_After_Bounded_Failure_Ack is
   begin
      Bounded_Failure_Ack_Arrived := False;
      Bounded_Failure_Ack_Armed := True;
   end Arm_After_Bounded_Failure_Ack;

   procedure After_Bounded_Failure_Ack_Barrier is
   begin
      if Bounded_Failure_Ack_Armed then
         Bounded_Failure_Ack_Arrived := True;
         while Bounded_Failure_Ack_Armed loop
            delay 0.0;
         end loop;
      end if;
   end After_Bounded_Failure_Ack_Barrier;

   function Bounded_Failure_Ack_Reached return Boolean
   is (Bounded_Failure_Ack_Arrived);

   procedure Release_After_Bounded_Failure_Ack is
   begin
      Bounded_Failure_Ack_Armed := False;
   end Release_After_Bounded_Failure_Ack;

end Flyology.Channel_Test_Hooks;
