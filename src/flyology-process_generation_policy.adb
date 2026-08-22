package body Flyology.Process_Generation_Policy
  with SPARK_Mode
is

   function Command_Allowed (Phase : Public.Upgrade_Phase; Command : Public.Upgrade_Command) return Boolean
   is (case Phase is
         when Public.Stable                                                                  =>
           Command = Public.Start_Upgrade,
         when Public.Starting                                                                =>
           Command in Public.Candidate_Started | Public.Cancel_Upgrade | Public.Record_Failure,
         when Public.Provisioning                                                            =>
           Command in Public.Candidate_Prepared | Public.Cancel_Upgrade | Public.Record_Failure,
         when Public.Prepared                                                                =>
           Command
           in Public.Start_Canary | Public.Cancel_Upgrade | Public.Promote_Upgrade | Public.Record_Failure,
         when Public.Canary                                                                  =>
           Command in Public.Cancel_Upgrade | Public.Promote_Upgrade | Public.Record_Failure,
         when Public.Cancelling                                                              =>
           Command in Public.Candidate_Stopped | Public.Record_Failure,
         when Public.Revoking_Admission                                                      =>
           Command in Public.Admission_Revoked | Public.Record_Failure,
         when Public.Draining_Candidate                                                      =>
           Command in Public.Candidate_Drained | Public.Record_Failure,
         when Public.Compensating                                                            =>
           Command in Public.Compensation_Finished | Public.Record_Failure,
         when Public.Promoting                                                               =>
           Command in Public.Previous_Drain_Started | Public.Require_Rollback,
         when Public.Draining_Previous                                                       =>
           Command in Public.Previous_Drained | Public.Require_Rollback,
         when Public.Committing                                                              =>
           Command in Public.Commit_Finished | Public.Require_Rollback,
         when Public.Cancelled | Public.Completed | Public.Failed | Public.Rollback_Required => False);

   function Phase_After
     (Phase : Public.Upgrade_Phase; Command : Public.Upgrade_Command) return Public.Upgrade_Phase
   is (case Command is
         when Public.Start_Upgrade          => Public.Starting,
         when Public.Candidate_Started      => Public.Provisioning,
         when Public.Candidate_Prepared     => Public.Prepared,
         when Public.Start_Canary           => Public.Canary,
         when Public.Cancel_Upgrade         =>
           (if Phase = Public.Canary then Public.Revoking_Admission else Public.Cancelling),
         when Public.Candidate_Stopped      => Public.Cancelled,
         when Public.Admission_Revoked      => Public.Draining_Candidate,
         when Public.Candidate_Drained      => Public.Compensating,
         when Public.Compensation_Finished  => Public.Cancelled,
         when Public.Promote_Upgrade        => Public.Promoting,
         when Public.Previous_Drain_Started => Public.Draining_Previous,
         when Public.Previous_Drained       => Public.Committing,
         when Public.Commit_Finished        => Public.Completed,
         when Public.Record_Failure         => Public.Failed,
         when Public.Require_Rollback       => Public.Rollback_Required);

   function Terminal (Phase : Public.Upgrade_Phase) return Boolean
   is (Phase in Public.Cancelled | Public.Completed | Public.Failed | Public.Rollback_Required);

   function Cancellation_Allowed (Phase : Public.Upgrade_Phase) return Boolean
   is (Phase in Public.Starting | Public.Provisioning | Public.Prepared | Public.Canary);

   function Promotion_Committed (Phase : Public.Upgrade_Phase) return Boolean
   is (Phase
       in Public.Promoting
        | Public.Draining_Previous
        | Public.Committing
        | Public.Completed
        | Public.Rollback_Required);

   function Authority_Matches (Expected, Supplied : Public.Upgrade_Handle) return Boolean
   is (Expected = Supplied);

   function Advanced (Value : Interfaces.Unsigned_64) return Interfaces.Unsigned_64
   is (Value + 1);

end Flyology.Process_Generation_Policy;
