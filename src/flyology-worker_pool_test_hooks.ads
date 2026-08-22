--  Test-only worker-pool control compiled with Flyology's own switches. The
--  disabled implementation has no native imports or observable effects.

private package Flyology.Worker_Pool_Test_Hooks is
   function Check_Activation return Boolean;
   function Consume_Failure return Boolean;
   function Completion_Wake return Boolean;
   procedure Run_Claim_Barrier;
   procedure Shutdown_Barrier;
   procedure Token_Cleanup_Acquire;
   procedure Token_Cleanup_Barrier;
   procedure Token_Cleanup_Release;
   procedure Capacity_Acquire_Barrier;
end Flyology.Worker_Pool_Test_Hooks;
