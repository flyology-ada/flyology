package body Flyology.Supervision_Policy
  with SPARK_Mode
is
   procedure Plan_Start_Order
     (Count        : Child_Count;
      Dependencies : Dependency_Matrix;
      Plan         : out Order_Plan)
   is
      Emitted   : Child_Set := (others => False);
      Ready_Set : Child_Set := (others => False);
      Candidate : Child_Id;
      Found     : Boolean;
   begin
      Plan := (Valid => False,
               Length => 0,
               Items => (others => Child_Id'First));
      for Position in 1 .. Count loop
         pragma Loop_Invariant (Plan.Length = Position - 1);
         pragma Loop_Invariant
           (Valid_Start_Order (Count, Dependencies, Plan));
         pragma Loop_Invariant
           (for all Id in Child_Id =>
              Emitted (Id) =
                (Id <= Count
                 and then Appears_Before
                   (Plan, Id, Child_Id (Position))));

         for Id in Child_Id loop
            Ready_Set (Id) :=
              Id <= Count
              and then not Emitted (Id)
              and then
                (for all Prerequisite in Child_Id =>
                   (if Prerequisite <= Count
                      and then Dependencies (Id, Prerequisite)
                    then Emitted (Prerequisite)));
            pragma Loop_Invariant
              (for all Checked in Child_Id =>
                 (if Checked <= Id then
                     Ready_Set (Checked) =
                       (Checked <= Count
                        and then not Emitted (Checked)
                        and then
                          (for all Prerequisite in Child_Id =>
                             (if Prerequisite <= Count
                                and then Dependencies
                                  (Checked, Prerequisite)
                              then Emitted (Prerequisite))))));
         end loop;

         Found := False;
         Candidate := Child_Id'First;
         for Id in Child_Id loop
            if Ready_Set (Id) and then not Found then
               Candidate := Id;
               Found := True;
            end if;
            pragma Loop_Invariant
              (if Found then Ready_Set (Candidate));
         end loop;
         if not Found then
            return;
         end if;

         pragma Assert (Candidate <= Count);
         pragma Assert (not Emitted (Candidate));
         pragma Assert
           (for all Prerequisite in Child_Id =>
              (if Prerequisite <= Count
                 and then Dependencies (Candidate, Prerequisite)
               then Emitted (Prerequisite)));
         Plan.Length := Position;
         Plan.Items (Child_Id (Position)) := Candidate;
         pragma Assert (Valid_Start_Order (Count, Dependencies, Plan));
         Emitted (Candidate) := True;
      end loop;
      Plan.Valid := True;
   end Plan_Start_Order;

   procedure Plan_Stop_Order
     (Start : Order_Plan;
      Stop  : out Order_Plan)
   is
   begin
      Stop := (Valid => True,
               Length => Start.Length,
               Items => (others => Child_Id'First));
      for Position in 1 .. Start.Length loop
         Stop.Items (Child_Id (Position)) :=
           Start.Items (Child_Id (Start.Length - Position + 1));
      end loop;
   end Plan_Stop_Order;

   procedure Affected_Children
     (Count        : Child_Count;
      Failed       : Child_Id;
      Impact       : Public.Restart_Impact;
      Cohort       : Child_Set;
      Dependencies : Dependency_Matrix;
      Affected     : out Child_Set)
   is
   begin
      Affected := (others => False);
      if Impact = Public.Escalate then
         return;
      end if;
      case Impact is
         when Public.Escalate =>
            null;
         when Public.Isolate_Child =>
            null;
         when Public.Restart_Cohort =>
            for Id in Child_Id loop
               if Id <= Count then
                  Affected (Id) := Cohort (Id);
               end if;
            end loop;
         when Public.Restart_Dependents =>
            declare
               Processed : Child_Set := (others => False);
               Source    : Child_Id := Failed;
               Found     : Boolean;
            begin
               Affected (Failed) := True;
               --  Each iteration expands one affected child that has not yet
               --  been processed. Processed entries only become true, so the
               --  finite worklist performs at most Count expansions.
               loop
                  pragma Loop_Invariant (Affected (Failed));
                  pragma Loop_Invariant
                    (for all Id in Child_Id =>
                       (if Processed (Id) then Id <= Count));
                  pragma Loop_Invariant
                    (for all Prerequisite in Child_Id =>
                       (if Processed (Prerequisite) then
                           (for all User in Child_Id =>
                              (if User <= Count
                                 and then Dependencies (User, Prerequisite)
                               then Affected (User)))));

                  Found := False;
                  for Id in Child_Id loop
                     if Id <= Count
                       and then Affected (Id)
                       and then not Processed (Id)
                       and then not Found
                     then
                        Source := Id;
                        Found := True;
                     end if;
                     pragma Loop_Invariant
                       (if Found then
                           Source <= Count
                           and then Affected (Source)
                           and then not Processed (Source));
                     pragma Loop_Invariant
                       (if not Found then
                           (for all Checked in Child_Id =>
                              (if Checked <= Id
                                 and then Checked <= Count
                                 and then Affected (Checked)
                               then Processed (Checked))));
                  end loop;
                  exit when not Found;

                  for User in Child_Id loop
                     pragma Loop_Invariant (Affected (Failed));
                     pragma Loop_Invariant
                       (for all Prerequisite in Child_Id =>
                          (if Processed (Prerequisite) then
                              (for all Dependent in Child_Id =>
                                 (if Dependent <= Count
                                    and then Dependencies
                                      (Dependent, Prerequisite)
                                  then Affected (Dependent)))));
                     pragma Loop_Invariant
                       (for all Checked in Child_Id =>
                          (if Checked < User
                             and then Checked <= Count
                             and then Dependencies (Checked, Source)
                           then Affected (Checked)));
                     if User <= Count
                       and then Dependencies (User, Source)
                     then
                        Affected (User) := True;
                     end if;
                  end loop;
                  Processed (Source) := True;
               end loop;
            end;
      end case;
      for Id in Child_Id loop
         if Id > Count then
            Affected (Id) := False;
         end if;
      end loop;
      --  The failed child is always in a local recovery set. Assigning this at
      --  the common exit also makes the public postcondition independent of
      --  the closure algorithm's internal loop proof.
      Affected (Failed) := True;
   end Affected_Children;

   function Transition_Allowed
     (From : Public.Child_State;
      To   : Public.Child_State) return Boolean
   is
     (case From is
         when Public.Configured =>
            To in Public.Starting | Public.Joined,
         when Public.Starting =>
            To in Public.Ready | Public.Running | Public.Stopping |
              Public.Terminated | Public.Failed_Escalated,
         when Public.Ready =>
            To in Public.Running | Public.Stopping | Public.Terminated,
         when Public.Running =>
            To in Public.Stopping | Public.Terminated,
         when Public.Stopping =>
            To in Public.Terminated | Public.Failed_Escalated,
         when Public.Terminated =>
            To in Public.Backing_Off | Public.Restarting |
              Public.Failed_Escalated | Public.Joined,
         when Public.Backing_Off =>
            To in Public.Restarting | Public.Stopping |
              Public.Failed_Escalated,
         when Public.Restarting =>
            To in Public.Starting | Public.Stopping |
              Public.Failed_Escalated,
         when Public.Failed_Escalated =>
            To in Public.Stopping | Public.Joined,
         when Public.Joined => False);

   function Is_Failure
     (Kind : Public.Termination_Kind) return Boolean
   is
     (Kind in Public.Unhandled_Exception |
              Public.Abnormal_Completion |
              Public.Activation_Failure |
              Public.Readiness_Timeout |
              Public.Stop_Timeout);

   function Should_Restart
     (Policy : Public.Restart_Kind;
      Kind   : Public.Termination_Kind) return Boolean
   is
     (if Kind in Public.No_Termination | Public.Supervisor_Shutdown |
         Public.Stuck | Public.Policy_Exhaustion
      then False
      else
        (case Policy is
            when Public.Never      => False,
            when Public.On_Failure => Is_Failure (Kind),
            when Public.Always     => True));

   function Backoff_For
     (Attempt       : Attempt_Count;
      Initial_Delay : Tick;
      Maximum_Delay : Tick) return Tick
   is
      Result : Tick := Initial_Delay;
   begin
      if Result = 0 then
         return Result;
      end if;
      for Index in 2 .. Attempt loop
         pragma Loop_Invariant (Result <= Maximum_Delay);
         pragma Loop_Invariant (Result >= Initial_Delay);
         exit when Result = Maximum_Delay;
         if Result > Maximum_Delay / 2 then
            Result := Maximum_Delay;
         else
            Result := Result * 2;
         end if;
      end loop;
      return Result;
   end Backoff_For;

   procedure Classify_Attempt
     (Limits            : Restart_Limits;
      Account           : Restart_Account;
      Now               : Tick;
      Recovery_Deadline : Tick;
      Admission         : out Restart_Admission;
      Backoff           : out Tick)
   is
      In_Window : constant Boolean :=
        Now - Account.Window_Started < Limits.Window;
      Window_Used : constant Attempt_Count :=
        (if In_Window then Account.Window_Used else 0);
   begin
      Backoff := Backoff_For
        (Account.Consecutive + 1,
         Limits.Initial_Delay,
         Limits.Maximum_Delay);
      if Account.Total_Used >= Limits.Total_Limit then
         Admission := Total_Exhausted;
      elsif Window_Used >= Limits.Burst_Limit then
         Admission := Burst_Exhausted;
      elsif Backoff > Recovery_Deadline - Now then
         Admission := Deadline_Exhausted;
      else
         Admission := Restart_Admitted;
      end if;
   end Classify_Attempt;

   procedure Record_Attempt
     (Limits  : Restart_Limits;
      Now     : Tick;
      Account : in out Restart_Account)
   is
   begin
      if Now - Account.Window_Started >= Limits.Window then
         Account.Window_Started := Now;
         Account.Window_Used := 0;
      end if;
      Account.Total_Used := Account.Total_Used + 1;
      Account.Window_Used := Account.Window_Used + 1;
      Account.Consecutive := Account.Consecutive + 1;
   end Record_Attempt;

   procedure Reset_If_Stable
     (Limits      : Restart_Limits;
      Now         : Tick;
      Ready_Since : Tick;
      Account     : in out Restart_Account)
   is
   begin
      if Now - Ready_Since >= Limits.Stability_Time then
         Account :=
           (Total_Used     => 0,
            Window_Used    => 0,
            Consecutive    => 0,
            Window_Started => Now);
      end if;
   end Reset_If_Stable;

   procedure Begin_Attempt (Incident : in out Incident_Context) is
   begin
      Incident.Attempt := Incident.Attempt + 1;
      Incident.Attempt_Active := True;
   end Begin_Attempt;

   procedure End_Attempt (Incident : in out Incident_Context) is
   begin
      Incident.Attempt_Active := False;
   end End_Attempt;

   procedure Observe_Incident
     (Incident    : Incident_Context;
      Observation : in out Incident_Observation;
      Was_New     : out Boolean)
   is
   begin
      Was_New :=
        not Observation.Seen
        or else Observation.Last_Id /= Incident.Id
        or else Observation.Last_Attempt /= Incident.Attempt;
      if Was_New then
         Observation.Last_Id := Incident.Id;
         Observation.Last_Attempt := Incident.Attempt;
         Observation.Seen := True;
         Observation.Count := Observation.Count + 1;
      end if;
   end Observe_Incident;

   function Same_Incident_Attempt
     (Seen             : Boolean;
      Previous_Id      : Public.Incident_Id;
      Previous_Attempt : Public.Incident_Attempt;
      Current_Id       : Public.Incident_Id;
      Current_Attempt  : Public.Incident_Attempt) return Boolean
   is
     (Seen
      and then Previous_Id = Current_Id
      and then Previous_Attempt = Current_Attempt);

   function Family_Finished
     (Shutdown          : Boolean;
      Terminal          : Boolean;
      Reserved_Children : Natural;
      Queued_Children   : Natural;
      Live_Managers     : Natural) return Boolean
   is
     ((Shutdown or else Terminal)
      and then Reserved_Children = 0
      and then Queued_Children = 0
      and then Live_Managers = 0);

   function Next_Incident (Value : Incident_Id) return Incident_Id is
     (Value + 1);

   function Next_Generation
     (Value : Public.Generation) return Public.Generation is
     (Value + 1);

   function Generation_Matches
     (Expected_Id          : Public.Child_Id;
      Expected_Generation : Public.Generation;
      Supplied_Id          : Public.Child_Id;
      Supplied_Generation  : Public.Generation) return Boolean
   is
     (Expected_Id = Supplied_Id
      and then Expected_Generation = Supplied_Generation);

end Flyology.Supervision_Policy;
