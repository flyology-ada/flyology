with Flyology.Supervision;

procedure Flyology.Supervision_Policy.Smoke is
   package Public renames Flyology.Supervision;

   Dependencies : Dependency_Matrix := (others => (others => False));
   Cohort       : Child_Set := (others => False);
   Affected     : Child_Set;
   Start        : Order_Plan;
   Stop         : Order_Plan;

   Limits : constant Restart_Limits :=
     (Burst_Limit    => 2,
      Window         => 10,
      Total_Limit    => 3,
      Initial_Delay  => 2,
      Maximum_Delay  => 8,
      Stability_Time => 20);
   Account   : Restart_Account := (Window_Started => 100, others => 0);
   Admission : Restart_Admission;
   Backoff   : Tick;

   Incident : Incident_Context;
   Child_Observation  : Incident_Observation;
   Parent_Observation : Incident_Observation;
   Was_New : Boolean;

   Generation : Public.Generation := Public.Generation'First;
begin
   --  Child 2 and 3 depend on 1; child 4 depends on both 2 and 3.
   Dependencies (2, 1) := True;
   Dependencies (3, 1) := True;
   Dependencies (4, 2) := True;
   Dependencies (4, 3) := True;
   Plan_Start_Order (4, Dependencies, Start);
   pragma Assert (Start.Valid and then Start.Length = 4);
   pragma Assert
     (Start.Items (1) = 1
      and then Start.Items (2) = 2
      and then Start.Items (3) = 3
      and then Start.Items (4) = 4);

   Plan_Stop_Order (Start, Stop);
   pragma Assert
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
   pragma Assert
     (Affected (1) and then Affected (2)
      and then Affected (3) and then Affected (4));

   Cohort (3) := True;
   Affected_Children
     (4, 2, Public.Restart_Cohort, Cohort, Dependencies, Affected);
   pragma Assert
     (not Affected (1) and then Affected (2)
      and then Affected (3) and then not Affected (4));

   Affected_Children
     (4, 2, Public.Escalate, Cohort, Dependencies, Affected);
   pragma Assert (for all Id in Child_Id => not Affected (Id));

   pragma Assert
     (Transition_Allowed (Public.Configured, Public.Starting));
   pragma Assert
     (Transition_Allowed (Public.Starting, Public.Ready));
   pragma Assert
     (Transition_Allowed (Public.Ready, Public.Running));
   pragma Assert
     (Transition_Allowed (Public.Running, Public.Terminated));
   pragma Assert
     (Transition_Allowed (Public.Terminated, Public.Backing_Off));
   pragma Assert
     (Transition_Allowed (Public.Backing_Off, Public.Restarting));
   pragma Assert
     (Transition_Allowed (Public.Restarting, Public.Starting));
   pragma Assert
     (not Transition_Allowed (Public.Running, Public.Starting));
   for State in Public.Child_State loop
      pragma Assert (not Transition_Allowed (Public.Joined, State));
   end loop;

   pragma Assert
     (not Should_Restart (Public.Never, Public.Unhandled_Exception));
   pragma Assert
     (Should_Restart (Public.On_Failure, Public.Unhandled_Exception));
   pragma Assert
     (not Should_Restart (Public.On_Failure, Public.Normal_Return));
   pragma Assert
     (not Should_Restart (Public.On_Failure, Public.Stuck));
   pragma Assert
     (not Should_Restart (Public.On_Failure, Public.Policy_Exhaustion));
   pragma Assert
     (not Should_Restart (Public.Always, Public.Stuck));
   pragma Assert
     (Should_Restart (Public.Always, Public.Normal_Return));

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

   Account := (Window_Started => 10, others => 0);
   Classify_Attempt (Limits, Account, 10, 11, Admission, Backoff);
   pragma Assert (Admission = Deadline_Exhausted and then Backoff = 2);
   Reset_If_Stable (Limits, 30, 10, Account);
   pragma Assert
     (Account.Total_Used = 0
      and then Account.Window_Used = 0
      and then Account.Consecutive = 0
      and then Account.Window_Started = 30);

   Begin_Attempt (Incident);
   pragma Assert (Incident.Attempt = 1 and then Incident.Attempt_Active);
   Observe_Incident (Incident, Child_Observation, Was_New);
   pragma Assert (Was_New and then Child_Observation.Count = 1);
   Observe_Incident (Incident, Child_Observation, Was_New);
   pragma Assert (not Was_New and then Child_Observation.Count = 1);
   Observe_Incident (Incident, Parent_Observation, Was_New);
   pragma Assert
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
   pragma Assert
     (not Generation_Matches
        (1, Generation, 1, Public.Generation'First));
   Generation := Next_Generation (Public.Generation'Last);
   pragma Assert (Generation = Public.Generation'First);

   pragma Assert (Next_Incident (Incident_Id'Last) = Incident_Id'First);
end Flyology.Supervision_Policy.Smoke;
