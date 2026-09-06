--  Enabled worker-pool test control selected by the owning project.

private package Flyology.Worker_Pool_Test_Hooks is
   pragma Preelaborate;

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := True;

   function Check_Activation return Boolean;
   function Cancellation_Failure return Boolean;
   function Consume_Failure return Boolean;
   function Completion_Wake return Boolean;
   procedure Native_Executor_Dispatch_Barrier;
   procedure Native_Executor_Idle_Barrier;
   procedure Run_Claim_Barrier;
   procedure Shutdown_Barrier;
   procedure Token_Cleanup_Acquire;
   procedure Token_Cleanup_Barrier;
   procedure Token_Cleanup_Release;
   procedure Capacity_Acquire_Barrier;
end Flyology.Worker_Pool_Test_Hooks;
