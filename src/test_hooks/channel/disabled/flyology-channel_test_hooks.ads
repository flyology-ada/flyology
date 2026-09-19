--  Disabled channel test seams selected by the owning project. The
--  imported-only declarations make a missed static guard visible to symbol
--  inspection without supplying any production implementation.

private package Flyology.Channel_Test_Hooks is
   pragma Preelaborate;

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := False;

   procedure Reset
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_reset";
   procedure Arm_Before_Send
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_arm";
   procedure Before_Send_Barrier
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_barrier";
   function Before_Send_Reached return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_reached";
   procedure Release_Before_Send
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_release";

   procedure Arm_After_Buffer_Commit
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_buffer_commit_arm";
   procedure After_Buffer_Commit_Barrier
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_buffer_commit_barrier";
   function Buffer_Commit_Reached return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_buffer_commit_reached";
   procedure Release_After_Buffer_Commit
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_buffer_commit_release";

   procedure Arm_After_Signal_Claim
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_signal_claim_arm";
   procedure After_Signal_Claim_Barrier
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_signal_claim_barrier";
   function Signal_Claim_Reached return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_signal_claim_reached";
   function Signal_Claim_Was_Released return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_signal_claim_was_released";
   procedure Release_After_Signal_Claim
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_signal_claim_release";

   procedure Arm_Next_Buffer_Signal_Failure
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_buffer_signal_failure_arm";
   function Fail_Next_Buffer_Signal return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_buffer_signal_failure";

   procedure Arm_Next_Bounded_Signal_Interrupt
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_bounded_signal_interrupt_arm";
   function Take_Bounded_Signal_Interrupt return Boolean
   with
     Import,
     External_Name => "flyology_disabled_hook_must_be_elided_channel_bounded_signal_interrupt_take";
   function Bounded_Signal_Interrupt_Observed return Boolean
   with
     Import,
     External_Name => "flyology_disabled_hook_must_be_elided_channel_bounded_signal_interrupt_observed";
   procedure Arm_Next_Bounded_Signal_Failure
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_bounded_signal_failure_arm";
   function Take_Bounded_Signal_Failure return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_bounded_signal_failure_take";
   function Bounded_Signal_Failure_Observed return Boolean
   with
     Import,
     External_Name => "flyology_disabled_hook_must_be_elided_channel_bounded_signal_failure_observed";
   procedure Arm_After_Bounded_Failure_Ack
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_bounded_ack_arm";
   procedure After_Bounded_Failure_Ack_Barrier
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_bounded_ack_barrier";
   function Bounded_Failure_Ack_Reached return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_bounded_ack_reached";
   procedure Release_After_Bounded_Failure_Ack
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_bounded_ack_release";

end Flyology.Channel_Test_Hooks;
