with Ada.Real_Time;
with Interfaces.C;

package body Worker_Pool_Test_Control is

   use type Ada.Real_Time.Time;
   use type Interfaces.C.int;

   procedure C_Reset
   with Import, Convention => C, External_Name => "flyology_test_worker_pool_reset";
   procedure C_Fail_Activation_At (Ordinal : Interfaces.C.int)
   with Import, Convention => C, External_Name => "flyology_test_worker_activation_fail_at";
   procedure C_Arm_Run_Claim_Barrier
   with Import, Convention => C, External_Name => "flyology_test_worker_run_claim_barrier_arm";
   function C_Run_Claim_Barrier_Reached return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_worker_run_claim_barrier_reached";
   procedure C_Release_Run_Claim_Barrier
   with Import, Convention => C, External_Name => "flyology_test_worker_run_claim_barrier_release";
   procedure C_Arm_Shutdown_Barrier
   with Import, Convention => C, External_Name => "flyology_test_worker_shutdown_barrier_arm";
   function C_Shutdown_Barrier_Reached return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_worker_shutdown_barrier_reached";
   procedure C_Release_Shutdown_Barrier
   with Import, Convention => C, External_Name => "flyology_test_worker_shutdown_barrier_release";
   procedure C_Fail_Native_Executor_Cancellation_Once
   with
     Import,
     Convention    => C,
     External_Name => "flyology_test_worker_native_executor_cancellation_fail_once";
   procedure C_Fail_Native_Executor_Cancellations (Count : Interfaces.C.int)
   with
     Import,
     Convention    => C,
     External_Name => "flyology_test_worker_native_executor_cancellation_failures";
   function C_Remaining_Native_Executor_Cancellation_Failures return Interfaces.C.int
   with
     Import,
     Convention    => C,
     External_Name => "flyology_test_worker_native_executor_cancellation_failures_remaining";
   procedure C_Fail_Native_Executor_Consume_Once
   with Import, Convention => C, External_Name => "flyology_test_worker_native_executor_consume_fail_once";
   procedure C_Arm_Native_Executor_Completion_Wake
   with Import, Convention => C, External_Name => "flyology_test_worker_native_executor_completion_wake_once";
   procedure C_Arm_Token_Cleanup_Barrier
   with Import, Convention => C, External_Name => "flyology_test_worker_token_cleanup_barrier_arm";
   function C_Token_Cleanup_Barrier_Reached return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_worker_token_cleanup_barrier_reached";
   procedure C_Release_Token_Cleanup_Barrier
   with Import, Convention => C, External_Name => "flyology_test_worker_token_cleanup_barrier_release";
   function C_Outstanding_Cleanup_Tokens return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_worker_token_cleanup_outstanding";
   procedure C_Arm_Capacity_Acquire_Barrier
   with Import, Convention => C, External_Name => "flyology_test_worker_capacity_acquire_barrier_arm";
   function C_Capacity_Acquire_Barrier_Reached return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_worker_capacity_acquire_barrier_reached";
   procedure C_Release_Capacity_Acquire_Barrier
   with Import, Convention => C, External_Name => "flyology_test_worker_capacity_acquire_barrier_release";

   procedure Reset is
   begin
      C_Reset;
   end Reset;

   procedure Fail_Activation_At (Ordinal : Positive) is
   begin
      C_Fail_Activation_At (Interfaces.C.int (Ordinal));
   end Fail_Activation_At;

   procedure Arm_Run_Claim_Barrier is
   begin
      C_Arm_Run_Claim_Barrier;
   end Arm_Run_Claim_Barrier;

   procedure Wait_Run_Claim_Barrier is
      Deadline : constant Ada.Real_Time.Time := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (10);
   begin
      while C_Run_Claim_Barrier_Reached = 0 loop
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "worker pool run claim barrier was not reached";
         end if;
         delay 0.001;
      end loop;
   end Wait_Run_Claim_Barrier;

   procedure Release_Run_Claim_Barrier is
   begin
      C_Release_Run_Claim_Barrier;
   end Release_Run_Claim_Barrier;

   procedure Arm_Shutdown_Barrier is
   begin
      C_Arm_Shutdown_Barrier;
   end Arm_Shutdown_Barrier;

   procedure Wait_Shutdown_Barrier is
      Deadline : constant Ada.Real_Time.Time := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
   begin
      while C_Shutdown_Barrier_Reached = 0 loop
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "worker pool shutdown barrier was not reached";
         end if;
         delay 0.001;
      end loop;
   end Wait_Shutdown_Barrier;

   procedure Release_Shutdown_Barrier is
   begin
      C_Release_Shutdown_Barrier;
   end Release_Shutdown_Barrier;

   procedure Fail_Native_Executor_Cancellation_Once is
   begin
      C_Fail_Native_Executor_Cancellation_Once;
   end Fail_Native_Executor_Cancellation_Once;

   procedure Fail_Native_Executor_Cancellations (Count : Positive) is
   begin
      C_Fail_Native_Executor_Cancellations (Interfaces.C.int (Count));
   end Fail_Native_Executor_Cancellations;

   function Remaining_Native_Executor_Cancellation_Failures return Natural
   is (Natural (C_Remaining_Native_Executor_Cancellation_Failures));

   procedure Fail_Native_Executor_Consume_Once is
   begin
      C_Fail_Native_Executor_Consume_Once;
   end Fail_Native_Executor_Consume_Once;

   procedure Arm_Native_Executor_Completion_Wake is
   begin
      C_Arm_Native_Executor_Completion_Wake;
   end Arm_Native_Executor_Completion_Wake;

   procedure Arm_Token_Cleanup_Barrier is
   begin
      C_Arm_Token_Cleanup_Barrier;
   end Arm_Token_Cleanup_Barrier;

   procedure Wait_Token_Cleanup_Barrier is
      Deadline : constant Ada.Real_Time.Time := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
   begin
      while C_Token_Cleanup_Barrier_Reached = 0 loop
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "native executor token cleanup barrier was not reached";
         end if;
         delay 0.001;
      end loop;
   end Wait_Token_Cleanup_Barrier;

   procedure Release_Token_Cleanup_Barrier is
   begin
      C_Release_Token_Cleanup_Barrier;
   end Release_Token_Cleanup_Barrier;

   function Outstanding_Cleanup_Tokens return Natural
   is (Natural (C_Outstanding_Cleanup_Tokens));

   procedure Arm_Capacity_Acquire_Barrier is
   begin
      C_Arm_Capacity_Acquire_Barrier;
   end Arm_Capacity_Acquire_Barrier;

   procedure Wait_Capacity_Acquire_Barrier is
      Deadline : constant Ada.Real_Time.Time := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
   begin
      while C_Capacity_Acquire_Barrier_Reached = 0 loop
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "capacity acquire barrier was not reached";
         end if;
         delay 0.001;
      end loop;
   end Wait_Capacity_Acquire_Barrier;

   procedure Release_Capacity_Acquire_Barrier is
   begin
      C_Release_Capacity_Acquire_Barrier;
   end Release_Capacity_Acquire_Barrier;

end Worker_Pool_Test_Control;
