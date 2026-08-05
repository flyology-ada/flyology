package Worker_Pool_Test_Control is

   procedure Reset;

   procedure Fail_Activation_At (Ordinal : Positive);

   procedure Arm_Shutdown_Barrier;

   procedure Wait_Shutdown_Barrier;

   procedure Release_Shutdown_Barrier;

   procedure Fail_Native_Executor_Cancellation_Once;

   procedure Fail_Native_Executor_Cancellations (Count : Positive);

   function Remaining_Native_Executor_Cancellation_Failures return Natural;

   procedure Fail_Native_Executor_Consume_Once;

   procedure Arm_Native_Executor_Completion_Wake;

   procedure Arm_Token_Cleanup_Barrier;

   procedure Wait_Token_Cleanup_Barrier;

   procedure Release_Token_Cleanup_Barrier;

   function Outstanding_Cleanup_Tokens return Natural;

end Worker_Pool_Test_Control;
