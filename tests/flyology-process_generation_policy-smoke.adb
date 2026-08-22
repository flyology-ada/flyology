with Interfaces;
with Flyology.Process_Generations;

procedure Flyology.Process_Generation_Policy.Smoke is
   package Public renames Flyology.Process_Generations;

   First : constant Public.Upgrade_Handle :=
     (Coordinator => 1, Upgrade => 2, Candidate => 3);
   Same  : constant Public.Upgrade_Handle := First;
   Other : constant Public.Upgrade_Handle :=
     (Coordinator => 1, Upgrade => 2, Candidate => 4);

   Phase : Public.Upgrade_Phase := Public.Stable;

   procedure Apply (Command : Public.Upgrade_Command) is
   begin
      pragma Assert (Command_Allowed (Phase, Command));
      Phase := Phase_After (Phase, Command);
   end Apply;
begin
   pragma Assert (Authority_Matches (First, Same));
   pragma Assert (not Authority_Matches (First, Other));
   pragma Assert (Public.Same_Upgrade (First, Same));
   pragma Assert (not Public.Same_Upgrade (First, Other));

   for Candidate_Phase in Public.Upgrade_Phase loop
      pragma Assert
        (Terminal (Candidate_Phase) =
           (Candidate_Phase in Public.Cancelled | Public.Completed |
              Public.Failed | Public.Rollback_Required));
      pragma Assert
        (Cancellation_Allowed (Candidate_Phase) =
           (Candidate_Phase in Public.Starting | Public.Provisioning |
              Public.Prepared | Public.Canary));
      pragma Assert
        (Promotion_Committed (Candidate_Phase) =
           (Candidate_Phase in Public.Promoting |
              Public.Draining_Previous | Public.Committing |
              Public.Completed | Public.Rollback_Required));
      if Terminal (Candidate_Phase) then
         for Command in Public.Upgrade_Command loop
            pragma Assert (not Command_Allowed (Candidate_Phase, Command));
         end loop;
      end if;
   end loop;

   Apply (Public.Start_Upgrade);
   pragma Assert (Phase = Public.Starting);
   Apply (Public.Candidate_Started);
   pragma Assert (Phase = Public.Provisioning);
   Apply (Public.Candidate_Prepared);
   pragma Assert (Phase = Public.Prepared);
   Apply (Public.Start_Canary);
   pragma Assert (Phase = Public.Canary);
   Apply (Public.Cancel_Upgrade);
   pragma Assert (Phase = Public.Revoking_Admission);
   Apply (Public.Admission_Revoked);
   pragma Assert (Phase = Public.Draining_Candidate);
   Apply (Public.Candidate_Drained);
   pragma Assert (Phase = Public.Compensating);
   Apply (Public.Compensation_Finished);
   pragma Assert (Phase = Public.Cancelled and then Terminal (Phase));

   Phase := Public.Stable;
   Apply (Public.Start_Upgrade);
   Apply (Public.Candidate_Started);
   Apply (Public.Candidate_Prepared);
   Apply (Public.Promote_Upgrade);
   pragma Assert (Phase = Public.Promoting);
   Apply (Public.Previous_Drain_Started);
   pragma Assert (Phase = Public.Draining_Previous);
   Apply (Public.Previous_Drained);
   pragma Assert (Phase = Public.Committing);
   Apply (Public.Commit_Finished);
   pragma Assert (Phase = Public.Completed and then Terminal (Phase));

   Phase := Public.Stable;
   Apply (Public.Start_Upgrade);
   Apply (Public.Cancel_Upgrade);
   pragma Assert (Phase = Public.Cancelling);
   Apply (Public.Candidate_Stopped);
   pragma Assert (Phase = Public.Cancelled);

   Phase := Public.Promoting;
   Apply (Public.Require_Rollback);
   pragma Assert (Phase = Public.Rollback_Required);

   Phase := Public.Provisioning;
   Apply (Public.Record_Failure);
   pragma Assert (Phase = Public.Failed);

   pragma Assert (Can_Advance (0));
   pragma Assert (Advanced (0) = 1);
   pragma Assert
     (not Can_Advance (Interfaces.Unsigned_64'Last));
end Flyology.Process_Generation_Policy.Smoke;
