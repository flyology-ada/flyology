with Ada.Real_Time;
with Flyology.Supervision;
with Flyology.Supervision_Windows;

procedure Flyology.Supervision_Policy.Smoke is
   use Ada.Real_Time;
   package Public renames Flyology.Supervision;

   Dependencies : Dependency_Matrix := (others => (others => False));
   Cohort       : Child_Set := (others => False);
   Affected     : Child_Set;
   Start        : Order_Plan;
   Stop         : Order_Plan;

   Limits    : constant Restart_Limits :=
     (Burst_Limit    => 2,
      Window         => 10,
      Total_Limit    => 3,
      Initial_Delay  => 2,
      Maximum_Delay  => 8,
      Stability_Time => 20);
   Account   : Restart_Account (Limits.Burst_Limit);
   Admission : Restart_Admission;
   Backoff   : Tick;

   Incident           : Incident_Context;
   Child_Observation  : Incident_Observation;
   Parent_Observation : Incident_Observation;
   Was_New            : Boolean;

   Generation        : Public.Generation := Public.Generation'First;
   High_Id           : constant Public.Child_Id := 2**40;
   Sliding_Limits    : constant Restart_Limits :=
     (Burst_Limit    => 3,
      Window         => 50,
      Total_Limit    => 10,
      Initial_Delay  => 0,
      Maximum_Delay  => 0,
      Stability_Time => 100);
   Sliding_Account   : Restart_Account (Sliding_Limits.Burst_Limit);
   Sliding_Window    : Flyology.Supervision_Windows.History;
   Large_Window      : Flyology.Supervision_Windows.History;
   Base_Time         : constant Ada.Real_Time.Time := Ada.Real_Time.Time_First;
   type Time_Sequence is array (Positive range <>) of Tick;
   Boundary_Attempts : constant Time_Sequence := (0, 49, 49, 50);
begin
   Flyology.Supervision_Windows.Initialize
     (Sliding_Window, Sliding_Limits.Burst_Limit);
   --  Child 2 and 3 depend on 1; child 4 depends on both 2 and 3.
   Dependencies (2, 1) := True;
   Dependencies (3, 1) := True;
   Dependencies (4, 2) := True;
   Dependencies (4, 3) := True;
   Plan_Start_Order (4, Dependencies, Start);
   pragma Assert (Start.Valid and then Start.Length = 4);
   pragma
     Assert
       (Start.Items (1) = 1
          and then Start.Items (2) = 2
          and then Start.Items (3) = 3
          and then Start.Items (4) = 4);

   Plan_Stop_Order (Start, Stop);
   pragma
     Assert
       (Stop.Valid
          and then Stop.Items (1) = 4
          and then Stop.Items (2) = 3
          and then Stop.Items (3) = 2
          and then Stop.Items (4) = 1);

   Dependencies (1, 4) := True;
   Plan_Start_Order (4, Dependencies, Start);
   pragma Assert (not Start.Valid);
   Dependencies (1, 4) := False;

   Affected_Children
     (4, 1, Public.Restart_Dependents, Cohort, Dependencies, Affected);
   pragma
     Assert
       (Affected (1)
          and then Affected (2)
          and then Affected (3)
          and then Affected (4));

   Cohort (3) := True;
   Affected_Children
     (4, 2, Public.Restart_Cohort, Cohort, Dependencies, Affected);
   pragma
     Assert
       (not Affected (1)
          and then Affected (2)
          and then Affected (3)
          and then not Affected (4));

   Affected_Children (4, 2, Public.Escalate, Cohort, Dependencies, Affected);
   pragma Assert (for all Id in Child_Id => not Affected (Id));

   pragma Assert (Transition_Allowed (Public.Configured, Public.Starting));
   pragma Assert (Transition_Allowed (Public.Starting, Public.Ready));
   pragma Assert (Transition_Allowed (Public.Starting, Public.Running));
   pragma Assert (Transition_Allowed (Public.Ready, Public.Running));
   pragma Assert (Transition_Allowed (Public.Running, Public.Terminated));
   pragma Assert (Transition_Allowed (Public.Terminated, Public.Backing_Off));
   pragma Assert (Transition_Allowed (Public.Backing_Off, Public.Restarting));
   pragma Assert (Transition_Allowed (Public.Backing_Off, Public.Joined));
   pragma Assert (Transition_Allowed (Public.Restarting, Public.Starting));
   pragma Assert (not Transition_Allowed (Public.Running, Public.Starting));
   for State in Public.Child_State loop
      pragma Assert (not Transition_Allowed (Public.Joined, State));
   end loop;

   pragma
     Assert
       (Recorded_Transition_Allowed
          (Public.Restart_Admitted, Public.Terminated, Public.Backing_Off));
   pragma
     Assert
       (not Recorded_Transition_Allowed
              (Public.Lifecycle_Changed, Public.Running, Public.Starting));
   pragma
     Assert
       (Recorded_Transition_Allowed
          (Public.Supervisor_Stopped, Public.Running, Public.Running));

   pragma
     Assert (not Should_Restart (Public.Never, Public.Unhandled_Exception));
   pragma
     Assert (Should_Restart (Public.On_Failure, Public.Unhandled_Exception));
   pragma Assert (Should_Restart (Public.On_Failure, Public.Unhealthy));
   pragma
     Assert (Should_Restart (Public.On_Failure, Public.Restart_Requested));
   pragma
     Assert (not Should_Restart (Public.On_Failure, Public.Normal_Return));
   pragma Assert (not Should_Restart (Public.On_Failure, Public.Stuck));
   pragma
     Assert (not Should_Restart (Public.On_Failure, Public.Policy_Exhaustion));
   pragma Assert (not Should_Restart (Public.Always, Public.Stuck));
   pragma
     Assert (not Should_Restart (Public.Always, Public.Supervisor_Shutdown));
   pragma Assert (Should_Restart (Public.Always, Public.Normal_Return));

   pragma Assert (Backoff_For (Attempt_Count'Last, 0, 8) = 0);

   Classify_Attempt (Limits, Account, 100, 200, Admission, Backoff);
   pragma Assert (Admission = Restart_Admitted and then Backoff = 2);
   Record_Attempt (Limits, 100, Account);
   Classify_Attempt (Limits, Account, 101, 200, Admission, Backoff);
   pragma Assert (Admission = Restart_Admitted and then Backoff = 4);
   Record_Attempt (Limits, 101, Account);
   Classify_Attempt (Limits, Account, 102, 200, Admission, Backoff);
   pragma Assert (Admission = Burst_Exhausted and then Backoff = 8);

   Classify_Attempt (Limits, Account, 111, 200, Admission, Backoff);
   pragma Assert (Admission = Restart_Admitted and then Backoff = 8);
   Record_Attempt (Limits, 111, Account);
   Classify_Attempt (Limits, Account, 112, 200, Admission, Backoff);
   pragma Assert (Admission = Total_Exhausted);

   --  A tumbling counter admits a fifth attempt at 51 after the 0 boundary
   --  expires. The attempts at 49, 49, and 50 must still fill the window.
   for At_Time of Boundary_Attempts loop
      Classify_Attempt
        (Sliding_Limits, Sliding_Account, At_Time, 500, Admission, Backoff);
      pragma Assert (Admission = Restart_Admitted);
      Record_Attempt (Sliding_Limits, At_Time, Sliding_Account);
      pragma
        Assert
          (Flyology.Supervision_Windows.Has_Capacity
             (Sliding_Window,
              Base_Time + Ada.Real_Time.Milliseconds (Integer (At_Time)),
              Ada.Real_Time.Milliseconds (50),
              3));
      Flyology.Supervision_Windows.Record_Attempt
        (Sliding_Window,
         Base_Time + Ada.Real_Time.Milliseconds (Integer (At_Time)));
   end loop;
   Classify_Attempt
     (Sliding_Limits, Sliding_Account, 51, 500, Admission, Backoff);
   pragma Assert (Admission = Burst_Exhausted);
   pragma
     Assert
       (not Flyology.Supervision_Windows.Has_Capacity
              (Sliding_Window,
               Base_Time + Ada.Real_Time.Milliseconds (51),
               Ada.Real_Time.Milliseconds (50),
               3));
   Classify_Attempt
     (Sliding_Limits, Sliding_Account, 99, 500, Admission, Backoff);
   pragma Assert (Admission = Restart_Admitted);
   pragma
     Assert
       (Flyology.Supervision_Windows.Has_Capacity
          (Sliding_Window,
           Base_Time + Ada.Real_Time.Milliseconds (99),
           Ada.Real_Time.Milliseconds (50),
           3));
   Flyology.Supervision_Windows.Reset (Sliding_Window);
   pragma
     Assert
       (Flyology.Supervision_Windows.Has_Capacity
          (Sliding_Window,
           Base_Time + Ada.Real_Time.Milliseconds (51),
           Ada.Real_Time.Milliseconds (50),
           3));
   Flyology.Supervision_Windows.Record_Attempt
     (Sliding_Window, Base_Time + Ada.Real_Time.Milliseconds (51));
   pragma Assert (Sliding_Window.Count = 1);

   --  Cross the former proposed fixed capacity; the configured limit alone
   --  determines the retained history size.
   Flyology.Supervision_Windows.Initialize (Large_Window, 65);
   for Index in 1 .. 65 loop
      Flyology.Supervision_Windows.Record_Attempt (Large_Window, Base_Time);
   end loop;
   pragma
     Assert
       (not Flyology.Supervision_Windows.Has_Capacity
              (Large_Window, Base_Time, Ada.Real_Time.Milliseconds (50), 65));
   pragma
     Assert
       (Flyology.Supervision_Windows.Has_Capacity
          (Large_Window,
           Base_Time + Ada.Real_Time.Milliseconds (50),
           Ada.Real_Time.Milliseconds (50),
           65));

   Account := (Capacity => Limits.Burst_Limit, others => <>);
   Classify_Attempt (Limits, Account, 10, 11, Admission, Backoff);
   pragma Assert (Admission = Deadline_Exhausted and then Backoff = 2);
   Reset_If_Stable (Limits, 30, 10, Account);
   pragma
     Assert
       (Account.Total_Used = 0
          and then Account.Window_Used = 0
          and then Account.Consecutive = 0
          and then (for all Index in Account.Times'Range =>
                      Account.Times (Index) = 0));

   Begin_Attempt (Incident);
   pragma Assert (Incident.Attempt = 1 and then Incident.Attempt_Active);
   Observe_Incident (Incident, Child_Observation, Was_New);
   pragma Assert (Was_New and then Child_Observation.Count = 1);
   Observe_Incident (Incident, Child_Observation, Was_New);
   pragma Assert (not Was_New and then Child_Observation.Count = 1);
   Observe_Incident (Incident, Parent_Observation, Was_New);
   pragma
     Assert
       (Was_New
          and then Parent_Observation.Count = 1
          and then Incident.Attempt = 1);
   End_Attempt (Incident);
   Begin_Attempt (Incident);
   Observe_Incident (Incident, Child_Observation, Was_New);
   pragma Assert (Was_New and then Child_Observation.Count = 2);

   Generation := Next_Generation (Generation);
   pragma Assert (Generation = 2);
   pragma Assert (Generation_Matches (1, Generation, 1, Generation));
   pragma
     Assert (Generation_Matches (High_Id, Generation, High_Id, Generation));
   pragma
     Assert
       (not Generation_Matches
              (High_Id, Generation, High_Id, Public.Generation'First));
   pragma
     Assert
       (Authority_Matches (7, High_Id, Generation, 7, High_Id, Generation));
   pragma
     Assert
       (not Authority_Matches
              (7, High_Id, Generation, 8, High_Id, Generation));
   pragma
     Assert
       (Generation_Start_Allowed
          (High_Id, Generation, High_Id, Generation, False));
   pragma
     Assert
       (Generation_Start_Allowed
          (High_Id, Generation, High_Id, Next_Generation (Generation), True));
   pragma
     Assert
       (not Generation_Start_Allowed
              (High_Id,
               Generation,
               High_Id,
               Next_Generation (Generation),
               False));
   pragma
     Assert
       (not Generation_Start_Allowed
              (High_Id,
               Generation,
               High_Id + 1,
               Next_Generation (Generation),
               True));
   pragma Assert (not Generation_Can_Advance (Public.Generation'Last));

   pragma Assert (Incident_Can_Advance (Incident_Id'First));
   pragma Assert (Next_Incident (Incident_Id'First) = Incident_Id'First + 1);
   pragma Assert (not Incident_Can_Advance (Incident_Id'Last));

   pragma Assert (Same_Incident_Attempt (True, 7, 3, 7, 3));
   pragma Assert (not Same_Incident_Attempt (False, 7, 3, 7, 3));
   pragma Assert (not Same_Incident_Attempt (True, 7, 3, 8, 3));

   pragma Assert (Family_Finished (True, False, 0, 0, 0));
   pragma Assert (Family_Finished (False, True, 0, 0, 0));
   pragma Assert (not Family_Finished (True, False, 1, 0, 0));
   pragma Assert (not Family_Finished (True, False, 0, 1, 0));
   pragma Assert (not Family_Finished (True, False, 0, 0, 1));

   pragma Assert (Family_Admission_Open (True, False, False));
   pragma Assert (not Family_Admission_Open (False, False, False));
   pragma Assert (not Family_Admission_Open (True, True, False));
   pragma Assert (not Family_Admission_Open (True, False, True));

   pragma
     Assert
       (Family_Stop_Command_Allowed
          (Current => True, Queued => True, Managed => False, Live => False));
   pragma
     Assert
       (Family_Stop_Command_Allowed
          (Current => True, Queued => False, Managed => True, Live => True));
   pragma
     Assert
       (not Family_Stop_Command_Allowed
              (Current => True,
               Queued  => False,
               Managed => True,
               Live    => False));
   pragma
     Assert
       (not Family_Stop_Command_Allowed
              (Current => False,
               Queued  => True,
               Managed => False,
               Live    => False));

   pragma
     Assert
       (Family_Intervention_Command_Allowed
          (Current          => True,
           Managed          => True,
           Live             => True,
           Ready            => True,
           Stop_Pending     => False,
           Shutdown         => False,
           Terminal         => False,
           Recovery_Pending => False));
   pragma
     Assert
       (not Family_Intervention_Command_Allowed
              (Current          => True,
               Managed          => True,
               Live             => True,
               Ready            => True,
               Stop_Pending     => True,
               Shutdown         => False,
               Terminal         => False,
               Recovery_Pending => False));
   pragma
     Assert
       (not Family_Intervention_Command_Allowed
              (Current          => True,
               Managed          => True,
               Live             => True,
               Ready            => True,
               Stop_Pending     => False,
               Shutdown         => True,
               Terminal         => False,
               Recovery_Pending => False));

   pragma
     Assert
       (Family_Generation_Start_Allowed
          (Generation_Allowed => True,
           Managed            => True,
           Stop_Pending       => False,
           Shutdown           => False,
           Terminal           => False));
   pragma
     Assert
       (not Family_Generation_Start_Allowed
              (Generation_Allowed => True,
               Managed            => True,
               Stop_Pending       => False,
               Shutdown           => True,
               Terminal           => False));
   pragma
     Assert
       (not Family_Replacement_Wait_Allowed
              (Managed      => True,
               Backing_Off  => True,
               Stop_Pending => True,
               Shutdown     => False,
               Terminal     => False));

   pragma
     Assert
       (not Authority_Matches
              (1,
               Public.Child_Id'First,
               Public.Generation'First,
               0,
               Public.Child_Id'First,
               Public.Generation'First));
end Flyology.Supervision_Policy.Smoke;
