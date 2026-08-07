with Ada.Exceptions;
with Ada.Task_Identification;
with Ada.Unchecked_Deallocation;
with Flyology.Supervision_Policy;
with Interfaces;

package body Flyology.Supervision.Families is
   use type Ada.Real_Time.Time;
   use type Ada.Real_Time.Time_Span;
   use type Flyology.Execution_Model;
   use type Interfaces.Unsigned_64;

   package Kernel renames Flyology.Supervision_Policy;

   function Generation_Is_Current
     (Handle : Child_Handle;
      Id     : Child_Id;
      Value  : Generation) return Boolean
   is
     (Kernel.Generation_Matches
        (Expected_Id         => Id,
         Expected_Generation => Value,
         Supplied_Id         => Child (Handle),
         Supplied_Generation => Current_Generation (Handle)));

   function Empty_Summary
     (Kind : Termination_Kind) return Termination_Summary is
     ((Kind           => Kind,
       Task_Id        => Ada.Task_Identification.Null_Task_Id,
       others         => <>));

   function Failure_Summary
     (Occurrence : Ada.Exceptions.Exception_Occurrence;
      Kind       : Termination_Kind := Unhandled_Exception)
      return Termination_Summary
   is
      Name : constant String :=
        Ada.Exceptions.Exception_Name
          (Ada.Exceptions.Exception_Identity (Occurrence));
      Message : constant String :=
        Ada.Exceptions.Exception_Message (Occurrence);
      Name_Length : constant Exception_Name_Length :=
        Exception_Name_Length'Min
          (Exception_Name_Length'Last, Name'Length);
      Length : constant Diagnostic_Length :=
        Diagnostic_Length'Min (Diagnostic_Length'Last, Message'Length);
      Value : Termination_Summary := Empty_Summary (Kind);
   begin
      Value.Exception_Id := Ada.Exceptions.Exception_Identity (Occurrence);
      Value.Exception_Name_Length := Name_Length;
      Value.Exception_Name_Truncated := Name'Length > Name_Length;
      if Name_Length > 0 then
         Value.Exception_Name (1 .. Name_Length) :=
           Name (Name'First .. Name'First + Name_Length - 1);
      end if;
      Value.Message_Length := Length;
      Value.Message_Truncated := Message'Length > Length;
      if Length > 0 then
         Value.Message (1 .. Length) :=
           Message (Message'First .. Message'First + Length - 1);
      end if;
      return Value;
   end Failure_Summary;

   function Logical_Id (Slot : Slot_Index) return Child_Id is
     (Child_Id
        (Interfaces.Unsigned_64 (First_Child_Id) +
         Interfaces.Unsigned_64 (Slot - Slot_Index'First)));

   protected body Family_State is
      procedure Configure (Inherited : Incident_Context) is
      begin
         if Run_Used then
            raise Program_Error with "supervision family is one-shot";
         end if;
         Run_Used := True;
         Configured := True;
         Inherited_Incident := Inherited;
         Result :=
           (Outcome     => Shutdown_Completed,
            Child       => First_Child_Id,
            Generation  => Generation'First,
            Termination => Empty_Summary (Supervisor_Shutdown),
            Incident    => No_Incident);
         for Slot in Slot_Index loop
            Snapshots (Slot) :=
              (Id          => Logical_Id (Slot),
               Generation  => Generation'First,
               State       => Flyology.Supervision.Configured,
               Task_Model  => Policy.Task_Model,
               Has_Group   => Policy.Has_Group,
               Group       => Policy.Group,
               Termination => Empty_Summary (No_Termination),
               Attempts    => 0,
               Backoff     => Ada.Real_Time.Time_Span_Zero,
               Ready       => False,
               Live        => False,
               Escalated   => False);
         end loop;
      end Configure;

      procedure Record_Event
        (Slot        : Slot_Index;
         Kind        : Event_Kind;
         Before      : Child_State;
         After       : Child_State;
         Now         : Ada.Real_Time.Time;
         Termination : Termination_Kind := No_Termination;
         Incident    : Incident_Context := No_Incident;
         Backoff     : Ada.Real_Time.Time_Span :=
           Ada.Real_Time.Time_Span_Zero)
      is
         Event_Slot : Positive;
      begin
         if not Kernel.Recorded_Transition_Allowed (Kind, Before, After) then
            raise Program_Error with
              "illegal family supervision lifecycle transition";
         end if;
         if Event_Sequence_Exhausted then
            return;
         elsif Event_Last_Sequence = Event_Sequence'Last then
            Event_Sequence_Exhausted := True;
            return;
         end if;

         Event_Last_Sequence := Event_Last_Sequence + 1;
         if Event_Length < Event_Capacity then
            Event_Slot :=
              Positive
                (((Event_First - Event_Buffer'First + Event_Length)
                  mod Event_Capacity) + Event_Buffer'First);
            Event_Length := Event_Length + 1;
         else
            Event_Slot := Event_First;
            Event_First :=
              (if Event_First = Event_Buffer'Last
               then Event_Buffer'First
               else Event_First + 1);
         end if;
         Events (Event_Slot) :=
           (Sequence    => Event_Last_Sequence,
            Timestamp   => Now,
            Kind        => Kind,
            Child       => Snapshots (Slot).Id,
            Generation  => Snapshots (Slot).Generation,
            Before      => Before,
            After       => After,
            Task_Model  => Policy.Task_Model,
            Has_Group   => Policy.Has_Group,
            Group       => Policy.Group,
            Termination => Termination,
            Incident    => Incident,
            Backoff     => Backoff);
      end Record_Event;

      procedure Reserve
        (Slot   : out Slot_Index;
         Handle : out Child_Handle)
      is
         Found : Boolean := False;
         Selected : Slot_Index := Slot_Index'First;
      begin
         if not Kernel.Family_Admission_Open
           (Configured, Shutdown, Terminal)
         then
            raise Program_Error with "family admission is closed";
         end if;
         for Candidate in Slot_Index loop
            if not Found and then Slots (Candidate) in Free | Reapable then
               Selected := Candidate;
               Found := True;
            end if;
         end loop;
         if not Found then
            raise Constraint_Error with "family capacity is exhausted";
         end if;

         if Has_Generation (Selected) then
            if not Flyology.Supervision_Policy.Generation_Can_Advance
              (Snapshots (Selected).Generation)
            then
               raise Program_Error with "family generation space exhausted";
            end if;
            Snapshots (Selected).Generation :=
              Flyology.Supervision_Policy.Next_Generation
                (Snapshots (Selected).Generation);
         else
            Has_Generation (Selected) := True;
         end if;
         Slots (Selected) := Reserved;
         Reserved_Children := Reserved_Children + 1;
         Stop_Requested (Selected) := False;
         Snapshots (Selected).State := Flyology.Supervision.Configured;
         Snapshots (Selected).Ready := False;
         Snapshots (Selected).Live := False;
         Snapshots (Selected).Escalated := False;
         Snapshots (Selected).Termination := Empty_Summary (No_Termination);
         Snapshots (Selected).Attempts := 0;
         Snapshots (Selected).Backoff := Ada.Real_Time.Time_Span_Zero;
         Total_Used (Selected) := 0;
         Window_Used (Selected) := 0;
         Consecutive (Selected) := 0;
         Incident_Since (Selected) := Ada.Real_Time.Time_First;
         Window_Since (Selected) := Ada.Real_Time.Time_First;
         Ready_Since (Selected) := Ada.Real_Time.Time_First;
         Last_Incident (Selected) := Incident_Id'First;
         Last_Attempt (Selected) := Incident_Attempt'First;
         Has_Incident (Selected) := False;
         Active_Incidents (Selected) := No_Incident;
         Slot := Selected;
         Handle :=
           (Id         => Logical_Id (Selected),
            Generation => Snapshots (Selected).Generation);
      end Reserve;

      procedure Commit (Slot : Slot_Index; Handle : Child_Handle) is
      begin
         if Slots (Slot) /= Reserved
           or else not Generation_Is_Current
             (Handle,
              Snapshots (Slot).Id,
              Snapshots (Slot).Generation)
         then
            raise Program_Error with "family reservation is stale";
         elsif not Kernel.Family_Admission_Open
           (Configured, Shutdown, Terminal)
         then
            raise Program_Error with "family admission closed during copy";
         end if;
         Reserved_Children := Reserved_Children - 1;
         Slots (Slot) := Queued;
         Queue (Queue_Tail) := Slot;
         Queue_Tail :=
           (if Queue_Tail = Slot_Index'Last
            then Slot_Index'First
            else Queue_Tail + 1);
         Queue_Length := Queue_Length + 1;
      end Commit;

      procedure Rollback (Slot : Slot_Index; Handle : Child_Handle) is
      begin
         if Slots (Slot) = Reserved
           and then Generation_Is_Current
             (Handle,
              Snapshots (Slot).Id,
              Snapshots (Slot).Generation)
         then
            Reserved_Children := Reserved_Children - 1;
            Slots (Slot) := Free;
         end if;
      end Rollback;

      procedure Take_Start
        (Available : out Boolean;
         Slot      : out Slot_Index;
         Handle    : out Child_Handle;
         Incident  : out Incident_Context)
      is
      begin
         Available := Queue_Length > 0;
         Slot := Slot_Index'First;
         Handle :=
           (Id => First_Child_Id, Generation => Generation'First);
         Incident := No_Incident;
         if not Available then
            return;
         end if;
         Slot := Queue (Queue_Head);
         Queue_Head :=
           (if Queue_Head = Slot_Index'Last
            then Slot_Index'First
            else Queue_Head + 1);
         Queue_Length := Queue_Length - 1;
         if Slots (Slot) /= Queued then
            raise Program_Error with "family start queue is inconsistent";
         end if;
         Slots (Slot) := Managed;
         Live_Managers := Live_Managers + 1;
         Handle :=
           (Id         => Snapshots (Slot).Id,
            Generation => Snapshots (Slot).Generation);
         Incident := Inherited_Incident;
      end Take_Start;

      procedure Stop_One (Handle : Child_Handle; Valid : out Boolean) is
         Slot : Slot_Index;
      begin
         Valid := False;
         if Child (Handle) < First_Child_Id
           or else Interfaces.Unsigned_64 (Child (Handle)) -
             Interfaces.Unsigned_64 (First_Child_Id) >=
               Interfaces.Unsigned_64 (Maximum_Children)
         then
            return;
         end if;
         Slot := Slot_Index
           (Interfaces.Unsigned_64 (Child (Handle)) -
            Interfaces.Unsigned_64 (First_Child_Id) + 1);
         Valid := Kernel.Family_Stop_Command_Allowed
           (Current => Generation_Is_Current
              (Handle,
               Snapshots (Slot).Id,
               Snapshots (Slot).Generation),
            Queued  => Slots (Slot) = Queued,
            Managed => Slots (Slot) = Managed,
            Live    => Snapshots (Slot).Live);
         if Valid then
            Stop_Requested (Slot) := True;
         end if;
      end Stop_One;

      procedure Stop_Status
        (Slot     : Slot_Index;
         Handle   : Child_Handle;
         Stop     : out Boolean;
         Shutdown : out Boolean)
      is
      begin
         Stop := False;
         Shutdown := Family_State.Shutdown;
         if Slots (Slot) = Managed
           and then Generation_Is_Current
             (Handle,
              Snapshots (Slot).Id,
              Snapshots (Slot).Generation)
         then
            Stop := Stop_Requested (Slot) or else Family_State.Shutdown;
            if Stop and then Snapshots (Slot).State /= Stopping then
               Record_Event
                 (Slot,
                  Stop_Published,
                  Snapshots (Slot).State,
                  Stopping,
                  Ada.Real_Time.Clock,
                  Incident => Active_Incidents (Slot));
               Snapshots (Slot).State := Stopping;
               Snapshots (Slot).Ready := False;
            end if;
         end if;
      end Stop_Status;

      procedure Publish_Starting
        (Slot   : Slot_Index;
         Handle : Child_Handle;
         Incident : Incident_Context)
      is
         Before : Child_State;
         Advancing : Boolean;
      begin
         if Slots (Slot) = Managed
           and then Kernel.Generation_Start_Allowed
             (Expected_Id         => Snapshots (Slot).Id,
              Expected_Generation => Snapshots (Slot).Generation,
              Supplied_Id         => Child (Handle),
              Supplied_Generation => Current_Generation (Handle),
              Restart_Pending     => Snapshots (Slot).State = Backing_Off)
         then
            Before := Snapshots (Slot).State;
            Advancing := Current_Generation (Handle) /=
              Snapshots (Slot).Generation;
            Active_Incidents (Slot) := Incident;
            Snapshots (Slot).Generation := Current_Generation (Handle);
            if Advancing then
               Snapshots (Slot).State := Restarting;
               Record_Event
                 (Slot,
                  Lifecycle_Changed,
                  Before,
                  Restarting,
                  Ada.Real_Time.Clock,
                  Incident => Incident);
               Before := Restarting;
            end if;
            Snapshots (Slot).State := Starting;
            Snapshots (Slot).Live := True;
            Snapshots (Slot).Ready := False;
            Snapshots (Slot).Termination := Empty_Summary (No_Termination);
            Record_Event
              (Slot,
               Lifecycle_Changed,
               Before,
               Starting,
               Ada.Real_Time.Clock,
               Incident => Incident);
         end if;
      end Publish_Starting;

      procedure Publish_Ready
        (Slot   : Slot_Index;
         Handle : Child_Handle;
         Now    : Ada.Real_Time.Time) is
      begin
         if Slots (Slot) = Managed
           and then Generation_Is_Current
             (Handle,
              Snapshots (Slot).Id,
              Snapshots (Slot).Generation)
           and then Snapshots (Slot).Live
           and then Snapshots (Slot).State = Starting
         then
            Snapshots (Slot).State := Running;
            Snapshots (Slot).Ready := True;
            Ready_Since (Slot) := Now;
            Record_Event
              (Slot,
               Readiness_Published,
               Starting,
               Running,
               Now,
               Incident => Active_Incidents (Slot));
            if Has_Incident (Slot)
              and then Active (Active_Incidents (Slot))
            then
               Record_Event
                 (Slot,
                  Restart_Completed,
                  Running,
                  Running,
                  Now,
                  Incident => Active_Incidents (Slot));
            end if;
         end if;
      end Publish_Ready;

      procedure Begin_Terminal
        (Outcome     : Supervisor_Outcome;
         Slot        : Slot_Index;
         Termination : Termination_Summary;
         Incident    : Incident_Context)
      is
         After : constant Child_State :=
           (if Snapshots (Slot).Live
            then Snapshots (Slot).State
            else Failed_Escalated);
      begin
         if not Terminal then
            Record_Event
              (Slot,
               Recovery_Escalated,
               Snapshots (Slot).State,
               After,
               Ada.Real_Time.Clock,
               Termination.Kind,
               Incident);
            if not Snapshots (Slot).Live then
               Snapshots (Slot).State := Failed_Escalated;
            end if;
            Terminal := True;
            Shutdown := True;
            Result :=
              (Outcome     => Outcome,
               Child       => Snapshots (Slot).Id,
               Generation  => Snapshots (Slot).Generation,
               Termination => Termination,
               Incident    => Incident);
            Snapshots (Slot).Escalated := True;
            for Other in Slot_Index loop
               if Slots (Other) in Queued | Managed then
                  Stop_Requested (Other) := True;
               end if;
            end loop;
         end if;
      end Begin_Terminal;

      procedure Publish_Stuck
        (Slot   : Slot_Index;
         Handle : Child_Handle) is
      begin
         if Slots (Slot) = Managed
           and then Generation_Is_Current
             (Handle,
              Snapshots (Slot).Id,
              Snapshots (Slot).Generation)
           and then Snapshots (Slot).Live
         then
            Snapshots (Slot).Termination := Empty_Summary (Stuck);
            Record_Event
              (Slot,
               Child_Became_Stuck,
               Snapshots (Slot).State,
               Snapshots (Slot).State,
               Ada.Real_Time.Clock,
               Stuck,
               Active_Incidents (Slot));
            Begin_Terminal
              (Child_Stuck,
               Slot,
               Snapshots (Slot).Termination,
               Active_Incidents (Slot));
         end if;
      end Publish_Stuck;

      procedure Publish_Termination
        (Slot        : Slot_Index;
         Handle      : Child_Handle;
         Termination : Termination_Summary;
         Incident    : Incident_Context;
         Now         : Ada.Real_Time.Time;
         Restart     : out Boolean;
         Backoff     : out Ada.Real_Time.Time_Span;
         Next        : out Child_Handle;
         Recovery    : out Incident_Context)
      is
         Next_Attempt : Natural;
         Elapsed : Ada.Real_Time.Time_Span;
         Cascade : Incident_Context := Incident;
         Before : Child_State;
      begin
         Restart := False;
         Backoff := Ada.Real_Time.Time_Span_Zero;
         Next := Handle;
         Recovery := Incident;
         if Slots (Slot) /= Managed
           or else not Generation_Is_Current
             (Handle,
              Snapshots (Slot).Id,
              Snapshots (Slot).Generation)
         then
            return;
         end if;
         Before := Snapshots (Slot).State;
         Snapshots (Slot).Live := False;
         Snapshots (Slot).Ready := False;
         Snapshots (Slot).State := Terminated;
         if Snapshots (Slot).Termination.Kind /= Stuck then
            Snapshots (Slot).Termination := Termination;
         end if;
         Record_Event
           (Slot,
            Lifecycle_Changed,
            Before,
            Terminated,
            Now,
            Snapshots (Slot).Termination.Kind,
            Incident);

         if Shutdown or else Stop_Requested (Slot) then
            return;
         elsif not Flyology.Supervision_Policy.Should_Restart
           (Policy.Restart, Termination.Kind)
         then
            if Policy.Impact = Escalate
              and then Termination.Kind /= Normal_Return
            then
               Begin_Terminal
                 (Failure_Escalated, Slot, Termination, Incident);
            end if;
            return;
         elsif Policy.Impact = Escalate then
            Begin_Terminal
              (Failure_Escalated, Slot, Termination, Incident);
            return;
         end if;

         if Flyology.Supervision_Policy.Same_Incident_Attempt
           (Has_Incident (Slot),
            Last_Incident (Slot),
            Last_Attempt (Slot),
            Flyology.Supervision.Incident (Cascade),
            Attempt (Cascade))
         then
            begin
               Cascade := Flyology.Supervision.Next_Attempt (Cascade);
            exception
               when Program_Error =>
                  Snapshots (Slot).Termination.Kind := Policy_Exhaustion;
                  Begin_Terminal
                    (Recovery_Exhausted,
                     Slot,
                     Snapshots (Slot).Termination,
                     Incident);
                  return;
            end;
         end if;
         Recovery := Cascade;

         if Ready_Since (Slot) /= Ada.Real_Time.Time_First
           and then Now - Ready_Since (Slot) >= Policy.Recovery.Stability_Reset
         then
            Total_Used (Slot) := 0;
            Window_Used (Slot) := 0;
            Consecutive (Slot) := 0;
            Window_Since (Slot) := Now;
            Incident_Since (Slot) := Now;
         end if;
         if not Has_Incident (Slot)
           or else Last_Incident (Slot) /=
             Flyology.Supervision.Incident (Cascade)
         then
            Incident_Since (Slot) := Now;
         end if;
         if Window_Used (Slot) = 0
           or else Now - Window_Since (Slot) >= Policy.Recovery.Window
         then
            Window_Since (Slot) := Now;
            Window_Used (Slot) := 0;
         end if;
         if Total_Used (Slot) >= Policy.Recovery.Total_Attempts
           or else Window_Used (Slot) >= Policy.Recovery.Burst_Attempts
           or else Now > Recovery_Deadline (Cascade)
         then
            Snapshots (Slot).Termination.Kind := Policy_Exhaustion;
            Begin_Terminal
              (Recovery_Exhausted,
               Slot,
               Snapshots (Slot).Termination,
               Cascade);
            return;
         end if;

         Next_Attempt := Consecutive (Slot) + 1;
         Backoff := Policy.Recovery.Initial_Backoff;
         if Backoff > Ada.Real_Time.Time_Span_Zero then
            for Index in 2 .. Next_Attempt loop
               exit when Backoff = Policy.Recovery.Maximum_Backoff;
               if Backoff > Policy.Recovery.Maximum_Backoff / 2 then
                  Backoff := Policy.Recovery.Maximum_Backoff;
               else
                  Backoff := Backoff * 2;
               end if;
            end loop;
         end if;
         Elapsed := Now - Incident_Since (Slot);
         if Elapsed > Policy.Recovery.Recovery_Deadline
           or else Backoff > Policy.Recovery.Recovery_Deadline - Elapsed
           or else Backoff > Recovery_Deadline (Cascade) - Now
           or else not Flyology.Supervision_Policy.Generation_Can_Advance
             (Snapshots (Slot).Generation)
         then
            Snapshots (Slot).Termination.Kind := Policy_Exhaustion;
            Begin_Terminal
              (Recovery_Exhausted,
               Slot,
               Snapshots (Slot).Termination,
               Cascade);
            return;
         end if;

         Total_Used (Slot) := Total_Used (Slot) + 1;
         Window_Used (Slot) := Window_Used (Slot) + 1;
         Consecutive (Slot) := Consecutive (Slot) + 1;
         Last_Incident (Slot) := Flyology.Supervision.Incident (Cascade);
         Last_Attempt (Slot) := Attempt (Cascade);
         Has_Incident (Slot) := True;
         Snapshots (Slot).Attempts :=
           Interfaces.Unsigned_64 (Total_Used (Slot));
         Snapshots (Slot).Backoff := Backoff;
         Snapshots (Slot).State := Backing_Off;
         Record_Event
           (Slot,
            Restart_Admitted,
            Terminated,
            Backing_Off,
            Now,
            Termination.Kind,
            Cascade,
            Backoff);
         Next :=
           (Id         => Snapshots (Slot).Id,
            Generation => Flyology.Supervision_Policy.Next_Generation
              (Snapshots (Slot).Generation));
         Restart := True;
      end Publish_Termination;

      function Incident_Can_Close
        (Slot   : Slot_Index;
         Handle : Child_Handle;
         Now    : Ada.Real_Time.Time) return Boolean
      is
        (Slots (Slot) = Managed
         and then Generation_Is_Current
           (Handle,
            Snapshots (Slot).Id,
            Snapshots (Slot).Generation)
         and then Snapshots (Slot).Live
         and then Snapshots (Slot).Ready
         and then Ready_Since (Slot) /= Ada.Real_Time.Time_First
         and then Now - Ready_Since (Slot) >=
           Policy.Recovery.Stability_Reset);

      procedure Manager_Done (Slot : Slot_Index; Handle : Child_Handle) is
      begin
         if Slots (Slot) = Managed
           and then Generation_Is_Current
             (Handle,
              Snapshots (Slot).Id,
              Snapshots (Slot).Generation)
         then
            Record_Event
              (Slot,
               Lifecycle_Changed,
               Snapshots (Slot).State,
               Joined,
               Ada.Real_Time.Clock,
               Snapshots (Slot).Termination.Kind,
               Active_Incidents (Slot));
            Slots (Slot) := Reapable;
            Snapshots (Slot).State := Joined;
            Snapshots (Slot).Live := False;
            Live_Managers := Live_Managers - 1;
         end if;
      end Manager_Done;

      procedure Manager_Failed
        (Slot        : Slot_Index;
         Handle      : Child_Handle;
         Termination : Termination_Summary) is
      begin
         if Slots (Slot) = Managed
           and then Generation_Is_Current
             (Handle,
              Snapshots (Slot).Id,
              Snapshots (Slot).Generation)
         then
            Snapshots (Slot).Termination := Termination;
            Snapshots (Slot).Live := False;
            Snapshots (Slot).Ready := False;
            Snapshots (Slot).State := Failed_Escalated;
            Begin_Terminal
              (Failure_Escalated,
               Slot,
               Termination,
               Active_Incidents (Slot));
         end if;
      end Manager_Failed;

      procedure Request_Stop is
      begin
         if Configured and then not Shutdown then
            Record_Event
              (Slot_Index'First,
               Supervisor_Stopped,
               Snapshots (Slot_Index'First).State,
               Snapshots (Slot_Index'First).State,
               Ada.Real_Time.Clock,
               Supervisor_Shutdown,
               Inherited_Incident);
         end if;
         Shutdown := True;
         if not Terminal then
            Result :=
              (Outcome     => Shutdown_Completed,
               Child       => First_Child_Id,
               Generation  => Generation'First,
               Termination => Empty_Summary (Supervisor_Shutdown),
               Incident    => No_Incident);
         end if;
         for Slot in Slot_Index loop
            if Slots (Slot) in Queued | Managed then
               Stop_Requested (Slot) := True;
            end if;
         end loop;
      end Request_Stop;

      function Is_Finished return Boolean is
        (Flyology.Supervision_Policy.Family_Finished
           (Shutdown,
            Terminal,
            Reserved_Children,
            Queue_Length,
            Live_Managers));

      function Admission_Is_Open return Boolean is
        (Kernel.Family_Admission_Open (Configured, Shutdown, Terminal));

      function Read_Result return Supervisor_Result is (Result);

      function Read_Snapshot
        (Handle : Child_Handle;
         Valid  : out Boolean) return Child_Snapshot
      is
         Slot : Slot_Index := Slot_Index'First;
      begin
         Valid := False;
         if Child (Handle) >= First_Child_Id
           and then Interfaces.Unsigned_64 (Child (Handle)) -
             Interfaces.Unsigned_64 (First_Child_Id) <
               Interfaces.Unsigned_64 (Maximum_Children)
         then
            Slot := Slot_Index
              (Interfaces.Unsigned_64 (Child (Handle)) -
               Interfaces.Unsigned_64 (First_Child_Id) + 1);
            Valid := Has_Generation (Slot)
              and then Generation_Is_Current
                (Handle,
                 Snapshots (Slot).Id,
                 Snapshots (Slot).Generation);
         end if;
         return Snapshots (Slot);
      end Read_Snapshot;

      function Read_Logical_Snapshot
        (Child : Child_Id;
         Valid : out Boolean) return Child_Snapshot
      is
         Slot : Slot_Index := Slot_Index'First;
         Value : Child_Snapshot :=
           (Id          => Child,
            Generation  => Generation'First,
            State       => Flyology.Supervision.Configured,
            Task_Model  => Policy.Task_Model,
            Has_Group   => Policy.Has_Group,
            Group       => Policy.Group,
            Termination => Empty_Summary (No_Termination),
            Attempts    => 0,
            Backoff     => Ada.Real_Time.Time_Span_Zero,
            Ready       => False,
            Live        => False,
            Escalated   => False);
      begin
         Valid := False;
         if Child >= First_Child_Id
           and then Interfaces.Unsigned_64 (Child) -
             Interfaces.Unsigned_64 (First_Child_Id) <
               Interfaces.Unsigned_64 (Maximum_Children)
         then
            Slot := Slot_Index
              (Interfaces.Unsigned_64 (Child) -
               Interfaces.Unsigned_64 (First_Child_Id) + 1);
            Valid := Slots (Slot) /= Free and then Has_Generation (Slot);
            if Valid then
               Value := Snapshots (Slot);
            end if;
         end if;
         return Value;
      end Read_Logical_Snapshot;

      function Read_Latest
        (Child : Child_Id;
         Valid : out Boolean) return Child_Handle
      is
         Slot : Slot_Index := Slot_Index'First;
         Value : Child_Handle :=
           (Id => First_Child_Id, Generation => Generation'First);
      begin
         Valid := False;
         if Child >= First_Child_Id
           and then Interfaces.Unsigned_64 (Child) -
             Interfaces.Unsigned_64 (First_Child_Id) <
               Interfaces.Unsigned_64 (Maximum_Children)
         then
            Slot := Slot_Index
              (Interfaces.Unsigned_64 (Child) -
               Interfaces.Unsigned_64 (First_Child_Id) + 1);
            Valid := Slots (Slot) /= Free and then Has_Generation (Slot);
            if Valid then
               Value :=
                 (Id         => Snapshots (Slot).Id,
                  Generation => Snapshots (Slot).Generation);
            end if;
         end if;
         return Value;
      end Read_Latest;

      procedure Copy_Events
        (Cursor  : in out Event_Sequence;
         Target  : out Supervisor_Event_Array;
         Count   : out Natural;
         Dropped : out Event_Sequence)
      is
         Oldest  : Event_Sequence;
         Desired : Event_Sequence;
         Event_Slot : Positive;
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
            Event_Slot :=
              Positive
                (((Event_First - Event_Buffer'First + Offset)
                  mod Event_Capacity) + Event_Buffer'First);
            if Events (Event_Slot).Sequence >= Desired then
               Count := Count + 1;
               Target (Target'First + Count - 1) := Events (Event_Slot);
               Cursor := Events (Event_Slot).Sequence;
            end if;
         end loop;
      end Copy_Events;
   end Family_State;

   procedure Validate is
   begin
      if Interfaces.Unsigned_64 (Maximum_Children - 1) >
        Interfaces.Unsigned_64'Last -
          Interfaces.Unsigned_64 (First_Child_Id)
        or else
          (Policy.Task_Model /= Flyology.Lightweight_Task
           and then Policy.Task_Model /= Flyology.Native_Task)
        or else Policy.Impact not in Isolate_Child | Escalate
        or else
          (Policy.Restart /= Never and then not Policy.Restart_Safe)
        or else Policy.Readiness_Timeout < Ada.Real_Time.Time_Span_Zero
        or else Policy.Recovery.Window <= Ada.Real_Time.Time_Span_Zero
        or else Policy.Recovery.Initial_Backoff <
          Ada.Real_Time.Time_Span_Zero
        or else Policy.Recovery.Maximum_Backoff <
          Policy.Recovery.Initial_Backoff
        or else Policy.Recovery.Stability_Reset <=
          Ada.Real_Time.Time_Span_Zero
        or else Policy.Recovery.Recovery_Deadline <
          Ada.Real_Time.Time_Span_Zero
        or else Policy.Stopping.Grace < Ada.Real_Time.Time_Span_Zero
        or else Policy.Stopping.Abort_Observation <
          Ada.Real_Time.Time_Span_Zero
        or else Policy.Stopping.Grace > Ada.Real_Time.Time_Span_Last -
          Policy.Stopping.Abort_Observation
        or else
          (Policy.Task_Model = Flyology.Native_Task
           and then Policy.Has_Group)
        or else
          (Policy.Task_Model = Flyology.Lightweight_Task
           and then Policy.Has_Group
           and then Integer (Policy.Group) = Integer (Control_Group))
      then
         raise Configuration_Error with "invalid supervision family policy";
      end if;
   end Validate;

   procedure Start
     (Item   : in out Family;
      Input  : Request;
      Handle : out Child_Handle)
   is
      Slot : Slot_Index;
   begin
      Item.State.Reserve (Slot, Handle);
      begin
         Item.Inputs (Slot) := Input;
         Item.State.Commit (Slot, Handle);
      exception
         when others =>
            Item.State.Rollback (Slot, Handle);
            raise;
      end;
   end Start;

   procedure Stop
     (Item   : in out Family;
      Handle : Child_Handle)
   is
      Valid : Boolean;
   begin
      Item.State.Stop_One (Handle, Valid);
      if not Valid then
         raise Stale_Handle;
      end if;
   end Stop;

   procedure Request_Shutdown (Item : in out Family) is
   begin
      Item.State.Request_Stop;
   end Request_Shutdown;

   function Accepting (Item : Family) return Boolean is
     (Item.State.Admission_Is_Open);

   function Current
     (Item   : Family;
      Handle : Child_Handle) return Child_Snapshot
   is
      Valid : Boolean;
      Value : constant Child_Snapshot :=
        Item.State.Read_Snapshot (Handle, Valid);
   begin
      if not Valid then
         raise Stale_Handle;
      end if;
      return Value;
   end Current;

   function Current
     (Item  : Family;
      Child : Child_Id) return Child_Snapshot
   is
      Valid : Boolean;
      Value : constant Child_Snapshot :=
        Item.State.Read_Logical_Snapshot (Child, Valid);
   begin
      if not Valid then
         raise Stale_Handle;
      end if;
      return Value;
   end Current;

   function Latest
     (Item  : Family;
      Child : Child_Id) return Child_Handle
   is
      Valid : Boolean;
      Value : constant Child_Handle := Item.State.Read_Latest (Child, Valid);
   begin
      if not Valid then
         raise Stale_Handle;
      end if;
      return Value;
   end Latest;

   procedure Read_Events
     (Item    : in out Family;
      Cursor  : in out Event_Sequence;
      Events  : out Supervisor_Event_Array;
      Count   : out Natural;
      Dropped : out Event_Sequence) is
   begin
      Item.State.Copy_Events (Cursor, Events, Count, Dropped);
   end Read_Events;

   procedure Run_Internal
     (Item    : not null access Family;
      Context : aliased in out Application_Context;
      Inherited : Incident_Context;
      Result  : out Supervisor_Result)
   is
   begin
      Validate;
      Item.State.Configure (Inherited);
      declare
         task type Manager with CPU => Control_Group is
            pragma Task_Info (Flyology.Lightweight_Task);
            entry Start
              (Slot     : Slot_Index;
               Handle   : Child_Handle;
               Incident : Incident_Context);
            entry Finish;
         end Manager;
         type Manager_Access is access Manager;
         type Manager_Array is array (Slot_Index) of Manager_Access;
         procedure Free_Manager is new Ada.Unchecked_Deallocation
           (Manager, Manager_Access);
         Managers : Manager_Array := (others => null);

         procedure Finish_Managers is
         begin
            for Candidate in Slot_Index loop
               if Managers (Candidate) /= null then
                  begin
                     Managers (Candidate).Finish;
                  exception
                     when Tasking_Error => null;
                  end;
               end if;
            end loop;
            for Candidate in Slot_Index loop
               if Managers (Candidate) /= null then
                  while not Ada.Task_Identification.Is_Terminated
                    (Managers (Candidate).all'Identity)
                  loop
                     delay 0.001;
                  end loop;
                  Free_Manager (Managers (Candidate));
               end if;
            end loop;
         end Finish_Managers;

         task body Manager is
            Managed_Slot : Slot_Index := Slot_Index'First;
            Value : Child_Handle :=
              (Id => First_Child_Id, Generation => Generation'First);
            Input : Request;

            procedure Run_Generation
              (Current : Child_Handle;
               Incident : Incident_Context;
               Restart : out Boolean;
               Backoff : out Ada.Real_Time.Time_Span;
               Next    : out Child_Handle;
               Recovery : out Incident_Context)
            is
               Control : aliased Generation_Control;
               Generation_Value : Generation_Result;
            begin
               Open (Control, Current, Incident);
               Item.State.Publish_Starting
                 (Managed_Slot, Current, Incident);
               declare
                  protected type Completion_State is
                     procedure Store (Value : Generation_Result);
                     procedure Read
                       (Done : out Boolean; Value : out Generation_Result);
                  private
                     Finished : Boolean := False;
                     Stored : Generation_Result;
                  end Completion_State;

                  protected body Completion_State is
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
                  end Completion_State;

                  Completion : aliased Completion_State;
                  task Runner with CPU => Control_Group is
                     pragma Task_Info (Flyology.Lightweight_Task);
                  end Runner;
                  task body Runner is
                     Value : Generation_Result;
                  begin
                     begin
                        Run_One_Generation
                          (Context, Input, Control, Value);
                     exception
                        when Occurrence : Tasking_Error =>
                           Value :=
                             (Termination =>
                                Failure_Summary
                                  (Occurrence, Activation_Failure),
                              Reported_Ready => Is_Ready (Control),
                              Incident => Recovery_Incident (Control));
                        when Occurrence : others =>
                           Value :=
                             (Termination => Failure_Summary (Occurrence),
                              Reported_Ready => Is_Ready (Control),
                              Incident => Recovery_Incident (Control));
                     end;
                     Completion.Store (Value);
                  end Runner;

                  Started_At : constant Ada.Real_Time.Time :=
                    Ada.Real_Time.Clock;
                  Stop_At : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
                  Done : Boolean;
                  Ready : Boolean := False;
                  Stop_Published : Boolean := False;
                  Abort_Published : Boolean := False;
                  Stuck_Published : Boolean := False;
                  Incident_Closed : Boolean := not Active (Incident);
                  Stop_Now : Boolean;
                  Shutdown : Boolean;
                  Override : Termination_Kind := No_Termination;
                  Now : Ada.Real_Time.Time;
               begin
                  loop
                     Completion.Read (Done, Generation_Value);
                     Now := Ada.Real_Time.Clock;
                     if not Ready and then Is_Ready (Control) then
                        Ready := True;
                        Item.State.Publish_Ready
                          (Managed_Slot, Current, Now);
                     end if;
                     if not Incident_Closed
                       and then Item.State.Incident_Can_Close
                         (Managed_Slot, Current, Now)
                     then
                        Close_Recovery_Incident (Control);
                        Incident_Closed := True;
                     end if;
                     exit when Done;
                     Item.State.Stop_Status
                       (Managed_Slot, Current, Stop_Now, Shutdown);
                     if not Ready
                       and then Now - Started_At >= Policy.Readiness_Timeout
                     then
                        Stop_Now := True;
                        Shutdown := False;
                        Override := Readiness_Timeout;
                     end if;
                     if Stop_Now and then not Stop_Published then
                        Stop_Published := True;
                        Stop_At := Now;
                        Request_Stop (Control, Shutdown);
                     end if;
                     if Stop_Published
                       and then Now - Stop_At >= Policy.Stopping.Grace
                     then
                        if not Shutdown and then Override = No_Termination then
                           Override := Stop_Timeout;
                        end if;
                        if Policy.Stopping.Request_Abort
                          and then not Abort_Published
                        then
                           Abort_Published := True;
                           Request_Abort (Control);
                        end if;
                        if not Stuck_Published
                          and then Now - Stop_At >= Policy.Stopping.Grace +
                            Policy.Stopping.Abort_Observation
                        then
                           Stuck_Published := True;
                           Item.State.Publish_Stuck (Managed_Slot, Current);
                        end if;
                     end if;
                     delay 0.001;
                  end loop;
                  Generation_Value.Incident := Recovery_Incident (Control);
                  if Generation_Value.Termination.Kind = No_Termination then
                     Generation_Value.Termination :=
                       Empty_Summary (Abnormal_Completion);
                  elsif Override /= No_Termination
                    and then Generation_Value.Termination.Kind in
                      Normal_Return | Cancelled | Supervisor_Shutdown |
                        Abnormal_Completion
                  then
                     Generation_Value.Termination.Kind := Override;
                  elsif Stop_Published and then Shutdown
                    and then Generation_Value.Termination.Kind in
                      Normal_Return | Cancelled
                  then
                     Generation_Value.Termination.Kind := Supervisor_Shutdown;
                  end if;
               end;
               declare
                  Finished_At : constant Ada.Real_Time.Time :=
                    Ada.Real_Time.Clock;
                  Cascade : Incident_Context := Generation_Value.Incident;
                  Deadline : Ada.Real_Time.Time;
               begin
                  if not Active (Cascade) then
                     if Policy.Recovery.Recovery_Deadline >
                       Ada.Real_Time.Time_Last - Finished_At
                     then
                        Deadline := Ada.Real_Time.Time_Last;
                     else
                        Deadline := Finished_At +
                          Policy.Recovery.Recovery_Deadline;
                     end if;
                     Cascade := New_Incident (Finished_At, Deadline);
                  end if;
                  Item.State.Publish_Termination
                    (Managed_Slot,
                     Current,
                     Generation_Value.Termination,
                     Cascade,
                     Finished_At,
                     Restart,
                     Backoff,
                     Next,
                     Recovery);
               end;
            end Run_Generation;

            Restart : Boolean;
            Backoff : Ada.Real_Time.Time_Span;
            Next : Child_Handle;
            Incident : Incident_Context := No_Incident;
            Recovery : Incident_Context := No_Incident;
            Start_Incident : Incident_Context := No_Incident;
         begin
            loop
               select
                  accept Start
                    (Slot     : Slot_Index;
                     Handle   : Child_Handle;
                     Incident : Incident_Context)
                  do
                     Managed_Slot := Slot;
                     Value := Handle;
                     Start_Incident := Incident;
                  end Start;
               or
                  accept Finish;
                  exit;
               end select;

               begin
                  Input := Item.Inputs (Managed_Slot);
                  Incident := Start_Incident;
                  Recovery := No_Incident;
                  loop
                     Run_Generation
                       (Value,
                        Incident,
                        Restart,
                        Backoff,
                        Next,
                        Recovery);
                     exit when not Restart;
                     declare
                        Now : constant Ada.Real_Time.Time :=
                          Ada.Real_Time.Clock;
                     begin
                        if Backoff > Ada.Real_Time.Time_Last - Now then
                           delay until Ada.Real_Time.Time_Last;
                        else
                           delay until Now + Backoff;
                        end if;
                     end;
                     Incident := Recovery;
                     Value := Next;
                  end loop;
               exception
                  when Occurrence : others =>
                     Item.State.Manager_Failed
                       (Managed_Slot,
                        Value,
                        Failure_Summary (Occurrence));
               end;
               Item.State.Manager_Done (Managed_Slot, Value);
            end loop;
         end Manager;

         Available : Boolean;
         Slot : Slot_Index;
         Handle : Child_Handle;
         Incident : Incident_Context;
      begin
         loop
            Item.State.Take_Start (Available, Slot, Handle, Incident);
            if Available then
               begin
                  if Managers (Slot) = null then
                     Managers (Slot) := new Manager;
                  end if;
                  Managers (Slot).Start (Slot, Handle, Incident);
               exception
                  when others =>
                     Item.State.Manager_Done (Slot, Handle);
                     raise;
               end;
            end if;

            exit when Item.State.Is_Finished;
            delay 0.001;
         end loop;
         Finish_Managers;
         Result := Item.State.Read_Result;
      exception
         when others =>
            Item.State.Request_Stop;
            Finish_Managers;
            raise;
      end;
   end Run_Internal;

   procedure Run
     (Item    : aliased in out Family;
      Context : aliased in out Application_Context;
      Result  : out Supervisor_Result) is
   begin
      Run_Internal (Item'Access, Context, No_Incident, Result);
   end Run;

   procedure Run_Nested
     (Item    : aliased in out Family;
      Context : aliased in out Application_Context;
      Parent  : in out Generation_Control;
      Result  : out Supervisor_Result)
   is
      Parent_Handle : constant Child_Handle := Handle (Parent);
      Inherited : constant Incident_Context := Recovery_Incident (Parent);
      pragma Unreferenced (Parent_Handle);
   begin
      Run_Internal (Item'Access, Context, Inherited, Result);
      if Active (Result.Incident)
        and then Result.Outcome /= Shutdown_Completed
      then
         Report_Escalation (Parent, Result.Incident);
      end if;
   end Run_Nested;

end Flyology.Supervision.Families;
