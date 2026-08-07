with Flyology.Supervision;
with Interfaces;

--  Internal fixed-capacity policy for supervision state, dependency ordering,
--  generations, incidents, restart accounting, and bounded backoff. Task
--  creation, clocks, cancellation, exception copying, and finalization stay in
--  the structured controller that consumes these decisions.
private package Flyology.Supervision_Policy
  with SPARK_Mode
is
   package Public renames Flyology.Supervision;
   use type Interfaces.Unsigned_64;
   use type Public.Child_State;
   use type Public.Event_Kind;
   use type Public.Restart_Impact;

   Maximum_Children : constant := 16;
   subtype Child_Id is Positive range 1 .. Maximum_Children;
   subtype Child_Count is Natural range 0 .. Maximum_Children;

   type Child_Set is array (Child_Id) of Boolean;
   type Dependency_Matrix is array (Child_Id, Child_Id) of Boolean;
   type Child_Order is array (Child_Id) of Child_Id;

   type Order_Plan is record
      Valid  : Boolean := False;
      Length : Child_Count := 0;
      Items  : Child_Order := (others => Child_Id'First);
   end record;

   --  Report whether Id occurs strictly before Position in Plan.
   function Appears_Before
     (Plan     : Order_Plan;
      Id       : Child_Id;
      Position : Child_Id) return Boolean is
     (for some Earlier in Child_Id =>
        Earlier < Position
        and then Earlier <= Plan.Length
        and then Plan.Items (Earlier) = Id)
   with Ghost;

   --  State the semantic contract for the emitted prefix of a start plan:
   --  children occur at most once and every prerequisite precedes its user. A
   --  successful full-length plan therefore contains every configured child.
   --  Lowest-id selection remains an executable deterministic property tested
   --  by the policy model rather than a second quantified proof obligation.
   function Valid_Start_Order
     (Count        : Child_Count;
      Dependencies : Dependency_Matrix;
      Plan         : Order_Plan) return Boolean is
     (Plan.Length <= Count
      and then
        (for all Position in Child_Id =>
           (if Position <= Plan.Length then
               Plan.Items (Position) <= Count
               and then
                 (for all Earlier in Child_Id =>
                    (if Earlier < Position then
                        Plan.Items (Earlier) /= Plan.Items (Position)))
               and then
                 (for all Prerequisite in Child_Id =>
                    (if Prerequisite <= Count
                       and then Dependencies
                         (Plan.Items (Position), Prerequisite)
                     then Appears_Before (Plan, Prerequisite, Position))))))
   with Ghost;

   --  Return a deterministic, lowest-id-first topological start order.
   procedure Plan_Start_Order
     (Count        : Child_Count;
      Dependencies : Dependency_Matrix;
      Plan         : out Order_Plan)
   with Global => null,
        Post   => Plan.Length <= Count
          and then
            (if Plan.Valid then
                Plan.Length = Count
                and then Valid_Start_Order (Count, Dependencies, Plan)
             else Plan.Length < Count);

   --  Reverse a valid start order for rollback or shutdown.
   procedure Plan_Stop_Order
     (Start : Order_Plan;
      Stop  : out Order_Plan)
   with Global => null,
        Pre    => Start.Valid,
        Post   => Stop.Valid
          and then Stop.Length = Start.Length
          and then
            (for all Position in Child_Id =>
               (if Position <= Stop.Length then
                   Stop.Items (Position) =
                     Start.Items
                       (Child_Id (Start.Length - Position + 1))));

   --  Report whether a set contains no unconfigured child and is closed under
   --  every configured dependent edge. With Failed included, this guarantees
   --  complete transitive-dependent recovery.
   function Dependent_Recovery_Closed
     (Count        : Child_Count;
      Dependencies : Dependency_Matrix;
      Affected     : Child_Set) return Boolean is
     ((for all Id in Child_Id =>
         (if Id > Count then not Affected (Id)))
      and then
        (for all User in Child_Id =>
           (for all Prerequisite in Child_Id =>
              (if User <= Count
                 and then Prerequisite <= Count
                 and then Dependencies (User, Prerequisite)
                 and then Affected (Prerequisite)
               then Affected (User)))))
   with Ghost;

   --  Compute the logical children affected by one explicit impact. For
   --  Restart_Dependents, dependency edges are followed transitively from the
   --  failed prerequisite to every configured user.
   procedure Affected_Children
     (Count        : Child_Count;
      Failed       : Child_Id;
      Impact       : Public.Restart_Impact;
      Cohort       : Child_Set;
      Dependencies : Dependency_Matrix;
      Affected     : out Child_Set)
   with Global => null,
        Pre    => Failed <= Count,
        Post   =>
          (case Impact is
                when Public.Escalate =>
                   (for all Id in Child_Id => not Affected (Id)),
                when Public.Isolate_Child =>
                   (for all Id in Child_Id =>
                      Affected (Id) = (Id = Failed)),
                when Public.Restart_Cohort =>
                   (for all Id in Child_Id =>
                      Affected (Id) =
                        (Id = Failed
                         or else (Id <= Count and then Cohort (Id)))),
                when Public.Restart_Dependents =>
                   Affected (Failed)
                   and then Dependent_Recovery_Closed
                     (Count, Dependencies, Affected));

   --  Decide whether a lifecycle transition is legal in the scalar model.
   function Transition_Allowed
     (From : Public.Child_State;
      To   : Public.Child_State) return Boolean
   with Global => null;

   --  Decide whether an event may retain its before/after edge. Events that
   --  represent lifecycle, stop, or restart admission must follow the scalar
   --  lifecycle model; observational events and same-state events carry no
   --  additional state transition.
   function Recorded_Transition_Allowed
     (Kind   : Public.Event_Kind;
      Before : Public.Child_State;
      After  : Public.Child_State) return Boolean
   with Global => null,
        Post   => Recorded_Transition_Allowed'Result =
          (Before = After
           or else Kind not in Public.Lifecycle_Changed |
             Public.Stop_Published | Public.Restart_Admitted
           or else Transition_Allowed (Before, After));

   --  Classify outcomes that On_Failure treats as restartable failures.
   function Is_Failure
     (Kind : Public.Termination_Kind) return Boolean
   with Global => null;

   --  Apply the child restart kind to one terminal classification.
   function Should_Restart
     (Policy : Public.Restart_Kind;
      Kind   : Public.Termination_Kind) return Boolean
   with Global => null,
        Post   =>
          (if Kind in Public.No_Termination | Public.Supervisor_Shutdown |
              Public.Stuck | Public.Policy_Exhaustion
           then not Should_Restart'Result
           else
             (case Policy is
                 when Public.Never => not Should_Restart'Result,
                 when Public.On_Failure =>
                    Should_Restart'Result = Is_Failure (Kind),
                 when Public.Always => Should_Restart'Result));

   --  Fixed monotonic time representation supplied by the controller.
   type Tick is range 0 .. Long_Long_Integer'Last;
   subtype Attempt_Count is Natural;

   type Restart_Limits is record
      Burst_Limit    : Attempt_Count range 1 .. Attempt_Count'Last;
      Window         : Tick range 1 .. Tick'Last;
      Total_Limit    : Attempt_Count range 1 .. Attempt_Count'Last;
      Initial_Delay  : Tick;
      Maximum_Delay  : Tick;
      Stability_Time : Tick range 1 .. Tick'Last;
   end record;

   type Restart_Account is record
      Total_Used       : Attempt_Count := 0;
      Window_Used      : Attempt_Count := 0;
      Consecutive      : Attempt_Count := 0;
      Window_Started   : Tick := 0;
   end record;

   type Restart_Admission is
     (Restart_Admitted,
      Burst_Exhausted,
      Total_Exhausted,
      Deadline_Exhausted);

   --  Return capped exponential backoff for the next one-based attempt.
   function Backoff_For
     (Attempt       : Attempt_Count;
      Initial_Delay : Tick;
      Maximum_Delay : Tick) return Tick
   with Global => null,
        Pre    => Attempt > 0 and then Initial_Delay <= Maximum_Delay,
        Post   => Backoff_For'Result in Initial_Delay .. Maximum_Delay
          and then
            (if Attempt = 1 then Backoff_For'Result = Initial_Delay);

   --  Classify one possible attempt without mutating its accounting state.
   procedure Classify_Attempt
     (Limits            : Restart_Limits;
      Account           : Restart_Account;
      Now               : Tick;
      Recovery_Deadline : Tick;
      Admission         : out Restart_Admission;
      Backoff           : out Tick)
   with Global => null,
        Pre    => Limits.Initial_Delay <= Limits.Maximum_Delay
          and then Account.Total_Used <= Limits.Total_Limit
          and then Account.Window_Used <= Limits.Burst_Limit
          and then Account.Consecutive < Attempt_Count'Last
          and then Account.Window_Started <= Now
          and then Now <= Recovery_Deadline,
        Post   => Backoff =
          Backoff_For
            (Account.Consecutive + 1,
             Limits.Initial_Delay,
             Limits.Maximum_Delay)
          and then Backoff <= Limits.Maximum_Delay;

   --  Commit exactly one previously admitted restart attempt.
   procedure Record_Attempt
     (Limits  : Restart_Limits;
      Now     : Tick;
      Account : in out Restart_Account)
   with Global => null,
        Pre    => Account.Total_Used < Limits.Total_Limit
          and then Account.Consecutive < Attempt_Count'Last
          and then Account.Window_Started <= Now
          and then
            (if Now - Account.Window_Started < Limits.Window then
                Account.Window_Used < Limits.Burst_Limit),
        Post   => Account.Total_Used = Account.Total_Used'Old + 1
          and then Account.Consecutive = Account.Consecutive'Old + 1
          and then
            (if Now - Account.Window_Started'Old >= Limits.Window then
                Account.Window_Started = Now
                and then Account.Window_Used = 1
             else Account.Window_Started = Account.Window_Started'Old
                and then Account.Window_Used =
                  Account.Window_Used'Old + 1);

   --  Close a recovery incident after a generation remains ready long enough.
   procedure Reset_If_Stable
     (Limits      : Restart_Limits;
      Now         : Tick;
      Ready_Since : Tick;
      Account     : in out Restart_Account)
   with Global => null,
        Pre    => Ready_Since <= Now,
        Post   =>
          (if Now - Ready_Since >= Limits.Stability_Time then
              Account.Total_Used = 0
              and then Account.Window_Used = 0
              and then Account.Consecutive = 0
              and then Account.Window_Started = Now
           else Account = Account'Old);

   subtype Incident_Id is Interfaces.Unsigned_64 range
     1 .. Interfaces.Unsigned_64'Last;

   type Incident_Context is record
      Id             : Incident_Id := Incident_Id'First;
      Attempt        : Attempt_Count := 0;
      Attempt_Active : Boolean := False;
   end record;

   type Incident_Observation is record
      Last_Id      : Incident_Id := Incident_Id'First;
      Last_Attempt : Attempt_Count := 0;
      Seen         : Boolean := False;
      Count        : Attempt_Count := 0;
   end record;

   --  Begin one tree-wide recovery attempt. Descendants and ancestors pass the
   --  same active incident rather than minting nested attempts.
   procedure Begin_Attempt (Incident : in out Incident_Context)
   with Global => null,
        Pre    => not Incident.Attempt_Active
          and then Incident.Attempt < Attempt_Count'Last,
        Post   => Incident.Attempt_Active
          and then Incident.Id = Incident.Id'Old
          and then Incident.Attempt = Incident.Attempt'Old + 1;

   --  Finish one tree-wide recovery attempt.
   procedure End_Attempt (Incident : in out Incident_Context)
   with Global => null,
        Pre    => Incident.Attempt_Active,
        Post   => not Incident.Attempt_Active
          and then Incident.Id = Incident.Id'Old
          and then Incident.Attempt = Incident.Attempt'Old;

   --  Account an incident attempt at most once at one supervisor node.
   procedure Observe_Incident
     (Incident   : Incident_Context;
      Observation : in out Incident_Observation;
      Was_New     : out Boolean)
   with Global => null,
        Pre    => Incident.Attempt_Active
          and then Observation.Count < Attempt_Count'Last,
        Post   =>
          Was_New =
            (not Observation.Seen'Old
             or else Observation.Last_Id'Old /= Incident.Id
             or else Observation.Last_Attempt'Old /= Incident.Attempt)
          and then
            (if Was_New then
                Observation.Seen
                and then Observation.Last_Id = Incident.Id
                and then Observation.Last_Attempt = Incident.Attempt
                and then Observation.Count = Observation.Count'Old + 1
             else Observation = Observation'Old);

   --  Report whether a controller has already accounted the exact public
   --  incident attempt. Static and dynamic controllers use this proved
   --  predicate before advancing a replacement failure to the next attempt.
   function Same_Incident_Attempt
     (Seen             : Boolean;
      Previous_Id      : Public.Incident_Id;
      Previous_Attempt : Public.Incident_Attempt;
      Current_Id       : Public.Incident_Id;
      Current_Attempt  : Public.Incident_Attempt) return Boolean
   with Global => null,
        Post   => Same_Incident_Attempt'Result =
          (Seen
           and then Previous_Id = Current_Id
           and then Previous_Attempt = Current_Attempt);

   --  Report whether a dynamic family has reached its structured join
   --  boundary. Outstanding reservations are included so Run cannot return
   --  while a concurrent Start is copying or finalizing typed input.
   function Family_Finished
     (Shutdown          : Boolean;
      Terminal          : Boolean;
      Reserved_Children : Natural;
      Queued_Children   : Natural;
      Live_Managers     : Natural) return Boolean
   with Global => null,
        Post   => Family_Finished'Result =
          ((Shutdown or else Terminal)
           and then Reserved_Children = 0
           and then Queued_Children = 0
           and then Live_Managers = 0);

   --  Derive dynamic-family admission from authoritative controller state.
   --  No separate mutable open flag can disagree with shutdown or terminal
   --  escalation.
   function Family_Admission_Open
     (Configured : Boolean;
      Shutdown   : Boolean;
      Terminal   : Boolean) return Boolean
   with Global => null,
        Post   => Family_Admission_Open'Result =
          (Configured and then not Shutdown and then not Terminal);

   --  Decide whether an exact-generation family stop command may be applied.
   --  A queued generation has not activated yet; a managed generation must
   --  still own a live task. A terminated generation awaiting replacement is
   --  deliberately rejected even though its slot remains managed.
   function Family_Stop_Command_Allowed
     (Current : Boolean;
      Queued  : Boolean;
      Managed : Boolean;
      Live    : Boolean) return Boolean
   with Global => null,
        Post   => Family_Stop_Command_Allowed'Result =
          (Current and then (Queued or else (Managed and then Live)));

   --  Report whether an incident id can advance without reuse.
   function Incident_Can_Advance (Value : Incident_Id) return Boolean is
     (Value < Incident_Id'Last);

   --  Advance an incident id without wrapping to a stale identity.
   function Next_Incident (Value : Incident_Id) return Incident_Id
   with Global => null,
        Pre    => Incident_Can_Advance (Value),
        Post   => Next_Incident'Result = Value + 1;

   --  Report whether a generation can advance without making an old handle
   --  current again.
   function Generation_Can_Advance
     (Value : Public.Generation) return Boolean is
     (Value < Public.Generation'Last);

   --  Advance a child generation without wrapping to a stale identity.
   function Next_Generation
     (Value : Public.Generation) return Public.Generation
   with Global => null,
        Pre    => Generation_Can_Advance (Value),
        Post   => Next_Generation'Result = Value + 1;

   --  Reject stale generation-qualified observations or commands.
   function Generation_Matches
     (Expected_Id         : Public.Child_Id;
      Expected_Generation : Public.Generation;
      Supplied_Id         : Public.Child_Id;
      Supplied_Generation : Public.Generation) return Boolean
   with Global => null,
        Post   => Generation_Matches'Result =
          (Expected_Id = Supplied_Id
           and then Expected_Generation = Supplied_Generation);

   --  Accept publication for the current generation or exactly its successor
   --  while replacement is pending. This prevents a stale, skipped, or
   --  wrapped generation from becoming the live family generation.
   function Generation_Start_Allowed
     (Expected_Id         : Public.Child_Id;
      Expected_Generation : Public.Generation;
      Supplied_Id         : Public.Child_Id;
      Supplied_Generation : Public.Generation;
      Restart_Pending     : Boolean) return Boolean
   with Global => null,
        Post   => Generation_Start_Allowed'Result =
          (Generation_Matches
             (Expected_Id,
              Expected_Generation,
              Supplied_Id,
              Supplied_Generation)
           or else
             (Restart_Pending
              and then Expected_Id = Supplied_Id
              and then Generation_Can_Advance (Expected_Generation)
              and then Supplied_Generation =
                Next_Generation (Expected_Generation)));

end Flyology.Supervision_Policy;
