with Flyology.IO.Sockets;
with Flyology.Process_Generations.Messages;

--  Application-side image agent. The package owns the bootstrap protocol and
--  the lifetime of one server task; application hooks reconstruct the local
--  supervision tree and bridge exact readiness/shutdown into that task.
--  @formal Application_Context Image-local application and server state
--  @formal Prepare Reconstruct the desired local topology before admission
--  @formal Run_Server Run the structured server on the handed-off listener
--  @formal Ready Report exact reconstructed topology and server admission
--  @formal Request_Stop Revoke admission and request structured shutdown
--  @formal Promoted Enable work reserved for the active image
--  @formal Compensate Reverse candidate effects after quiescence
generic
   type Application_Context is limited private;

   --  Reconstruct desired local topology without admission authority.
   with procedure Prepare
     (Context : in out Application_Context;
      Data    : Messages.Provisioning_Data);

   --  Run the server until Request_Stop causes its structured scopes to join.
   --  The procedure executes in one native Agent-owned task.
   with procedure Run_Server
     (Context  : in out Application_Context;
      Listener : in out Flyology.IO.Sockets.Socket_Type;
      Role     : Candidate_Role);

   --  True only when the exact provisioned topology is reconciled and every
   --  required structured server reports Accepting.
   with function Ready
     (Context : Application_Context;
      Data    : Messages.Provisioning_Data) return Boolean;

   --  Must synchronously revoke new admission before returning, then request
   --  structured shutdown. It may be called more than once during cleanup.
   with procedure Request_Stop (Context : in out Application_Context);

   --  Enable Active_Only work and publish the promoted deployment epoch.
   with procedure Promoted
     (Context   : in out Application_Context;
      Authority : Upgrade_Handle);

   --  Called only after the candidate server task has terminated. It may be
   --  repeated after uncertain acknowledgment and must be idempotent.
   with function Compensate
     (Context   : in out Application_Context;
      Authority : Upgrade_Handle) return Compensation_Result;
package Flyology.Process_Generations.Agents is
   --  Bootstrap, protocol, application-hook, or server-lifecycle failure.
   Agent_Error : exception;

   --  Adopt bootstrap channels and serve one coordinator-managed image.
   --  @param Context Image-local application context
   --  @param Ready_Timeout Total wait for application readiness
   --  @param Drain_Timeout Wait before reporting a stuck structured drain;
   --     process-level fencing remains the coordinator's responsibility
   --  @param Control_Timeout Timeout for each long-lived control operation
   --  @exception Agent_Error Bootstrap or lifecycle processing fails
   procedure Run
     (Context         : in out Application_Context;
      Ready_Timeout   : Duration := 30.0;
      Drain_Timeout   : Duration := 30.0;
      Control_Timeout : Duration := Flyology.IO.Infinite);
end Flyology.Process_Generations.Agents;
