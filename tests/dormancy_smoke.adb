with Flyology;
with Flyology.Dormancy;
with Flyology.Observability;
with Interfaces;

procedure Dormancy_Smoke is
   package Dormancy renames Flyology.Dormancy;
   package Observation renames Flyology.Observability;

   use type Dormancy.Policy;
   use type Interfaces.Unsigned_64;

   protected Control is
      procedure Started;
      procedure Finished;
      entry Wait_Until_Started;
      entry Wait_Until_Finished;
   private
      Is_Started  : Boolean := False;
      Is_Finished : Boolean := False;
   end Control;

   protected body Control is
      procedure Started is
      begin
         Is_Started := True;
      end Started;

      procedure Finished is
      begin
         Is_Finished := True;
      end Finished;

      entry Wait_Until_Started when Is_Started is
      begin
         null;
      end Wait_Until_Started;

      entry Wait_Until_Finished when Is_Finished is
      begin
         null;
      end Wait_Until_Finished;
   end Control;

   Native_Rejected : Boolean := False;
   Sample          : Observation.Group_Snapshot;
   Parked          : Boolean := False;
begin
   if Dormancy.Current_Policy /= Dormancy.Prompt then
      raise Program_Error with "native task has a reclaimable stack policy";
   end if;
   Dormancy.Set_Policy (Dormancy.Prompt);
   begin
      Dormancy.Set_Policy (Dormancy.Reclaimable, Minimum_Wait => 0.0);
   exception
      when Dormancy.Dormancy_Error =>
         Native_Rejected := True;
   end;
   if not Native_Rejected then
      raise Program_Error with "native reclaimable policy was accepted";
   end if;

   declare
      task Worker with CPU => 1 is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Worker;

      task body Worker is
      begin
         if Dormancy.Current_Policy /= Dormancy.Prompt then
            raise Program_Error with "lightweight policy did not default prompt";
         end if;
         Dormancy.Set_Policy
           (Dormancy.Reclaimable, Minimum_Wait => 0.0);
         if Dormancy.Current_Policy /= Dormancy.Reclaimable then
            raise Program_Error with "reclaimable policy was not retained";
         end if;
         Control.Started;
         delay 1.0;
         Dormancy.Set_Policy (Dormancy.Prompt);
         Control.Finished;
      end Worker;
   begin
      select
         Control.Wait_Until_Started;
      or
         delay 2.0;
         raise Program_Error with "dormancy worker did not start";
      end select;

      for Attempt in 1 .. 2_000 loop
         Parked := Observation.Snapshot (1, Sample)
           and then Sample.Dormancy_Candidates = 1
           and then Sample.Dormancy_Candidate_Bytes > 0
           and then
             (if Dormancy.Cold_Advice_Supported then
                 Sample.Cold_Stacks = 1
                 and then Sample.Cold_Stack_Bytes =
                   Sample.Dormancy_Candidate_Bytes
                 and then Sample.Cold_Advice_Attempts >= 1
                 and then Sample.Cold_Advice_Accepted >= 1
                 and then Sample.Cold_Advice_Failures = 0
              else
                 Sample.Cold_Stacks = 0
                 and then Sample.Cold_Stack_Bytes = 0
                 and then Sample.Cold_Advice_Attempts = 0);
         exit when Parked;
         delay 0.001;
      end loop;
      if not Parked then
         raise Program_Error with "dormant stack state was not observed";
      end if;

      select
         Control.Wait_Until_Finished;
      or
         delay 2.0;
         raise Program_Error with "dormancy worker did not finish";
      end select;
   end;

   if not Observation.Snapshot (1, Sample)
     or else Sample.Cold_Stacks /= 0
     or else Sample.Cold_Stack_Bytes /= 0
   then
      raise Program_Error with "resumed stack remained classified cold";
   end if;
end Dormancy_Smoke;
