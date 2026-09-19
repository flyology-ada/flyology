--  Exposes deterministic channel fault points to runtime tests.
--  Applications should not depend on this child package.
--  @exclude

package Flyology.Channel_Testing is

   procedure Reset;
   procedure Arm_Before_Send;
   procedure Wait_Before_Send;
   procedure Release_Before_Send;

   procedure Arm_After_Buffer_Commit;
   procedure Wait_After_Buffer_Commit;
   procedure Release_After_Buffer_Commit;

   procedure Arm_After_Signal_Claim;
   procedure Wait_After_Signal_Claim;
   function Signal_Claim_Was_Released return Boolean;
   procedure Release_After_Signal_Claim;

   procedure Arm_Next_Buffer_Signal_Failure;

   procedure Arm_Next_Bounded_Signal_Interrupt;
   function Bounded_Signal_Interrupt_Observed return Boolean;
   procedure Arm_Next_Bounded_Signal_Failure;
   function Bounded_Signal_Failure_Observed return Boolean;
   procedure Arm_After_Bounded_Failure_Ack;
   procedure Wait_After_Bounded_Failure_Ack;
   procedure Release_After_Bounded_Failure_Ack;

end Flyology.Channel_Testing;
