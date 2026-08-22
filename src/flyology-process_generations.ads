with Interfaces;

--  Vocabulary shared by new-process upgrade coordinators and application
--  agents. An image generation always owns a fresh Ada runtime, supervision
--  tree, tasks, connections, and process-local handles. These types identify
--  rollout authority and observations; they do not make process-local values
--  transferable.

package Flyology.Process_Generations
  with Preelaborate
is
   --  Nonzero stable identity of one coordinator lifetime.
   type Coordinator_Id is new Interfaces.Unsigned_64 range 1 .. Interfaces.Unsigned_64'Last;

   --  Nonzero transaction identity allocated by one coordinator. Values do
   --  not wrap; exhaustion requires a fresh coordinator identity.
   type Upgrade_Id is new Interfaces.Unsigned_64 range 1 .. Interfaces.Unsigned_64'Last;

   --  Nonzero identity of one executable process generation. Values do not
   --  wrap within a coordinator lifetime.
   type Image_Generation is new Interfaces.Unsigned_64 range 1 .. Interfaces.Unsigned_64'Last;

   --  Exact authority for one candidate transaction.
   --  @field Coordinator Coordinator that allocated the transaction
   --  @field Upgrade Exact upgrade transaction
   --  @field Candidate Candidate process generation
   type Upgrade_Handle is record
      Coordinator : Coordinator_Id;
      Upgrade     : Upgrade_Id;
      Candidate   : Image_Generation;
   end record;

   --  Report whether two values grant authority over the same transaction.
   --  @param Left First authority
   --  @param Right Second authority
   --  @return True only when every authority component matches
   function Same_Upgrade (Left, Right : Upgrade_Handle) return Boolean
   is (Left = Right);

   --  Candidate role supplied to application topology reconstruction.
   --  @enum Canary_Safe May perform work concurrently with the previous image
   --  @enum Fenced Effects require an exact active deployment-epoch check
   --  @enum Active_Only Work begins only after promotion
   --  @enum Shadow Work may observe or compute but must not commit effects
   type Candidate_Role is (Canary_Safe, Fenced, Active_Only, Shadow);

   --  Lifecycle phase of one coordinator or upgrade transaction.
   --  Stable has no candidate. Completed, Cancelled, Failed, and
   --  Rollback_Required are terminal transaction observations; a coordinator
   --  starts a later transaction from a fresh Stable state.
   --  @enum Stable No candidate transaction is active
   --  @enum Starting A candidate launch is beginning
   --  @enum Provisioning The candidate is reconstructing its local topology
   --  @enum Prepared The candidate is provisioned but not admitting work
   --  @enum Canary The candidate may admit work under its declared role
   --  @enum Cancelling Candidate cancellation has begun
   --  @enum Revoking_Admission New candidate admission is being revoked
   --  @enum Draining_Candidate Existing candidate work is draining
   --  @enum Compensating Candidate effects are being compensated
   --  @enum Cancelled Cancellation completed
   --  @enum Promoting The candidate crossed the promotion boundary
   --  @enum Draining_Previous The previous active image is draining
   --  @enum Committing Promotion bookkeeping is being committed
   --  @enum Completed Promotion completed
   --  @enum Failed The transaction failed before promotion committed
   --  @enum Rollback_Required Promotion failed after commitment
   type Upgrade_Phase is
     (Stable,
      Starting,
      Provisioning,
      Prepared,
      Canary,
      Cancelling,
      Revoking_Admission,
      Draining_Candidate,
      Compensating,
      Cancelled,
      Promoting,
      Draining_Previous,
      Committing,
      Completed,
      Failed,
      Rollback_Required);

   --  Exact commands consumed by the proved transition policy.
   --  @enum Start_Upgrade Begin a candidate transaction
   --  @enum Candidate_Started Record successful candidate launch
   --  @enum Candidate_Prepared Record successful candidate preparation
   --  @enum Start_Canary Grant candidate admission
   --  @enum Cancel_Upgrade Begin reversible cancellation
   --  @enum Candidate_Stopped Record candidate server termination
   --  @enum Admission_Revoked Record that new admission is disabled
   --  @enum Candidate_Drained Record candidate quiescence
   --  @enum Compensation_Finished Record the compensation outcome
   --  @enum Promote_Upgrade Cross the promotion commitment boundary
   --  @enum Previous_Drain_Started Begin previous-image retirement
   --  @enum Previous_Drained Record previous-image quiescence
   --  @enum Commit_Finished Complete promotion bookkeeping
   --  @enum Record_Failure Record a pre-commit failure
   --  @enum Require_Rollback Record a post-commit failure
   type Upgrade_Command is
     (Start_Upgrade,
      Candidate_Started,
      Candidate_Prepared,
      Start_Canary,
      Cancel_Upgrade,
      Candidate_Stopped,
      Admission_Revoked,
      Candidate_Drained,
      Compensation_Finished,
      Promote_Upgrade,
      Previous_Drain_Started,
      Previous_Drained,
      Commit_Finished,
      Record_Failure,
      Require_Rollback);

   --  Outcome of application compensation after candidate quiescence.
   --  @enum Not_Required Compensation has not been requested
   --  @enum Nothing_To_Do No candidate effect required compensation
   --  @enum Compensated Candidate effects were reversed
   --  @enum Compensation_Pending The outcome is unknown and needs recovery
   --  @enum Irreversible_Effects Some candidate effects cannot be reversed
   --  @enum Compensation_Failed Compensation completed unsuccessfully
   type Compensation_Result is
     (Not_Required,
      Nothing_To_Do,
      Compensated,
      Compensation_Pending,
      Irreversible_Effects,
      Compensation_Failed);

end Flyology.Process_Generations;
