with Ada.Exceptions;
with Ada.Task_Identification;
with Flyology.Supervision_Policy;
with Interfaces;

package body Flyology.Supervision.Static is
   use type Ada.Real_Time.Time;
   use type Ada.Real_Time.Time_Span;
   use type Ada.Exceptions.Exception_Id;
   use type Interfaces.Unsigned_64;

   package Policy renames Flyology.Supervision_Policy;

   function Empty_Summary
     (Kind : Termination_Kind) return Termination_Summary is
     ((Kind           => Kind,
       Exception_Id   => Ada.Exceptions.Null_Id,
       Task_Id        => Ada.Task_Identification.Null_Task_Id,
       Message_Length => 0,
       Message        => (others => ' ')));

   function Failure_Summary
     (Occurrence : Ada.Exceptions.Exception_Occurrence;
      Kind       : Termination_Kind := Unhandled_Exception)
      return Termination_Summary
   is
      Message : constant String :=
        Ada.Exceptions.Exception_Message (Occurrence);
      Length  : constant Diagnostic_Length :=
        Diagnostic_Length'Min
          (Diagnostic_Length'Last, Message'Length);
      Result  : Termination_Summary := Empty_Summary (Kind);
   begin
      Result.Exception_Id := Ada.Exceptions.Exception_Identity (Occurrence);
      Result.Message_Length := Length;
      if Length > 0 then
         Result.Message (1 .. Length) :=
           Message (Message'First .. Message'First + Length - 1);
      end if;
      return Result;
   end Failure_Summary;

   protected body Lifecycle is
      procedure Configure
        (Specs        : Specification_Array;
         Ids          : Logical_Id_Array;
         Dependencies : Dependency_Matrix;
         Cohorts      : Cohort_Matrix;
         Start_Order  : Child_Order;
         Stop_Order   : Child_Order;
         Inherited    : Incident_Context)
      is
      begin
         if Run_Used then
            raise Program_Error with "supervisor is one-shot";
         end if;
         Run_Used := True;
         Configured := True;
         Child_Specs := Specs;
         Child_Ids := Ids;
         Child_Dependencies := Dependencies;
         Child_Cohorts := Cohorts;
         Starts := Start_Order;
         Stops := Stop_Order;
         Inherited_Incident := Inherited;
         Phase := Starting_Children;
         Start_Position := 0;
         Stop_Position := 0;
         Managers_Done := 0;
         Terminal :=
           (Outcome     => Shutdown_Completed,
            Child       => Child_Ids (Child_Kind'First),
            Generation  => Generation'First,
            Termination => Empty_Summary (No_Termination),
            Incident    => Inherited);

         for Child in Child_Kind loop
            Snapshots (Child) :=
              (Id          => Child_Ids (Child),
               Generation  => Generation'First,
               State       => Flyology.Supervision.Configured,
               Lane        => Child_Specs (Child).Lane,
               Has_Group   => Child_Specs (Child).Has_Group,
               Group       => Child_Specs (Child).Group,
               Termination => Empty_Summary (No_Termination),
               Attempts    => 0,
               Backoff     => Ada.Real_Time.Time_Span_Zero,
               Ready       => False,
               Live        => False,
               Escalated   => False);
         end loop;
      end Configure;

      procedure Record_Event
        (Child       : Child_Kind;
         Kind        : Event_Kind;
         Before      : Child_State;
         After       : Child_State;
         Now         : Ada.Real_Time.Time;
         Termination : Termination_Kind := No_Termination;
         Incident    : Incident_Context := No_Incident;
         Backoff     : Ada.Real_Time.Time_Span :=
           Ada.Real_Time.Time_Span_Zero)
      is
         Slot : Positive;
      begin
         if Event_Sequence_Exhausted then
            return;
         elsif Event_Last_Sequence = Event_Sequence'Last then
            Event_Sequence_Exhausted := True;
            return;
         end if;

         Event_Last_Sequence := Event_Last_Sequence + 1;
         if Event_Length < Event_Capacity then
            Slot :=
              Positive
                (((Event_First - Event_Buffer'First + Event_Length)
                  mod Event_Capacity) + Event_Buffer'First);
            Event_Length := Event_Length + 1;
         else
            Slot := Event_First;
            Event_First :=
              (if Event_First = Event_Buffer'Last
               then Event_Buffer'First
               else Event_First + 1);
         end if;
         Events (Slot) :=
           (Sequence    => Event_Last_Sequence,
            Timestamp   => Now,
            Kind        => Kind,
            Child       => Child_Ids (Child),
            Generation  => Snapshots (Child).Generation,
            Before      => Before,
            After       => After,
            Lane        => Child_Specs (Child).Lane,
            Has_Group   => Child_Specs (Child).Has_Group,
            Group       => Child_Specs (Child).Group,
            Termination => Termination,
            Incident    => Incident,
            Backoff     => Backoff);
      end Record_Event;

      procedure Begin_Terminal_Stop
        (Outcome     : Supervisor_Outcome;
         Child       : Child_Kind;
         Termination : Termination_Summary)
      is
      begin
         if Phase not in Stopping_Children | Finished then
            Terminal :=
              (Outcome     => Outcome,
               Child       => Child_Ids (Child),
               Generation  => Snapshots (Child).Generation,
               Termination => Termination,
               Incident    =>
                 (if Active (Active_Incident)
                  then Active_Incident
                  else Inherited_Incident));
            Phase := Stopping_Children;
            Stop_Position := 1;
            Snapshots (Child).Escalated :=
              Outcome in Recovery_Exhausted | Failure_Escalated |
                Child_Stuck;
            Record_Event
              (Child,
               (if Outcome = Child_Stuck
                then Child_Became_Stuck
                else Recovery_Escalated),
               Snapshots (Child).State,
               Snapshots (Child).State,
               Ada.Real_Time.Clock,
               Termination.Kind,
               Terminal.Incident);
            Advance_Stop_Order;
         end if;
      end Begin_Terminal_Stop;

      procedure Advance_Stop_Order is
         Child : Child_Kind;
      begin
         while Phase = Stopping_Children
           and then Stop_Position in Order_Position
         loop
            Child := Stops (Order_Position (Stop_Position));
            exit when Snapshots (Child).Live;
            Snapshots (Child).Ready := False;
            Snapshots (Child).Backoff := Ada.Real_Time.Time_Span_Zero;
            Snapshots (Child).State := Joined;
            Stop_Position := Stop_Position + 1;
         end loop;
         if Phase = Stopping_Children
           and then Stop_Position > Child_Total
         then
            Phase := Finished;
         end if;
      end Advance_Stop_Order;

      procedure Advance_Recovery_Stop_Order is
         Child : Child_Kind;
      begin
         while Phase = Recovery_Stopping
           and then Recovery_Stop_Position < Child_Total
         loop
            Recovery_Stop_Position := Recovery_Stop_Position + 1;
            Child := Stops (Order_Position (Recovery_Stop_Position));
            if Recovery_Affected (Child) then
               if Snapshots (Child).Live then
                  return;
               end if;
               Snapshots (Child).Ready := False;
            end if;
         end loop;
         if Phase = Recovery_Stopping
           and then Recovery_Stop_Position = Child_Total
         then
            Phase := Recovery_Backing_Off;
            Recovery_Start_Position := 0;
         end if;
      end Advance_Recovery_Stop_Order;

      procedure Advance_Recovery_Start_Order is
         Child : Child_Kind;
      begin
         while Phase = Recovery_Starting
           and then Recovery_Start_Position < Child_Total
         loop
            Child := Starts (Order_Position (Recovery_Start_Position + 1));
            exit when Recovery_Affected (Child);
            Recovery_Start_Position := Recovery_Start_Position + 1;
         end loop;
         if Phase = Recovery_Starting
           and then Recovery_Start_Position = Child_Total
         then
            Phase := Running_Children;
            Subtree_Ready_Since := Ada.Real_Time.Clock;
            Record_Event
              (Recovery_Trigger,
               Restart_Completed,
               Running,
               Running,
               Subtree_Ready_Since,
               No_Termination,
               Active_Incident);
            Recovery_Affected := (others => False);
         end if;
      end Advance_Recovery_Start_Order;

      procedure Compute_Affected
        (Trigger : Child_Kind;
         Impact  : Restart_Impact;
         Result  : out Boolean_Array)
      is
      begin
         Result := (others => False);
         if Impact = Escalate then
            return;
         end if;
         Result (Trigger) := True;
         if Impact = Restart_Cohort then
            for Child in Child_Kind loop
               Result (Child) :=
                 Result (Child) or else Child_Cohorts (Trigger, Child);
            end loop;
         elsif Impact = Restart_Dependents then
            for Pass in Child_Kind loop
               pragma Unreferenced (Pass);
               for Child in Child_Kind loop
                  if not Result (Child) then
                     for Prerequisite in Child_Kind loop
                        if Child_Dependencies (Child, Prerequisite)
                          and then Result (Prerequisite)
                        then
                           Result (Child) := True;
                        end if;
                     end loop;
                  end if;
               end loop;
            end loop;
         end if;
      end Compute_Affected;

      procedure Try_Start
        (Child   : Child_Kind;
         Now     : Ada.Real_Time.Time;
         Started : out Boolean;
         Value   : out Child_Handle;
         Spec    : out Child_Specification;
         Incident : out Incident_Context)
      is
         Initial_Start : constant Boolean :=
           Phase = Starting_Children
           and then Start_Position < Child_Total
           and then Starts (Order_Position (Start_Position + 1)) = Child;
         Recovery_Start : Boolean := False;
         Before : Child_State;
      begin
         if Phase = Recovery_Backing_Off and then Now >= Recovery_Due then
            Phase := Recovery_Starting;
            Recovery_Start_Position := 0;
            Advance_Recovery_Start_Order;
         end if;
         Recovery_Start :=
           Phase = Recovery_Starting
           and then Recovery_Start_Position < Child_Total
           and then Starts (Order_Position (Recovery_Start_Position + 1)) =
             Child;
         Started := False;
         Spec := Child_Specs (Child);
         Incident :=
           (if Initial_Start then Inherited_Incident else Active_Incident);
         Value :=
           (Id         => Child_Ids (Child),
            Generation => Snapshots (Child).Generation);
         if not Initial_Start and then not Recovery_Start then
            return;
         end if;

         if Has_Generation (Child) then
            if Snapshots (Child).Generation = Generation'Last then
               Snapshots (Child).Termination :=
                 Empty_Summary (Policy_Exhaustion);
               Begin_Terminal_Stop
                 (Recovery_Exhausted,
                  Child,
                  Snapshots (Child).Termination);
               return;
            end if;
            Snapshots (Child).Generation :=
              Snapshots (Child).Generation + 1;
         else
            Has_Generation (Child) := True;
         end if;

         Before := Snapshots (Child).State;
         Snapshots (Child).State := Starting;
         Snapshots (Child).Ready := False;
         Snapshots (Child).Live := True;
         Snapshots (Child).Backoff := Ada.Real_Time.Time_Span_Zero;
         Snapshots (Child).Termination := Empty_Summary (No_Termination);
         Value :=
           (Id         => Child_Ids (Child),
            Generation => Snapshots (Child).Generation);
         Started := True;
         Record_Event
           (Child,
            Lifecycle_Changed,
            Before,
            Starting,
            Now,
            No_Termination,
            Incident);
      end Try_Start;

      procedure Publish_Ready
        (Child : Child_Kind;
         Value : Child_Handle;
         Now   : Ada.Real_Time.Time)
      is
      begin
         if not Is_Current
           (Value, Child_Ids (Child), Snapshots (Child).Generation)
           or else not Snapshots (Child).Live
           or else Snapshots (Child).State /= Starting
         then
            return;
         end if;

         Snapshots (Child).State := Ready;
         Snapshots (Child).Ready := True;
         Ready_Since (Child) := Now;
         Snapshots (Child).State := Running;
         Record_Event
           (Child,
            Readiness_Published,
            Starting,
            Running,
            Now,
            No_Termination,
            (if Phase = Recovery_Starting
             then Active_Incident
             else Inherited_Incident));
         if Phase = Starting_Children
           and then Start_Position < Child_Total
           and then Starts (Order_Position (Start_Position + 1)) = Child
         then
            Start_Position := Start_Position + 1;
            if Start_Position = Child_Total then
               Phase := Running_Children;
            end if;
         elsif Phase = Recovery_Starting
           and then Recovery_Start_Position < Child_Total
           and then Starts (Order_Position (Recovery_Start_Position + 1)) =
             Child
         then
            Recovery_Start_Position := Recovery_Start_Position + 1;
            Advance_Recovery_Start_Order;
         end if;
      end Publish_Ready;

      procedure Stop_Decision
        (Child    : Child_Kind;
         Value    : Child_Handle;
         Stop     : out Boolean;
         Shutdown : out Boolean;
         Spec     : out Stop_Policy)
      is
      begin
         Spec := Child_Specs (Child).Stopping;
         Stop := False;
         Shutdown := False;
         if not Is_Current
           (Value, Child_Ids (Child), Snapshots (Child).Generation)
           or else not Snapshots (Child).Live
         then
            return;
         end if;
         if Phase = Stopping_Children
           and then Stop_Position in Order_Position
           and then Stops (Order_Position (Stop_Position)) = Child
         then
            Stop := True;
            Shutdown := Terminal.Outcome = Shutdown_Completed;
            if Snapshots (Child).State not in Stopping | Failed_Escalated then
               Record_Event
                 (Child,
                  Stop_Published,
                  Snapshots (Child).State,
                  Stopping,
                  Ada.Real_Time.Clock,
                  No_Termination,
                  Active_Incident);
               Snapshots (Child).State := Stopping;
            end if;
         elsif Phase = Recovery_Stopping
           and then Recovery_Stop_Position in Order_Position
           and then Stops (Order_Position (Recovery_Stop_Position)) = Child
           and then Recovery_Affected (Child)
         then
            Stop := True;
            Shutdown := False;
            if Snapshots (Child).State /= Stopping then
               Record_Event
                 (Child,
                  Stop_Published,
                  Snapshots (Child).State,
                  Stopping,
                  Ada.Real_Time.Clock,
                  No_Termination,
                  Active_Incident);
               Snapshots (Child).State := Stopping;
            end if;
         end if;
      end Stop_Decision;

      procedure Classify_Restart
        (Child    : Child_Kind;
         Incident : Incident_Context;
         Now      : Ada.Real_Time.Time;
         Admitted : out Boolean;
         Backoff  : out Ada.Real_Time.Time_Span)
      is
         Limits       : constant Recovery_Limits :=
           Child_Specs (Child).Recovery;
         Next_Attempt : Natural;
         Subtree_Next : Natural;
         Elapsed      : Ada.Real_Time.Time_Span;
         Subtree_Elapsed : Ada.Real_Time.Time_Span;
         Subtree_Backoff : Ada.Real_Time.Time_Span;

         procedure Double_To_Attempt
           (Target : Natural;
            Limit  : Ada.Real_Time.Time_Span;
            Value  : in out Ada.Real_Time.Time_Span)
         is
         begin
            if Value > Ada.Real_Time.Time_Span_Zero then
               for Index in 2 .. Target loop
                  exit when Value = Limit;
                  if Value > Limit / 2 then
                     Value := Limit;
                  else
                     Value := Value * 2;
                  end if;
               end loop;
            end if;
         end Double_To_Attempt;
      begin
         if not Active (Incident) then
            Admitted := False;
            Backoff := Ada.Real_Time.Time_Span_Zero;
            return;
         end if;

         if Ready_Since (Child) /= Ada.Real_Time.Time_First
           and then Now - Ready_Since (Child) >= Limits.Stability_Reset
         then
            Total_Used (Child) := 0;
            Window_Used (Child) := 0;
            Consecutive (Child) := 0;
            Incident_Since (Child) := Now;
            Window_Since (Child) := Now;
         end if;

         if Total_Used (Child) = 0 then
            Incident_Since (Child) := Now;
         end if;
         if Window_Used (Child) = 0
           or else Now - Window_Since (Child) >= Limits.Window
         then
            Window_Since (Child) := Now;
            Window_Used (Child) := 0;
         end if;

         if Subtree_Ready_Since /= Ada.Real_Time.Time_First
           and then Now - Subtree_Ready_Since >=
             Subtree_Recovery.Stability_Reset
         then
            Subtree_Total_Used := 0;
            Subtree_Window_Used := 0;
            Subtree_Consecutive := 0;
            Subtree_Incident_Since := Now;
            Subtree_Window_Since := Now;
         end if;
         if Subtree_Total_Used = 0 then
            Subtree_Incident_Since := Now;
         end if;
         if Subtree_Window_Used = 0
           or else Now - Subtree_Window_Since >= Subtree_Recovery.Window
         then
            Subtree_Window_Since := Now;
            Subtree_Window_Used := 0;
         end if;

         if Total_Used (Child) >= Limits.Total_Attempts
           or else Window_Used (Child) >= Limits.Burst_Attempts
           or else Subtree_Total_Used >= Subtree_Recovery.Total_Attempts
           or else Subtree_Window_Used >= Subtree_Recovery.Burst_Attempts
           or else Now > Recovery_Deadline (Incident)
         then
            Admitted := False;
            Backoff := Limits.Maximum_Backoff;
            return;
         end if;

         Next_Attempt := Consecutive (Child) + 1;
         Backoff := Limits.Initial_Backoff;
         Double_To_Attempt
           (Next_Attempt, Limits.Maximum_Backoff, Backoff);
         Subtree_Next := Subtree_Consecutive + 1;
         Subtree_Backoff := Subtree_Recovery.Initial_Backoff;
         Double_To_Attempt
           (Subtree_Next,
            Subtree_Recovery.Maximum_Backoff,
            Subtree_Backoff);
         if Subtree_Backoff > Backoff then
            Backoff := Subtree_Backoff;
         end if;

         Elapsed := Now - Incident_Since (Child);
         Subtree_Elapsed := Now - Subtree_Incident_Since;
         Admitted :=
           Total_Used (Child) < Limits.Total_Attempts
           and then Window_Used (Child) < Limits.Burst_Attempts
           and then Subtree_Total_Used < Subtree_Recovery.Total_Attempts
           and then Subtree_Window_Used < Subtree_Recovery.Burst_Attempts
           and then Elapsed <= Limits.Recovery_Deadline
           and then Backoff <= Limits.Recovery_Deadline - Elapsed
           and then Subtree_Elapsed <=
             Subtree_Recovery.Recovery_Deadline
           and then Backoff <=
             Subtree_Recovery.Recovery_Deadline - Subtree_Elapsed
           and then Now <= Recovery_Deadline (Incident)
           and then Backoff <= Recovery_Deadline (Incident) - Now;
      end Classify_Restart;

      procedure Record_Restart
        (Child    : Child_Kind;
         Incident : Incident_Context;
         Now      : Ada.Real_Time.Time;
         Backoff : Ada.Real_Time.Time_Span)
      is
      begin
         Total_Used (Child) := Total_Used (Child) + 1;
         Window_Used (Child) := Window_Used (Child) + 1;
         Consecutive (Child) := Consecutive (Child) + 1;
         if not Policy.Same_Incident_Attempt
           (Has_Observed_Attempt,
            Observed_Incident,
            Observed_Attempt,
            Flyology.Supervision.Incident (Incident),
            Attempt (Incident))
         then
            Subtree_Total_Used := Subtree_Total_Used + 1;
            Subtree_Window_Used := Subtree_Window_Used + 1;
            Subtree_Consecutive := Subtree_Consecutive + 1;
            Observed_Incident := Flyology.Supervision.Incident (Incident);
            Observed_Attempt := Attempt (Incident);
            Has_Observed_Attempt := True;
         end if;
         Snapshots (Child).Attempts :=
           Interfaces.Unsigned_64 (Total_Used (Child));
         Snapshots (Child).Backoff := Backoff;
         if Backoff > Ada.Real_Time.Time_Last - Now then
            Restart_Due (Child) := Ada.Real_Time.Time_Last;
         else
            Restart_Due (Child) := Now + Backoff;
         end if;
         Snapshots (Child).State := Backing_Off;
      end Record_Restart;

      procedure Begin_Recovery
        (Trigger     : Child_Kind;
         Termination : Termination_Summary;
         Incident    : Incident_Context;
         Now         : Ada.Real_Time.Time)
      is
         Admitted : Boolean;
         Backoff  : Ada.Real_Time.Time_Span;
         Previous : constant Boolean_Array := Recovery_Affected;
         Retrying : constant Boolean := Phase = Recovery_Starting;
      begin
         Active_Incident := Incident;
         Classify_Restart
           (Trigger, Incident, Now, Admitted, Backoff);
         if not Admitted then
            Snapshots (Trigger).Termination.Kind := Policy_Exhaustion;
            Begin_Terminal_Stop
              (Recovery_Exhausted,
               Trigger,
               Snapshots (Trigger).Termination);
            return;
         end if;

         Compute_Affected
           (Trigger,
            Child_Specs (Trigger).Impact,
            Recovery_Affected);
         if Retrying then
            for Child in Child_Kind loop
               Recovery_Affected (Child) :=
                 Recovery_Affected (Child) or else Previous (Child);
            end loop;
         end if;
         Recovery_Trigger := Trigger;
         Record_Restart (Trigger, Incident, Now, Backoff);
         Recovery_Due := Restart_Due (Trigger);
         Recovery_Stop_Position := 0;
         Recovery_Start_Position := 0;
         Phase := Recovery_Stopping;
         Record_Event
           (Trigger,
            Restart_Admitted,
            Terminated,
            Backing_Off,
            Now,
            Termination.Kind,
            Incident,
            Backoff);
         Advance_Recovery_Stop_Order;
      end Begin_Recovery;

      procedure Publish_Termination
        (Child       : Child_Kind;
         Value       : Child_Handle;
         Termination : Termination_Summary;
         Incident    : Incident_Context;
         Now         : Ada.Real_Time.Time)
      is
         Existing_Stuck : constant Boolean :=
           Snapshots (Child).Termination.Kind = Stuck;
         Before : Child_State;
         Retry_Incident : Incident_Context := Incident;

         procedure Advance_Repeated_Attempt
           (Context   : in out Incident_Context;
            Exhausted : out Boolean)
         is
         begin
            Exhausted := False;
            if Policy.Same_Incident_Attempt
              (Has_Observed_Attempt,
               Observed_Incident,
               Observed_Attempt,
               Flyology.Supervision.Incident (Context),
               Attempt (Context))
            then
               begin
                  Context := Next_Attempt (Context);
               exception
                  when Program_Error => Exhausted := True;
               end;
            end if;
         end Advance_Repeated_Attempt;

         Attempts_Exhausted : Boolean;
      begin
         if not Is_Current
           (Value, Child_Ids (Child), Snapshots (Child).Generation)
           or else not Snapshots (Child).Live
         then
            return;
         end if;

         Before := Snapshots (Child).State;
         Snapshots (Child).Live := False;
         Snapshots (Child).Ready := False;
         Snapshots (Child).State := Terminated;
         if not Existing_Stuck then
            Snapshots (Child).Termination := Termination;
         end if;
         Record_Event
           (Child,
            Lifecycle_Changed,
            Before,
            Terminated,
            Now,
            Snapshots (Child).Termination.Kind,
            Incident);

         if Phase = Stopping_Children then
            Advance_Stop_Order;
         elsif Phase = Recovery_Stopping then
            if Recovery_Affected (Child) then
               Advance_Recovery_Stop_Order;
            else
               Active_Incident := Incident;
               Begin_Terminal_Stop
                 (Failure_Escalated, Child, Snapshots (Child).Termination);
            end if;
         elsif Phase = Starting_Children then
            Active_Incident := Incident;
            Begin_Terminal_Stop
              (Startup_Failed, Child, Snapshots (Child).Termination);
         elsif Phase = Running_Children then
            Active_Incident := Incident;
            if Child_Specs (Child).Impact = Escalate
              or else not Policy.Should_Restart
                (Child_Specs (Child).Restart, Termination.Kind)
            then
               Begin_Terminal_Stop
                 (Failure_Escalated,
                  Child,
                  Snapshots (Child).Termination);
            else
               Advance_Repeated_Attempt
                 (Retry_Incident, Attempts_Exhausted);
               if Attempts_Exhausted then
                  Active_Incident := Incident;
                  Snapshots (Child).Termination.Kind := Policy_Exhaustion;
                  Begin_Terminal_Stop
                    (Recovery_Exhausted,
                     Child,
                     Snapshots (Child).Termination);
               else
                  Active_Incident := Retry_Incident;
                  Begin_Recovery
                    (Child,
                     Snapshots (Child).Termination,
                     Retry_Incident,
                     Now);
               end if;
            end if;
         elsif Phase = Recovery_Starting then
            if not Recovery_Affected (Child)
              or else Child_Specs (Child).Impact = Escalate
              or else not Policy.Should_Restart
                (Child_Specs (Child).Restart, Termination.Kind)
            then
               Active_Incident := Incident;
               Begin_Terminal_Stop
                 (Failure_Escalated, Child, Snapshots (Child).Termination);
            else
               Advance_Repeated_Attempt
                 (Retry_Incident, Attempts_Exhausted);
               if Attempts_Exhausted then
                  Active_Incident := Incident;
                  Snapshots (Child).Termination.Kind := Policy_Exhaustion;
                  Begin_Terminal_Stop
                    (Recovery_Exhausted,
                     Child,
                     Snapshots (Child).Termination);
               else
                  Begin_Recovery
                    (Child,
                     Snapshots (Child).Termination,
                     Retry_Incident,
                     Now);
               end if;
            end if;
         end if;
      end Publish_Termination;

      function Incident_Can_Close
        (Child : Child_Kind;
         Value : Child_Handle;
         Now   : Ada.Real_Time.Time) return Boolean
      is
        (Phase = Running_Children
         and then Is_Current
           (Value, Child_Ids (Child), Snapshots (Child).Generation)
         and then Snapshots (Child).Live
         and then Snapshots (Child).Ready
         and then Ready_Since (Child) /= Ada.Real_Time.Time_First
         and then Subtree_Ready_Since /= Ada.Real_Time.Time_First
         and then Now - Ready_Since (Child) >=
           Child_Specs (Child).Recovery.Stability_Reset
         and then Now - Subtree_Ready_Since >=
           Subtree_Recovery.Stability_Reset);

      procedure Publish_Stuck
        (Child : Child_Kind;
         Value : Child_Handle)
      is
      begin
         if Is_Current
           (Value, Child_Ids (Child), Snapshots (Child).Generation)
           and then Snapshots (Child).Live
           and then Snapshots (Child).Termination.Kind /= Stuck
         then
            Snapshots (Child).State := Failed_Escalated;
            Snapshots (Child).Ready := False;
            Snapshots (Child).Termination := Empty_Summary (Stuck);
            if Phase = Stopping_Children then
               Terminal :=
                 (Outcome     => Child_Stuck,
                  Child       => Child_Ids (Child),
                  Generation  => Snapshots (Child).Generation,
                  Termination => Snapshots (Child).Termination,
                  Incident    => Active_Incident);
               Snapshots (Child).Escalated := True;
            else
               Begin_Terminal_Stop
                 (Child_Stuck, Child, Snapshots (Child).Termination);
            end if;
         end if;
      end Publish_Stuck;

      procedure Request_Stop is
      begin
         if Phase = Unconfigured then
            Terminal :=
              (Outcome     => Shutdown_Completed,
               Child       => Child_Id'First,
               Generation  => Generation'First,
               Termination => Empty_Summary (Supervisor_Shutdown),
               Incident    => No_Incident);
         elsif Phase not in Stopping_Children | Finished then
            Terminal :=
              (Outcome     => Shutdown_Completed,
               Child       => Child_Ids (Child_Kind'First),
               Generation  => Snapshots (Child_Kind'First).Generation,
               Termination => Empty_Summary (Supervisor_Shutdown),
               Incident    => Active_Incident);
            Phase := Stopping_Children;
            Stop_Position := 1;
            Record_Event
              (Child_Kind'First,
               Supervisor_Stopped,
               Snapshots (Child_Kind'First).State,
               Snapshots (Child_Kind'First).State,
               Ada.Real_Time.Clock,
               Supervisor_Shutdown,
               Active_Incident);
            Advance_Stop_Order;
         end if;
      end Request_Stop;

      function Manager_Should_Exit return Boolean is (Phase = Finished);

      procedure Manager_Failed
        (Child       : Child_Kind;
         Termination : Termination_Summary)
      is
      begin
         if Phase /= Finished then
            Snapshots (Child).Live := False;
            Snapshots (Child).Ready := False;
            Snapshots (Child).Termination := Termination;
            if Phase = Stopping_Children then
               Advance_Stop_Order;
            else
               Begin_Terminal_Stop
                 (Failure_Escalated, Child, Termination);
            end if;
         end if;
      end Manager_Failed;

      procedure Manager_Finished is
      begin
         if Managers_Done < Child_Total then
            Managers_Done := Managers_Done + 1;
         end if;
      end Manager_Finished;

      entry Await_Finished when Phase = Finished is
      begin
         null;
      end Await_Finished;

      entry Await_Managers when Managers_Done = Child_Total is
      begin
         null;
      end Await_Managers;

      function Has_Configuration return Boolean is (Configured);

      function Read_Result return Supervisor_Result is (Terminal);

      function Read_Snapshot
        (Child : Child_Kind) return Child_Snapshot is
        (Snapshots (Child));

      procedure Copy_Events
        (Cursor  : in out Event_Sequence;
         Target  : out Supervisor_Event_Array;
         Count   : out Natural;
         Dropped : out Event_Sequence)
      is
         Oldest  : Event_Sequence;
         Desired : Event_Sequence;
         Slot    : Positive;
      begin
         Target := (others => <>);
         Count := 0;
         Dropped := 0;
         if Event_Length = 0 or else Cursor >= Event_Last_Sequence then
            return;
         end if;

         Oldest :=
           Event_Last_Sequence - Event_Sequence (Event_Length) + 1;
         if Cursor < Oldest - 1 then
            Dropped := Oldest - Cursor - 1;
            Desired := Oldest;
         elsif Cursor = Event_Sequence'Last then
            return;
         else
            Desired := Cursor + 1;
         end if;

         for Offset in 0 .. Event_Length - 1 loop
            exit when Count = Target'Length;
            Slot :=
              Positive
                (((Event_First - Event_Buffer'First + Offset)
                  mod Event_Capacity) + Event_Buffer'First);
            if Events (Slot).Sequence >= Desired then
               Count := Count + 1;
               Target (Target'First + Count - 1) := Events (Slot);
               Cursor := Events (Slot).Sequence;
            end if;
         end loop;
      end Copy_Events;
   end Lifecycle;

   procedure Validate_Configuration
     (Specs        : out Specification_Array;
      Ids          : out Logical_Id_Array;
      Dependencies : out Dependency_Matrix;
      Cohorts      : out Cohort_Matrix;
      Start_Order  : out Child_Order;
      Stop_Order   : out Child_Order)
   is
      Emitted  : Boolean_Array := (others => False);
      Found    : Boolean;
      Ready    : Boolean;
      Selected : Child_Kind := Child_Kind'First;
      Position : Natural := 0;
      Affected : Boolean_Array;
   begin
      if Subtree_Recovery.Window <= Ada.Real_Time.Time_Span_Zero
        or else Subtree_Recovery.Initial_Backoff <
          Ada.Real_Time.Time_Span_Zero
        or else Subtree_Recovery.Maximum_Backoff <
          Subtree_Recovery.Initial_Backoff
        or else Subtree_Recovery.Stability_Reset <=
          Ada.Real_Time.Time_Span_Zero
        or else Subtree_Recovery.Recovery_Deadline <
          Ada.Real_Time.Time_Span_Zero
      then
         raise Configuration_Error with "invalid subtree recovery policy";
      end if;

      for Child in Child_Kind loop
         Specs (Child) := Specification (Child);
         Ids (Child) := Logical_Id (Child);
         if Specs (Child).Readiness_Timeout <
           Ada.Real_Time.Time_Span_Zero
           or else Specs (Child).Recovery.Window <=
             Ada.Real_Time.Time_Span_Zero
           or else Specs (Child).Recovery.Initial_Backoff <
             Ada.Real_Time.Time_Span_Zero
           or else Specs (Child).Recovery.Maximum_Backoff <
             Specs (Child).Recovery.Initial_Backoff
           or else Specs (Child).Recovery.Stability_Reset <=
             Ada.Real_Time.Time_Span_Zero
           or else Specs (Child).Recovery.Recovery_Deadline <
             Ada.Real_Time.Time_Span_Zero
           or else Specs (Child).Stopping.Grace <
             Ada.Real_Time.Time_Span_Zero
           or else Specs (Child).Stopping.Abort_Observation <
             Ada.Real_Time.Time_Span_Zero
           or else Specs (Child).Stopping.Grace >
             Ada.Real_Time.Time_Span_Last -
               Specs (Child).Stopping.Abort_Observation
           or else Specs (Child).Lane = No_Lane
           or else
             (Specs (Child).Lane = Native_Lane
              and then Specs (Child).Has_Group)
           or else
             (Specs (Child).Lane = Lightweight_Lane
              and then Specs (Child).Has_Group
              and then Integer (Specs (Child).Group) =
                Integer (Control_Group))
           or else
             (Specs (Child).Restart /= Never
              and then not Specs (Child).Restart_Safe)
           or else
             (Specs (Child).Restart = Never
              and then Specs (Child).Impact /= Escalate)
         then
            raise Configuration_Error with
              "invalid child specification";
         end if;

         for Other in Child_Kind loop
            if Other < Child and then Ids (Other) = Ids (Child) then
               raise Configuration_Error with "duplicate logical child id";
            end if;
            Dependencies (Child, Other) := Depends_On (Child, Other);
            Cohorts (Child, Other) := Cohort_Member (Child, Other);
            if Child = Other and then Dependencies (Child, Other) then
               raise Configuration_Error with "self dependency";
            end if;
         end loop;
      end loop;

      for Slot in Order_Position loop
         Found := False;
         for Child in Child_Kind loop
            if not Found and then not Emitted (Child) then
               Ready := True;
               for Prerequisite in Child_Kind loop
                  if Dependencies (Child, Prerequisite)
                    and then not Emitted (Prerequisite)
                  then
                     Ready := False;
                  end if;
               end loop;
               if Ready then
                  Selected := Child;
                  Found := True;
               end if;
            end if;
         end loop;
         if not Found then
            raise Configuration_Error with "dependency cycle";
         end if;
         Position := Position + 1;
         Start_Order (Order_Position (Position)) := Selected;
         Emitted (Selected) := True;
      end loop;

      for Slot in Order_Position loop
         Stop_Order (Slot) :=
           Start_Order (Order_Position (Child_Total - Slot + 1));
      end loop;

      for Trigger in Child_Kind loop
         if Specs (Trigger).Restart /= Never
           and then Specs (Trigger).Impact /= Escalate
         then
            Affected := (others => False);
            Affected (Trigger) := True;
            if Specs (Trigger).Impact = Restart_Cohort then
               if not Cohorts (Trigger, Trigger) then
                  raise Configuration_Error with
                    "recovery cohort must contain its trigger";
               end if;
               for Child in Child_Kind loop
                  Affected (Child) :=
                    Affected (Child) or else Cohorts (Trigger, Child);
               end loop;
            elsif Specs (Trigger).Impact = Restart_Dependents then
               for Pass in Child_Kind loop
                  pragma Unreferenced (Pass);
                  for Child in Child_Kind loop
                     if not Affected (Child) then
                        for Prerequisite in Child_Kind loop
                           if Dependencies (Child, Prerequisite)
                             and then Affected (Prerequisite)
                           then
                              Affected (Child) := True;
                           end if;
                        end loop;
                     end if;
                  end loop;
               end loop;
            end if;

            for Child in Child_Kind loop
               if Affected (Child) and then not Specs (Child).Restart_Safe then
                  raise Configuration_Error with
                    "affected child is not restart safe";
               end if;
               for Prerequisite in Child_Kind loop
                  if Affected (Prerequisite)
                    and then Dependencies (Child, Prerequisite)
                    and then not Affected (Child)
                  then
                     raise Configuration_Error with
                       "recovery set is not closed over dependents";
                  end if;
               end loop;
            end loop;
         end if;
      end loop;
   end Validate_Configuration;

   procedure Request_Shutdown (Item : in out Supervisor) is
   begin
      Item.State.Request_Stop;
   end Request_Shutdown;

   function Current
     (Item  : Supervisor;
      Child : Child_Kind) return Child_Snapshot
   is
      Spec : Child_Specification;
   begin
      if Item.State.Has_Configuration then
         return Item.State.Read_Snapshot (Child);
      end if;
      Spec := Specification (Child);
      return
        (Id          => Logical_Id (Child),
         Generation  => Generation'First,
         State       => Flyology.Supervision.Configured,
         Lane        => Spec.Lane,
         Has_Group   => Spec.Has_Group,
         Group       => Spec.Group,
         Termination => Empty_Summary (No_Termination),
         Attempts    => 0,
         Backoff     => Ada.Real_Time.Time_Span_Zero,
         Ready       => False,
         Live        => False,
         Escalated   => False);
   end Current;

   procedure Read_Events
     (Item    : in out Supervisor;
      Cursor  : in out Event_Sequence;
      Events  : out Supervisor_Event_Array;
      Count   : out Natural;
      Dropped : out Event_Sequence) is
   begin
      Item.State.Copy_Events (Cursor, Events, Count, Dropped);
   end Read_Events;

   procedure Run_Internal
     (Item    : aliased in out Supervisor;
      Context : aliased in out Application_Context;
      Inherited : Incident_Context;
      Result  : out Supervisor_Result)
   is
      Specs        : Specification_Array;
      Ids          : Logical_Id_Array;
      Dependencies : Dependency_Matrix;
      Cohorts      : Cohort_Matrix;
      Start_Order  : Child_Order;
      Stop_Order   : Child_Order;
   begin
      Validate_Configuration
        (Specs, Ids, Dependencies, Cohorts, Start_Order, Stop_Order);
      Item.State.Configure
        (Specs,
         Ids,
         Dependencies,
         Cohorts,
         Start_Order,
         Stop_Order,
         Inherited);

      declare
         protected type Runner_Completion is
            procedure Store (Value : Generation_Result);
            procedure Read
              (Done : out Boolean; Value : out Generation_Result);
         private
            Finished : Boolean := False;
            Stored   : Generation_Result;
         end Runner_Completion;

         protected body Runner_Completion is
            procedure Store (Value : Generation_Result) is
            begin
               if not Finished then
                  Stored := Value;
                  Finished := True;
               end if;
            end Store;

            procedure Read
              (Done : out Boolean; Value : out Generation_Result) is
            begin
               Done := Finished;
               Value := Stored;
            end Read;
         end Runner_Completion;

         task type Manager with CPU => Control_Group is
            pragma Task_Info (Flyology.Lightweight_Task);
            entry Start (Child : Child_Kind);
         end Manager;

         task body Manager is
            Managed_Child : Child_Kind := Child_Kind'First;
            Activated     : Boolean := False;

            procedure Run_Generation
              (Value : Child_Handle;
               Spec  : Child_Specification;
               Incident : Incident_Context)
            is
               Control      : aliased Generation_Control;
               Result_Value : Generation_Result;
            begin
               Open (Control, Value, Incident);
               declare
                  Completion : aliased Runner_Completion;

                  task Runner with CPU => Control_Group is
                     pragma Task_Info (Flyology.Lightweight_Task);
                  end Runner;

                  task body Runner is
                     Generation : Generation_Result;
                  begin
                     begin
                        Run_One_Generation
                          (Context, Managed_Child, Control, Generation);
                     exception
                        when Occurrence : Tasking_Error =>
                           Generation :=
                             (Termination    =>
                                Failure_Summary
                                  (Occurrence, Activation_Failure),
                              Reported_Ready => Is_Ready (Control),
                              Incident       => Recovery_Incident (Control));
                        when Occurrence : others =>
                           Generation :=
                             (Termination    => Failure_Summary (Occurrence),
                              Reported_Ready => Is_Ready (Control),
                              Incident       => Recovery_Incident (Control));
                     end;
                     Completion.Store (Generation);
                  end Runner;

                  Started_At       : constant Ada.Real_Time.Time :=
                    Ada.Real_Time.Clock;
                  Stop_At          : Ada.Real_Time.Time :=
                    Ada.Real_Time.Time_First;
                  Done             : Boolean;
                  Ready_Published  : Boolean := False;
                  Stop_Published   : Boolean := False;
                  Abort_Published  : Boolean := False;
                  Stuck_Published  : Boolean := False;
                  Incident_Closed  : Boolean := not Active (Incident);
                  Stop_Now         : Boolean;
                  Shutdown_Stop    : Boolean;
                  Stop_Config      : Stop_Policy;
                  Override         : Termination_Kind := No_Termination;
                  Now              : Ada.Real_Time.Time;
               begin
                  loop
                     Completion.Read (Done, Result_Value);
                     Now := Ada.Real_Time.Clock;

                     if not Ready_Published and then Is_Ready (Control) then
                        Item.State.Publish_Ready
                          (Managed_Child, Value, Now);
                        Ready_Published := True;
                     end if;
                     if not Incident_Closed
                       and then Item.State.Incident_Can_Close
                         (Managed_Child, Value, Now)
                     then
                        Close_Recovery_Incident (Control);
                        Incident_Closed := True;
                     end if;
                     exit when Done;

                     Item.State.Stop_Decision
                       (Managed_Child,
                        Value,
                        Stop_Now,
                        Shutdown_Stop,
                        Stop_Config);
                     if not Ready_Published
                       and then Now - Started_At >= Spec.Readiness_Timeout
                     then
                        Stop_Now := True;
                        Shutdown_Stop := False;
                        Override := Readiness_Timeout;
                        Stop_Config := Spec.Stopping;
                     end if;

                     if Stop_Now and then not Stop_Published then
                        Stop_Published := True;
                        Stop_At := Now;
                        begin
                           Request_Stop (Control, Shutdown_Stop);
                        exception
                           when others => null;
                        end;
                     end if;

                     if Stop_Published
                       and then Now - Stop_At >= Stop_Config.Grace
                     then
                        if not Shutdown_Stop
                          and then Override = No_Termination
                        then
                           Override := Stop_Timeout;
                        end if;
                        if Stop_Config.Request_Abort
                          and then not Abort_Published
                        then
                           Abort_Published := True;
                           begin
                              Request_Abort (Control);
                           exception
                              when others => null;
                           end;
                        end if;
                        if not Stuck_Published
                          and then Now - Stop_At >=
                            Stop_Config.Grace +
                              Stop_Config.Abort_Observation
                        then
                           Stuck_Published := True;
                           Item.State.Publish_Stuck
                             (Managed_Child, Value);
                        end if;
                     end if;
                     delay 0.001;
                  end loop;

                  Result_Value.Incident := Recovery_Incident (Control);
                  if Result_Value.Termination.Kind = No_Termination then
                     Result_Value.Termination :=
                       Empty_Summary (Abnormal_Completion);
                  elsif Override /= No_Termination
                    and then Result_Value.Termination.Kind in
                      Normal_Return | Cancelled | Supervisor_Shutdown |
                        Abnormal_Completion
                  then
                     Result_Value.Termination.Kind := Override;
                  elsif Stop_Published
                    and then Shutdown_Stop
                    and then Result_Value.Termination.Kind in
                      Normal_Return | Cancelled
                  then
                     Result_Value.Termination.Kind := Supervisor_Shutdown;
                  end if;
               exception
                  when Occurrence : others =>
                     Result_Value :=
                       (Termination    => Failure_Summary (Occurrence),
                        Reported_Ready => Is_Ready (Control),
                        Incident       => Recovery_Incident (Control));
               end;
               --  Leaving the nested block joins Runner. The application
               --  factory has already joined its generation before returning.
               declare
                  Finished_At : constant Ada.Real_Time.Time :=
                    Ada.Real_Time.Clock;
                  Cascade : Incident_Context := Result_Value.Incident;
                  Span : constant Ada.Real_Time.Time_Span :=
                    (if Spec.Recovery.Recovery_Deadline <
                       Subtree_Recovery.Recovery_Deadline
                     then Spec.Recovery.Recovery_Deadline
                     else Subtree_Recovery.Recovery_Deadline);
                  Deadline : Ada.Real_Time.Time;
               begin
                  if not Active (Cascade) then
                     if Span > Ada.Real_Time.Time_Last - Finished_At then
                        Deadline := Ada.Real_Time.Time_Last;
                     else
                        Deadline := Finished_At + Span;
                     end if;
                     Cascade := New_Incident (Finished_At, Deadline);
                  end if;
                  Item.State.Publish_Termination
                    (Managed_Child,
                     Value,
                     Result_Value.Termination,
                     Cascade,
                     Finished_At);
               end;
            exception
               when Occurrence : others =>
                  declare
                     Failed_At : constant Ada.Real_Time.Time :=
                       Ada.Real_Time.Clock;
                     Cascade : Incident_Context :=
                       Recovery_Incident (Control);
                     Span : constant Ada.Real_Time.Time_Span :=
                       (if Spec.Recovery.Recovery_Deadline <
                          Subtree_Recovery.Recovery_Deadline
                        then Spec.Recovery.Recovery_Deadline
                        else Subtree_Recovery.Recovery_Deadline);
                     Deadline : Ada.Real_Time.Time;
                  begin
                     if not Active (Cascade) then
                        if Span > Ada.Real_Time.Time_Last - Failed_At then
                           Deadline := Ada.Real_Time.Time_Last;
                        else
                           Deadline := Failed_At + Span;
                        end if;
                        Cascade := New_Incident (Failed_At, Deadline);
                     end if;
                     Item.State.Publish_Termination
                       (Managed_Child,
                        Value,
                        Failure_Summary
                          (Occurrence,
                           (if Ada.Exceptions.Exception_Identity (Occurrence) =
                             Tasking_Error'Identity
                            then Activation_Failure
                            else Unhandled_Exception)),
                        Cascade,
                        Failed_At);
                  end;
            end Run_Generation;

            Started : Boolean;
            Value   : Child_Handle;
            Spec    : Child_Specification;
            Incident : Incident_Context;
         begin
            select
               accept Start (Child : Child_Kind) do
                  Managed_Child := Child;
                  Activated := True;
               end Start;
            or
               terminate;
            end select;

            while Activated
              and then not Item.State.Manager_Should_Exit
            loop
               Item.State.Try_Start
                 (Managed_Child,
                  Ada.Real_Time.Clock,
                  Started,
                  Value,
                  Spec,
                  Incident);
               if Started then
                  Run_Generation (Value, Spec, Incident);
               else
                  delay 0.001;
               end if;
            end loop;
            Item.State.Manager_Finished;
         exception
            when Occurrence : others =>
               Item.State.Manager_Failed
                 (Managed_Child, Failure_Summary (Occurrence));
               Item.State.Manager_Finished;
         end Manager;

         type Manager_Array is array (Child_Kind) of Manager;
         Managers : Manager_Array;
      begin
         for Child in Child_Kind loop
            Managers (Child).Start (Child);
         end loop;
         Item.State.Await_Finished;
         Item.State.Await_Managers;
         Result := Item.State.Read_Result;
      exception
         when others =>
            Item.State.Request_Stop;
            raise;
      end;
   end Run_Internal;

   procedure Run
     (Item    : aliased in out Supervisor;
      Context : aliased in out Application_Context;
      Result  : out Supervisor_Result) is
   begin
      Run_Internal (Item, Context, No_Incident, Result);
   end Run;

   procedure Run_Nested
     (Item    : aliased in out Supervisor;
      Context : aliased in out Application_Context;
      Parent  : in out Generation_Control;
      Result  : out Supervisor_Result)
   is
      Inherited : constant Incident_Context := Recovery_Incident (Parent);
   begin
      Run_Internal (Item, Context, Inherited, Result);
      if Active (Result.Incident)
        and then Result.Outcome /= Shutdown_Completed
      then
         Report_Escalation (Parent, Result.Incident);
      end if;
   end Run_Nested;

end Flyology.Supervision.Static;
