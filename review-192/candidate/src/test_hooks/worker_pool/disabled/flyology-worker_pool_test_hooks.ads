--  Disabled worker-pool test seams selected by the owning project. The
--  imported-only declarations make a missed static guard visible to symbol
--  inspection without supplying any production implementation.

private package Flyology.Worker_Pool_Test_Hooks is
   pragma Preelaborate;

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := False;

   function Check_Activation return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_worker_activation";
   function Cancellation_Failure return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_worker_cancellation";
   function Consume_Failure return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_worker_consume";
   function Completion_Wake return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_worker_completion_wake";
   procedure Native_Executor_Dispatch_Barrier
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_worker_executor_dispatch";
   procedure Native_Executor_Idle_Barrier
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_worker_executor_idle";
   procedure Run_Claim_Barrier
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_worker_run_claim";
   procedure Shutdown_Barrier
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_worker_shutdown";
   procedure Token_Cleanup_Acquire
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_worker_token_acquire";
   procedure Token_Cleanup_Barrier
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_worker_token_barrier";
   procedure Token_Cleanup_Release
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_worker_token_release";
   procedure Capacity_Acquire_Barrier
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_worker_capacity_acquire";

end Flyology.Worker_Pool_Test_Hooks;
