with Interfaces.C;

package body Flyology.Worker_Pool_Test_Hooks is
   use type Interfaces.C.int;

   function Test_Activation_Failure return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_worker_activation_failure";
   function Test_Consume_Failure return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_worker_native_executor_consume_failure";
   function Test_Completion_Wake return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_worker_native_executor_completion_wake";
   function Test_Cancellation_Failure return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_worker_native_executor_cancellation_failure";
   function Test_Run_Claim_Barrier_Arrive return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_worker_run_claim_barrier_arrive";
   function Test_Run_Claim_Barrier_Released return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_worker_run_claim_barrier_released";
   function Test_Shutdown_Barrier_Arrive return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_worker_shutdown_barrier_arrive";
   function Test_Shutdown_Barrier_Released return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_worker_shutdown_barrier_released";
   function Test_Token_Cleanup_Barrier_Arrive return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_worker_token_cleanup_barrier_arrive";
   function Test_Token_Cleanup_Barrier_Released return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_worker_token_cleanup_barrier_released";
   procedure Test_Token_Cleanup_Acquire
   with Import, Convention => C, External_Name => "flyology_test_worker_token_cleanup_acquire";
   procedure Test_Token_Cleanup_Release
   with Import, Convention => C, External_Name => "flyology_test_worker_token_cleanup_release";
   function Test_Capacity_Acquire_Barrier_Arrive return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_worker_capacity_acquire_barrier_arrive";
   function Test_Capacity_Acquire_Barrier_Released return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_worker_capacity_acquire_barrier_released";

   function Check_Activation return Boolean is
   begin
      if Test_Activation_Failure /= 0 then
         raise Program_Error with "injected worker activation failure";
      end if;
      return True;
   end Check_Activation;

   function Cancellation_Failure return Boolean
   is (Test_Cancellation_Failure /= 0);

   function Consume_Failure return Boolean
   is (Test_Consume_Failure /= 0);

   function Completion_Wake return Boolean
   is (Test_Completion_Wake /= 0);

   procedure Run_Claim_Barrier is
   begin
      if Test_Run_Claim_Barrier_Arrive /= 0 then
         while Test_Run_Claim_Barrier_Released = 0 loop
            delay 0.0;
         end loop;
      end if;
   end Run_Claim_Barrier;

   procedure Shutdown_Barrier is
   begin
      if Test_Shutdown_Barrier_Arrive /= 0 then
         while Test_Shutdown_Barrier_Released = 0 loop
            delay 0.0;
         end loop;
      end if;
   end Shutdown_Barrier;

   procedure Token_Cleanup_Acquire is
   begin
      Test_Token_Cleanup_Acquire;
   end Token_Cleanup_Acquire;

   procedure Token_Cleanup_Barrier is
   begin
      if Test_Token_Cleanup_Barrier_Arrive /= 0 then
         while Test_Token_Cleanup_Barrier_Released = 0 loop
            null;
         end loop;
      end if;
   end Token_Cleanup_Barrier;

   procedure Token_Cleanup_Release is
   begin
      Test_Token_Cleanup_Release;
   end Token_Cleanup_Release;

   procedure Capacity_Acquire_Barrier is
   begin
      if Test_Capacity_Acquire_Barrier_Arrive /= 0 then
         while Test_Capacity_Acquire_Barrier_Released = 0 loop
            null;
         end loop;
      end if;
   end Capacity_Acquire_Barrier;
end Flyology.Worker_Pool_Test_Hooks;
