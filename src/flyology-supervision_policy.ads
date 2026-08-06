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

   --  Return a deterministic, lowest-id-first topological start order.
   procedure Plan_Start_Order
     (Count        : Child_Count;
      Dependencies : Dependency_Matrix;
      Plan         : out Order_Plan)
   with Global => null,
        Post   => Plan.Length <= Count
          and then (if Plan.Valid then Plan.Length = Count);

   --  Reverse a valid start order for rollback or shutdown.
   procedure Plan_Stop_Order
     (Start : Order_Plan;
      Stop  : out Order_Plan)
   with Global => null,
        Pre    => Start.Valid,
        Post   => Stop.Valid
          and then Stop.Length = Start.Length;

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
          (if Impact = Public.Escalate then
              (for all Id in Child_Id => not Affected (Id))
           else Affected (Failed));

   --  Decide whether a lifecycle transition is legal in the scalar model.
   function Transition_Allowed
     (From : Public.Child_State;
      To   : Public.Child_State) return Boolean
   with Global => null;

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
          (if Kind in Public.No_Termination | Public.Stuck |
              Public.Policy_Exhaustion
           then not Should_Restart'Result
           else
             (case Policy is
                 when Public.Never => not Should_Restart'Result,
                 when Public.On_Failure =>
                    Should_Restart'Result = Is_Failure (Kind),
                 when Public.Always => Should_Restart'Result));

   --  Fixed monotonic time representation supplied by the controller.
   type Tick is range 0 .. Long_Long_Integer'Last;
   subtype Attempt_Count is Natural range 0 .. 65_535;

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
        Post   => Backoff_For'Result <= Maximum_Delay;

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
        Post   => Backoff <= Limits.Maximum_Delay;

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
          and then Account.Consecutive = Account.Consecutive'Old + 1;

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
          (if Was_New then
              Observation.Count = Observation.Count'Old + 1
           else Observation = Observation'Old);

   --  Advance an incident id while reserving zero as invalid.
   function Next_Incident (Value : Incident_Id) return Incident_Id
   with Global => null;

   --  Advance a child generation while reserving zero as invalid.
   function Next_Generation
     (Value : Public.Generation) return Public.Generation
   with Global => null;

   --  Reject stale generation-qualified observations or commands.
   function Generation_Matches
     (Expected_Id         : Child_Id;
      Expected_Generation : Public.Generation;
      Supplied_Id         : Child_Id;
      Supplied_Generation : Public.Generation) return Boolean
   with Global => null,
        Post   => Generation_Matches'Result =
          (Expected_Id = Supplied_Id
           and then Expected_Generation = Supplied_Generation);

end Flyology.Supervision_Policy;
