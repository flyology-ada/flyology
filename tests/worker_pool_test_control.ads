package Worker_Pool_Test_Control is

   procedure Reset;

   procedure Fail_Activation_At (Ordinal : Positive);

   procedure Arm_Shutdown_Barrier;

   procedure Wait_Shutdown_Barrier;

   procedure Release_Shutdown_Barrier;

   procedure Fail_Native_Executor_Cancellation_Once;

end Worker_Pool_Test_Control;
