--  Enabled channel test control selected by the owning project.

private package Flyology.Channel_Test_Hooks is
   pragma Preelaborate;

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := True;

   procedure Reset;
   procedure Arm_Before_Send;
   procedure Before_Send_Barrier;
   function Before_Send_Reached return Boolean;
   procedure Release_Before_Send;

   procedure Arm_After_Buffer_Commit;
   procedure After_Buffer_Commit_Barrier;
   function Buffer_Commit_Reached return Boolean;
   procedure Release_After_Buffer_Commit;

   procedure Arm_After_Signal_Claim;
   procedure After_Signal_Claim_Barrier;
   function Signal_Claim_Reached return Boolean;
   function Signal_Claim_Was_Released return Boolean;
   procedure Release_After_Signal_Claim;

   procedure Arm_Next_Buffer_Signal_Failure;
   function Fail_Next_Buffer_Signal return Boolean;

   procedure Arm_Next_Bounded_Signal_Interrupt;
   function Take_Bounded_Signal_Interrupt return Boolean;
   function Bounded_Signal_Interrupt_Observed return Boolean;
   procedure Arm_Next_Bounded_Signal_Failure;
   function Take_Bounded_Signal_Failure return Boolean;
   function Bounded_Signal_Failure_Observed return Boolean;
   procedure Arm_After_Bounded_Failure_Ack;
   procedure After_Bounded_Failure_Ack_Barrier;
   function Bounded_Failure_Ack_Reached return Boolean;
   procedure Release_After_Bounded_Failure_Ack;

end Flyology.Channel_Test_Hooks;
