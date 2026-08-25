with Ada.Exceptions;
with Ada.Task_Identification;
with Ada.Unchecked_Deallocation;
with Flyology.Cancellation;
with Flyology.Supervision_Policy;
with Flyology.Task_Lifecycle_Test_Hooks;
with Interfaces;

package body Flyology.Supervision.Families is
   use type Ada.Real_Time.Time;
   use type Ada.Real_Time.Time_Span;
   use type Flyology.Execution_Model;
   use type Flyology.Wake_Sources.Signal_Attempt_Result;
   use type Interfaces.Unsigned_64;
   use type Interfaces.C.int;

   package Kernel renames Flyology.Supervision_Policy;

   function Generation_Is_Current
     (Handle : Child_Handle; Owner : Controller_Id; Id : Child_Id; Value : Generation) return Boolean
   is (Kernel.Authority_Matches
         (Expected_Owner      => Interfaces.Unsigned_64 (Owner),
          Expected_Id         => Id,
          Expected_Generation => Value,
          Supplied_Owner      => Interfaces.Unsigned_64 (Controller (Handle)),
          Supplied_Id         => Child (Handle),
          Supplied_Generation => Current_Generation (Handle)));

   function Empty_Summary (Kind : Termination_Kind) return Termination_Summary
   is ((Kind => Kind, Task_Id => Ada.Task_Identification.Null_Task_Id, others => <>));

   function Completed_Observation
     (Status : Generation_Observation_Status; Snapshot : Child_Snapshot) return Generation_Observation;

   function Completed_Observation
     (Status : Generation_Observation_Status; Snapshot : Child_Snapshot) return Generation_Observation is
   begin
      case Status is
         when Generation_Terminated =>
            return (Status => Generation_Terminated, Snapshot => Snapshot);

         when Generation_Replaced   =>
            return (Status => Generation_Replaced, Snapshot => Snapshot);

         when Observation_Timed_Out =>
            raise Program_Error with "incomplete generation observation";
      end case;
   end Completed_Observation;

   function Failure_Summary
     (Occurrence : Ada.Exceptions.Exception_Occurrence; Kind : Termination_Kind := Unhandled_Exception)
      return Termination_Summary
   is
      Name        : constant String :=
        Ada.Exceptions.Exception_Name (Ada.Exceptions.Exception_Identity (Occurrence));
      Message     : constant String := Ada.Exceptions.Exception_Message (Occurrence);
      Name_Length : constant Exception_Name_Length :=
        Exception_Name_Length'Min (Exception_Name_Length'Last, Name'Length);
      Length      : constant Diagnostic_Length :=
        Diagnostic_Length'Min (Diagnostic_Length'Last, Message'Length);
      Value       : Termination_Summary := Empty_Summary (Kind);
   begin
      Value.Exception_Id := Ada.Exceptions.Exception_Identity (Occurrence);
      Value.Exception_Name_Length := Name_Length;
      Value.Exception_Name_Truncated := Name'Length > Name_Length;
      if Name_Length > 0 then
         Value.Exception_Name (1 .. Name_Length) := Name (Name'First .. Name'First + Name_Length - 1);
      end if;
      Value.Message_Length := Length;
      Value.Message_Truncated := Message'Length > Length;
      if Length > 0 then
         Value.Message (1 .. Length) := Message (Message'First .. Message'First + Length - 1);
      end if;
      return Value;
   end Failure_Summary;

   function Logical_Id (Slot : Slot_Index) return Child_Id
   is (Child_Id (Interfaces.Unsigned_64 (First_Child_Id) + Interfaces.Unsigned_64 (Slot - Slot_Index'First)));

   function Next_Slot (Value : Slot_Index) return Slot_Index
   is (Slot_Index
         (((Natural (Value) - Natural (Slot_Index'First) + 1) mod Maximum_Children)
          + Natural (Slot_Index'First)));

   procedure Drain_Monitor_Signals (Item : in out Monitor_Signal_Guard; Use_Test_Hooks : Boolean) is
      Result : Flyology.Wake_Sources.Signal_Attempt_Result;
   begin
      while Item.Armed loop
         if not Item.Claimed then
            Item.Owner.State.Claim_Monitor_Signal (Item'Unchecked_Access);
            exit when not Item.Armed;
         end if;
         if Flyology.Task_Lifecycle_Test_Hooks.Enabled then
            if Use_Test_Hooks then
               Flyology.Task_Lifecycle_Test_Hooks.Barrier
                 (Flyology.Task_Lifecycle_Test_Hooks.Admission_Signal_Claimed);
            end if;
         end if;
         Item.Owner.State.Try_Acknowledge_Monitor_Signal (Item'Unchecked_Access, Result);
         case Result is
            when Flyology.Wake_Sources.Signal_Delivered   =>
               null;

            when Flyology.Wake_Sources.Signal_Interrupted =>
               if Flyology.Task_Lifecycle_Test_Hooks.Enabled and then Use_Test_Hooks then
                  Flyology.Task_Lifecycle_Test_Hooks.Barrier
                    (Flyology.Task_Lifecycle_Test_Hooks.Admission_Signal_Interrupted);
               end if;
               delay 0.0;

            when Flyology.Wake_Sources.Signal_Failed      =>
               raise Program_Error with "admission monitor wake source is invalid";
         end case;
      end loop;
   end Drain_Monitor_Signals;

   procedure Flush_Monitor_Signals (Item : in out Monitor_Signal_Guard) is
   begin
      if Item.Armed then
         Drain_Monitor_Signals (Item, Use_Test_Hooks => True);
      end if;
   end Flush_Monitor_Signals;

   overriding
   procedure Finalize (Item : in out Monitor_Signal_Guard) is
   begin
      if Item.Armed then
         if Flyology.Task_Lifecycle_Test_Hooks.Enabled then
            Flyology.Task_Lifecycle_Test_Hooks.Barrier
              (Flyology.Task_Lifecycle_Test_Hooks.Admission_Signal_Finalizing);
         end if;
         Drain_Monitor_Signals (Item, Use_Test_Hooks => False);
      end if;
   exception
      when others =>
         null;
   end Finalize;

   protected body Family_State is
      procedure Complete_Monitors
        (Slot    : Slot_Index;
         Status  : Generation_Observation_Status;
         Signals : not null access Monitor_Signal_Guard) is
      begin
         pragma Assert (Status /= Observation_Timed_Out);
         for Ticket in Monitor_Index loop
            if Monitor_States (Ticket) = Monitor_Pending
              and then (if Status = Generation_Terminated
                        then
                          Generation_Is_Current
                            (Monitor_Handles (Ticket),
                             Identity,
                             Snapshots (Slot).Id,
                             Snapshots (Slot).Generation)
                        else
                          Monitor_Snapshots (Ticket).Escalated
                          and then Controller (Monitor_Handles (Ticket)) = Identity
                          and then Child (Monitor_Handles (Ticket)) = Snapshots (Slot).Id
                          and then Current_Generation (Monitor_Handles (Ticket))
                                   < Snapshots (Slot).Generation)
            then
               declare
                  Signal : constant Interfaces.C.int :=
                    (if Monitor_Snapshots (Ticket).Escalated
                     then Interfaces.C.int (Monitor_Snapshots (Ticket).Attempts)
                     else Interfaces.C.int (-1));
               begin
                  if Signal >= 0 then
                     Signals.Armed := True;
                     --  Matching no longer needs the observed handle. Retain
                     --  the nonnegative borrowed descriptor in its controller
                     --  field without adding storage to every Family.
                     Monitor_Handles (Ticket).Controller := Controller_Id (Interfaces.C.unsigned (Signal));
                  end if;
                  Monitor_States (Ticket) :=
                    (if Signal >= 0 and then Status = Generation_Terminated
                     then Monitor_Termination_Signal_Pending
                     elsif Signal >= 0
                     then Monitor_Replacement_Signal_Pending
                     elsif Status = Generation_Terminated
                     then Monitor_Terminated
                     else Monitor_Replaced);
                  Monitor_Snapshots (Ticket) := Snapshots (Slot);
               end;
            end if;
         end loop;
      end Complete_Monitors;

      procedure Configure (Identity : Controller_Id; Inherited : Incident_Context) is
      begin
         if Run_Used then
            raise Program_Error with "supervision family is one-shot";
         end if;
         Run_Used := True;
         Configured := True;
         Family_State.Identity := Identity;
         Inherited_Incident := Inherited;
         Result :=
           (Outcome     => Shutdown_Completed,
            Child       => First_Child_Id,
            Generation  => Generation'First,
            Termination => Empty_Summary (Supervisor_Shutdown),
            Incident    => No_Incident);
         for Slot in Slot_Index loop
            Recovery_Requested (Slot) := False;
            Intervention (Slot) := Empty_Summary (No_Termination);
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
         Backoff     : Ada.Real_Time.Time_Span := Ada.Real_Time.Time_Span_Zero)
      is
         Event_Slot : Positive;
      begin
         if not Kernel.Recorded_Transition_Allowed (Kind, Before, After) then
            raise Program_Error with "illegal family supervision lifecycle transition";
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
                (((Event_First - Event_Buffer'First + Event_Length) mod Event_Capacity) + Event_Buffer'First);
            Event_Length := Event_Length + 1;
         else
            Event_Slot := Event_First;
            Event_First := (if Event_First = Event_Buffer'Last then Event_Buffer'First else Event_First + 1);
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

      procedure Reserve (Slot : out Slot_Index; Handle : out Child_Handle) is
         Found      : Boolean := False;
         Has_Vacant : Boolean := False;
         Selected   : Slot_Index := Slot_Index'First;
      begin
         if not Kernel.Family_Admission_Open (Configured, Shutdown, Terminal) then
            raise Program_Error with "family admission is closed";
         end if;
         for Candidate in Slot_Index loop
            if Slots (Candidate) in Free | Reapable then
               Has_Vacant := True;
               if not Found
                 and then (not Has_Generation (Candidate)
                           or else Flyology.Supervision_Policy.Generation_Can_Advance
                                     (Snapshots (Candidate).Generation))
               then
                  Selected := Candidate;
                  Found := True;
               end if;
            end if;
         end loop;
         if not Found then
            if Has_Vacant then
               raise Program_Error with "family generation space exhausted";
            else
               raise Constraint_Error with "family capacity is exhausted";
            end if;
         end if;

         if Has_Generation (Selected) then
            Snapshots (Selected).Generation :=
              Flyology.Supervision_Policy.Next_Generation (Snapshots (Selected).Generation);
         else
            Has_Generation (Selected) := True;
         end if;
         Slots (Selected) := Reserved;
         Reserved_Children := Reserved_Children + 1;
         Stop_Requested (Selected) := False;
         Recovery_Requested (Selected) := False;
         Intervention (Selected) := Empty_Summary (No_Termination);
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
           (Controller => Identity,
            Id         => Logical_Id (Selected),
            Generation => Snapshots (Selected).Generation);
      end Reserve;

      procedure Commit (Slot : Slot_Index; Handle : Child_Handle) is
      begin
         if Slots (Slot) /= Reserved
           or else not Generation_Is_Current
                         (Handle, Identity, Snapshots (Slot).Id, Snapshots (Slot).Generation)
         then
            raise Program_Error with "family reservation is stale";
         elsif not Kernel.Family_Admission_Open (Configured, Shutdown, Terminal) then
            raise Program_Error with "family admission closed during copy";
         end if;
         Reserved_Children := Reserved_Children - 1;
         Slots (Slot) := Queued;
         Queue (Queue_Tail) := Slot;
         Queue_Tail := Next_Slot (Queue_Tail);
         Queue_Length := Queue_Length + 1;
      end Commit;

      procedure Rollback (Slot : Slot_Index; Handle : Child_Handle) is
      begin
         if Slots (Slot) = Reserved
           and then Generation_Is_Current (Handle, Identity, Snapshots (Slot).Id, Snapshots (Slot).Generation)
         then
            Reserved_Children := Reserved_Children - 1;
            Slots (Slot) := Free;
         end if;
      end Rollback;

      procedure Reserve_Prepared
        (Slot   : not null access Slot_Index;
         Handle : not null access Child_Handle;
         Active : not null access Boolean;
         Status : out Prepared_Reserve_Status)
      is
         Found        : Boolean := False;
         Has_Occupied : Boolean := False;
         Selected     : Slot_Index := Slot_Index'First;
      begin
         Slot.all := Slot_Index'First;
         Handle.all := (Controller => Identity, Id => First_Child_Id, Generation => Generation'First);
         Active.all := False;
         if not Kernel.Family_Admission_Open (Configured, Shutdown, Terminal) then
            Status := Prepared_Admission_Closed;
            return;
         end if;

         for Candidate in Slot_Index loop
            if Slots (Candidate) in Free | Reapable then
               if not Has_Generation (Candidate)
                 or else Flyology.Supervision_Policy.Generation_Can_Advance (Snapshots (Candidate).Generation)
               then
                  if not Found then
                     Selected := Candidate;
                     Found := True;
                  end if;
               end if;
            else
               Has_Occupied := True;
            end if;
         end loop;
         if not Found then
            Status := (if Has_Occupied then Prepared_Capacity_Exhausted else Prepared_Generation_Exhausted);
            return;
         end if;

         if Flyology.Task_Lifecycle_Test_Hooks.Enabled
           and then Flyology.Task_Lifecycle_Test_Hooks.Consume_Prepared_Generation_Final
         then
            Has_Generation (Selected) := True;
            Snapshots (Selected).Generation := Generation'Last;
         elsif Has_Generation (Selected) then
            Snapshots (Selected).Generation :=
              Flyology.Supervision_Policy.Next_Generation (Snapshots (Selected).Generation);
         else
            Has_Generation (Selected) := True;
         end if;
         Slots (Selected) := Preparing;
         Reserved_Children := Reserved_Children + 1;
         Stop_Requested (Selected) := False;
         Recovery_Requested (Selected) := False;
         Intervention (Selected) := Empty_Summary (No_Termination);
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
         Slot.all := Selected;
         Handle.all :=
           (Controller => Identity,
            Id         => Logical_Id (Selected),
            Generation => Snapshots (Selected).Generation);
         Active.all := True;
         Status := Prepared_Reserved;
      end Reserve_Prepared;

      procedure Publish_Prepared (Slot : Slot_Index; Handle : Child_Handle) is
      begin
         if Slots (Slot) /= Preparing
           or else not Generation_Is_Current
                         (Handle, Identity, Snapshots (Slot).Id, Snapshots (Slot).Generation)
         then
            raise Program_Error with "prepared family reservation is stale";
         end if;
         Slots (Slot) := Prepared;
      end Publish_Prepared;

      procedure Rollback_Prepared (Slot : Slot_Index; Handle : Child_Handle; Active : not null access Boolean)
      is
      begin
         if Active.all
           and then Slots (Slot) in Preparing | Prepared
           and then Generation_Is_Current (Handle, Identity, Snapshots (Slot).Id, Snapshots (Slot).Generation)
         then
            Reserved_Children := Reserved_Children - 1;
            Slots (Slot) := Free;
         end if;
         Active.all := False;
      end Rollback_Prepared;

      procedure Commit_Prepared
        (Slot             : Slot_Index;
         Handle           : Child_Handle;
         Claim_Active     : not null access Boolean;
         Admission_Slot   : not null access Slot_Index;
         Admission_Handle : not null access Child_Handle;
         Admission_Active : not null access Boolean;
         Status           : out Prepared_Commit_Status) is
      begin
         if not Claim_Active.all or else Admission_Active.all then
            raise Program_Error with "invalid prepared admission ownership";
         elsif Slots (Slot) /= Prepared
           or else not Generation_Is_Current
                         (Handle, Identity, Snapshots (Slot).Id, Snapshots (Slot).Generation)
         then
            raise Program_Error with "prepared admission is stale";
         elsif Shutdown or else Terminal then
            Status := Prepared_Commit_Closed;
            return;
         end if;

         Slots (Slot) := Committed_Blocked;
         Admission_Slot.all := Slot;
         Admission_Handle.all := Handle;
         Admission_Active.all := True;
         Claim_Active.all := False;
         Status := Prepared_Committed;
      end Commit_Prepared;

      procedure Release_Prepared
        (Slot      : Slot_Index;
         Handle    : Child_Handle;
         Released  : not null access Boolean;
         Succeeded : not null access Boolean) is
      begin
         if Released.all then
            Succeeded.all := True;
            return;
         elsif Slots (Slot) /= Committed_Blocked
           or else not Generation_Is_Current
                         (Handle, Identity, Snapshots (Slot).Id, Snapshots (Slot).Generation)
         then
            raise Program_Error with "committed admission is stale";
         elsif Shutdown or else Terminal then
            Succeeded.all := False;
            return;
         end if;

         Reserved_Children := Reserved_Children - 1;
         Slots (Slot) := Released_Queued;
         Queue (Queue_Tail) := Slot;
         Queue_Tail := Next_Slot (Queue_Tail);
         Queue_Length := Queue_Length + 1;
         Released.all := True;
         Succeeded.all := True;
      end Release_Prepared;

      procedure Begin_Admission_Cancel
        (Slot      : Slot_Index;
         Handle    : Child_Handle;
         Active    : not null access Boolean;
         Released  : not null access Boolean;
         Signals   : not null access Monitor_Signal_Guard;
         Completed : out Boolean) is
      begin
         Completed := True;
         if not Active.all then
            return;
         elsif Controller (Handle) /= Identity or else Child (Handle) /= Snapshots (Slot).Id then
            raise Program_Error with "prepared admission belongs to another family";
         end if;

         case Slots (Slot) is
            when Committed_Blocked                  =>
               Reserved_Children := Reserved_Children - 1;
               Snapshots (Slot).Termination :=
                 Empty_Summary ((if Shutdown then Supervisor_Shutdown else Cancelled));
               Record_Event
                 (Slot,
                  Lifecycle_Changed,
                  Snapshots (Slot).State,
                  Joined,
                  Ada.Real_Time.Clock,
                  Snapshots (Slot).Termination.Kind,
                  Active_Incidents (Slot));
               Snapshots (Slot).State := Joined;
               Snapshots (Slot).Ready := False;
               Snapshots (Slot).Live := False;
               Complete_Monitors (Slot, Generation_Terminated, Signals);
               Slots (Slot) := Free;
               Released.all := False;
               Active.all := False;

            when Released_Queued | Released_Managed =>
               Stop_Requested (Slot) := True;
               Completed := False;

            when Released_Reapable                  =>
               Slots (Slot) := Reapable;
               Live_Managers := Live_Managers - 1;
               Released.all := False;
               Active.all := False;

            when others                             =>
               raise Program_Error with "prepared admission state is inconsistent";
         end case;
      end Begin_Admission_Cancel;

      entry Await_Admission_Cancel (for Slot in Slot_Index)
        (Handle : Child_Handle; Active : not null access Boolean; Released : not null access Boolean)
        when Slots (Slot) = Released_Reapable
      is
      begin
         if Active.all and then Controller (Handle) = Identity and then Child (Handle) = Snapshots (Slot).Id
         then
            Slots (Slot) := Reapable;
            Live_Managers := Live_Managers - 1;
            Released.all := False;
            Active.all := False;
         end if;
      end Await_Admission_Cancel;

      procedure Take_Start
        (Available : out Boolean;
         Slot      : out Slot_Index;
         Handle    : out Child_Handle;
         Incident  : out Incident_Context) is
      begin
         Available := Queue_Length > 0;
         Slot := Slot_Index'First;
         Handle := (Controller => Identity, Id => First_Child_Id, Generation => Generation'First);
         Incident := No_Incident;
         if not Available then
            return;
         end if;
         Slot := Queue (Queue_Head);
         Queue_Head := Next_Slot (Queue_Head);
         Queue_Length := Queue_Length - 1;
         if Slots (Slot) not in Queued | Released_Queued then
            raise Program_Error with "family start queue is inconsistent";
         end if;
         Slots (Slot) := (if Slots (Slot) = Released_Queued then Released_Managed else Managed);
         Live_Managers := Live_Managers + 1;
         Handle :=
           (Controller => Identity, Id => Snapshots (Slot).Id, Generation => Snapshots (Slot).Generation);
         Incident := Inherited_Incident;
      end Take_Start;

      procedure Stop_One (Handle : Child_Handle; Valid : out Boolean) is
         Slot : Slot_Index;
      begin
         Valid := False;
         if Child (Handle) < First_Child_Id
           or else Interfaces.Unsigned_64 (Child (Handle)) - Interfaces.Unsigned_64 (First_Child_Id)
                   >= Interfaces.Unsigned_64 (Maximum_Children)
         then
            return;
         end if;
         Slot :=
           Slot_Index (Interfaces.Unsigned_64 (Child (Handle)) - Interfaces.Unsigned_64 (First_Child_Id) + 1);
         Valid :=
           Kernel.Family_Stop_Command_Allowed
             (Current =>
                Generation_Is_Current (Handle, Identity, Snapshots (Slot).Id, Snapshots (Slot).Generation),
              Queued  => Slots (Slot) in Queued | Released_Queued,
              Managed => Slots (Slot) in Managed | Released_Managed,
              Live    => Snapshots (Slot).Live);
         if Valid then
            Stop_Requested (Slot) := True;
         end if;
      end Stop_One;

      procedure Stop_Status
        (Slot     : Slot_Index;
         Handle   : Child_Handle;
         Stop     : out Boolean;
         Shutdown : out Boolean;
         Override : out Termination_Summary) is
      begin
         Stop := False;
         Shutdown := Family_State.Shutdown;
         Override := Empty_Summary (No_Termination);
         if Slots (Slot) in Managed | Released_Managed
           and then Generation_Is_Current (Handle, Identity, Snapshots (Slot).Id, Snapshots (Slot).Generation)
         then
            Stop := Stop_Requested (Slot) or else Recovery_Requested (Slot) or else Family_State.Shutdown;
            if Recovery_Requested (Slot) then
               Override := Intervention (Slot);
            end if;
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

      procedure Request_Intervention
        (Handle : Child_Handle; Termination : Termination_Summary; Valid : out Boolean)
      is
         Slot : Slot_Index;
      begin
         Valid := False;
         if Child (Handle) < First_Child_Id
           or else Interfaces.Unsigned_64 (Child (Handle)) - Interfaces.Unsigned_64 (First_Child_Id)
                   >= Interfaces.Unsigned_64 (Maximum_Children)
         then
            return;
         end if;
         Slot :=
           Slot_Index (Interfaces.Unsigned_64 (Child (Handle)) - Interfaces.Unsigned_64 (First_Child_Id) + 1);
         Valid :=
           Kernel.Family_Intervention_Command_Allowed
             (Current          =>
                Generation_Is_Current (Handle, Identity, Snapshots (Slot).Id, Snapshots (Slot).Generation),
              Managed          => Slots (Slot) in Managed | Released_Managed,
              Live             => Snapshots (Slot).Live,
              Ready            => Snapshots (Slot).Ready,
              Stop_Pending     => Stop_Requested (Slot),
              Shutdown         => Family_State.Shutdown,
              Terminal         => Family_State.Terminal,
              Recovery_Pending => Recovery_Requested (Slot));
         if Valid then
            Intervention (Slot) := Termination;
            Recovery_Requested (Slot) := True;
         end if;
      end Request_Intervention;

      procedure Publish_Starting
        (Slot     : Slot_Index;
         Handle   : Child_Handle;
         Incident : Incident_Context;
         Signals  : not null access Monitor_Signal_Guard;
         Accepted : out Boolean)
      is
         Before    : Child_State;
         Advancing : Boolean;
      begin
         Accepted :=
           Kernel.Family_Generation_Start_Allowed
             (Generation_Allowed =>
                Kernel.Generation_Start_Allowed
                  (Expected_Id         => Snapshots (Slot).Id,
                   Expected_Generation => Snapshots (Slot).Generation,
                   Supplied_Id         => Child (Handle),
                   Supplied_Generation => Current_Generation (Handle),
                   Restart_Pending     => Snapshots (Slot).State = Backing_Off),
              Managed            => Slots (Slot) in Managed | Released_Managed,
              Stop_Pending       => Stop_Requested (Slot),
              Shutdown           => Family_State.Shutdown,
              Terminal           => Family_State.Terminal);
         if Accepted then
            Before := Snapshots (Slot).State;
            Advancing := Current_Generation (Handle) /= Snapshots (Slot).Generation;
            Active_Incidents (Slot) := Incident;
            Snapshots (Slot).Generation := Current_Generation (Handle);
            if Advancing then
               Snapshots (Slot).State := Restarting;
               Record_Event
                 (Slot, Lifecycle_Changed, Before, Restarting, Ada.Real_Time.Clock, Incident => Incident);
               Before := Restarting;
            end if;
            Snapshots (Slot).State := Starting;
            Snapshots (Slot).Live := True;
            Snapshots (Slot).Ready := False;
            Snapshots (Slot).Termination := Empty_Summary (No_Termination);
            Record_Event
              (Slot, Lifecycle_Changed, Before, Starting, Ada.Real_Time.Clock, Incident => Incident);
            if Advancing then
               Complete_Monitors (Slot, Generation_Replaced, Signals);
            end if;
         end if;
      end Publish_Starting;

      function Replacement_Wait_Allowed (Slot : Slot_Index) return Boolean
      is (Kernel.Family_Replacement_Wait_Allowed
            (Managed      => Slots (Slot) in Managed | Released_Managed,
             Backing_Off  => Snapshots (Slot).State = Backing_Off,
             Stop_Pending => Stop_Requested (Slot),
             Shutdown     => Family_State.Shutdown,
             Terminal     => Family_State.Terminal));

      procedure Publish_Ready (Slot : Slot_Index; Handle : Child_Handle; Now : Ada.Real_Time.Time) is
      begin
         if Slots (Slot) in Managed | Released_Managed
           and then Generation_Is_Current (Handle, Identity, Snapshots (Slot).Id, Snapshots (Slot).Generation)
           and then Snapshots (Slot).Live
           and then Snapshots (Slot).State = Starting
         then
            Snapshots (Slot).State := Running;
            Snapshots (Slot).Ready := True;
            Ready_Since (Slot) := Now;
            Record_Event
              (Slot, Readiness_Published, Starting, Running, Now, Incident => Active_Incidents (Slot));
            if Has_Incident (Slot) and then Active (Active_Incidents (Slot)) then
               Record_Event
                 (Slot, Restart_Completed, Running, Running, Now, Incident => Active_Incidents (Slot));
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
           (if Snapshots (Slot).Live then Snapshots (Slot).State else Failed_Escalated);
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
               if Slots (Other) in Queued | Released_Queued | Managed | Released_Managed then
                  Stop_Requested (Other) := True;
               end if;
            end loop;
         end if;
      end Begin_Terminal;

      procedure Publish_Stuck (Slot : Slot_Index; Handle : Child_Handle) is
      begin
         if Slots (Slot) in Managed | Released_Managed
           and then Generation_Is_Current (Handle, Identity, Snapshots (Slot).Id, Snapshots (Slot).Generation)
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
            Begin_Terminal (Child_Stuck, Slot, Snapshots (Slot).Termination, Active_Incidents (Slot));
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
         Recovery    : out Incident_Context;
         Signals     : not null access Monitor_Signal_Guard)
      is
         Next_Attempt : Natural;
         Elapsed      : Ada.Real_Time.Time_Span;
         Cascade      : Incident_Context := Incident;
         Before       : Child_State;
      begin
         Restart := False;
         Backoff := Ada.Real_Time.Time_Span_Zero;
         Next := Handle;
         Recovery := Incident;
         if Slots (Slot) not in Managed | Released_Managed
           or else not Generation_Is_Current
                         (Handle, Identity, Snapshots (Slot).Id, Snapshots (Slot).Generation)
         then
            return;
         end if;
         Recovery_Requested (Slot) := False;
         Before := Snapshots (Slot).State;
         Snapshots (Slot).Live := False;
         Snapshots (Slot).Ready := False;
         Snapshots (Slot).State := Terminated;
         if Snapshots (Slot).Termination.Kind /= Stuck then
            Snapshots (Slot).Termination := Termination;
         end if;
         Complete_Monitors (Slot, Generation_Terminated, Signals);
         Record_Event
           (Slot, Lifecycle_Changed, Before, Terminated, Now, Snapshots (Slot).Termination.Kind, Incident);

         if Shutdown or else Stop_Requested (Slot) then
            return;
         elsif not Flyology.Supervision_Policy.Should_Restart (Policy.Restart, Termination.Kind) then
            if Policy.Impact = Escalate and then Termination.Kind /= Normal_Return then
               Begin_Terminal (Failure_Escalated, Slot, Termination, Incident);
            end if;
            return;
         elsif Policy.Impact = Escalate then
            Begin_Terminal (Failure_Escalated, Slot, Termination, Incident);
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
                  Begin_Terminal (Recovery_Exhausted, Slot, Snapshots (Slot).Termination, Incident);
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
         if not Has_Incident (Slot) or else Last_Incident (Slot) /= Flyology.Supervision.Incident (Cascade)
         then
            Incident_Since (Slot) := Now;
         end if;
         if Window_Used (Slot) = 0 or else Now - Window_Since (Slot) >= Policy.Recovery.Window then
            Window_Since (Slot) := Now;
            Window_Used (Slot) := 0;
         end if;
         if Total_Used (Slot) >= Policy.Recovery.Total_Attempts
           or else Window_Used (Slot) >= Policy.Recovery.Burst_Attempts
           or else Now > Recovery_Deadline (Cascade)
         then
            Snapshots (Slot).Termination.Kind := Policy_Exhaustion;
            Begin_Terminal (Recovery_Exhausted, Slot, Snapshots (Slot).Termination, Cascade);
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
           or else not Flyology.Supervision_Policy.Generation_Can_Advance (Snapshots (Slot).Generation)
         then
            Snapshots (Slot).Termination.Kind := Policy_Exhaustion;
            Begin_Terminal (Recovery_Exhausted, Slot, Snapshots (Slot).Termination, Cascade);
            return;
         end if;

         Total_Used (Slot) := Total_Used (Slot) + 1;
         Window_Used (Slot) := Window_Used (Slot) + 1;
         Consecutive (Slot) := Consecutive (Slot) + 1;
         Last_Incident (Slot) := Flyology.Supervision.Incident (Cascade);
         Last_Attempt (Slot) := Attempt (Cascade);
         Has_Incident (Slot) := True;
         Snapshots (Slot).Attempts := Interfaces.Unsigned_64 (Total_Used (Slot));
         Snapshots (Slot).Backoff := Backoff;
         Snapshots (Slot).State := Backing_Off;
         Record_Event
           (Slot, Restart_Admitted, Terminated, Backing_Off, Now, Termination.Kind, Cascade, Backoff);
         Next :=
           (Controller => Identity,
            Id         => Snapshots (Slot).Id,
            Generation => Flyology.Supervision_Policy.Next_Generation (Snapshots (Slot).Generation));
         Restart := True;
      end Publish_Termination;

      function Incident_Can_Close
        (Slot : Slot_Index; Handle : Child_Handle; Now : Ada.Real_Time.Time) return Boolean
      is (Slots (Slot) in Managed | Released_Managed
          and then Generation_Is_Current (Handle, Identity, Snapshots (Slot).Id, Snapshots (Slot).Generation)
          and then Snapshots (Slot).Live
          and then Snapshots (Slot).Ready
          and then Ready_Since (Slot) /= Ada.Real_Time.Time_First
          and then Now - Ready_Since (Slot) >= Policy.Recovery.Stability_Reset);

      procedure Manager_Done
        (Slot : Slot_Index; Handle : Child_Handle; Signals : not null access Monitor_Signal_Guard) is
      begin
         if Slots (Slot) in Managed | Released_Managed
           and then Generation_Is_Current (Handle, Identity, Snapshots (Slot).Id, Snapshots (Slot).Generation)
         then
            Record_Event
              (Slot,
               Lifecycle_Changed,
               Snapshots (Slot).State,
               Joined,
               Ada.Real_Time.Clock,
               Snapshots (Slot).Termination.Kind,
               Active_Incidents (Slot));
            if Slots (Slot) = Released_Managed then
               Slots (Slot) := Released_Reapable;
            else
               Slots (Slot) := Reapable;
               Live_Managers := Live_Managers - 1;
            end if;
            Snapshots (Slot).State := Joined;
            Snapshots (Slot).Live := False;
            Complete_Monitors (Slot, Generation_Terminated, Signals);
         end if;
      end Manager_Done;

      procedure Manager_Failed
        (Slot        : Slot_Index;
         Handle      : Child_Handle;
         Termination : Termination_Summary;
         Signals     : not null access Monitor_Signal_Guard) is
      begin
         if Slots (Slot) in Managed | Released_Managed
           and then Generation_Is_Current (Handle, Identity, Snapshots (Slot).Id, Snapshots (Slot).Generation)
         then
            Snapshots (Slot).Termination := Termination;
            Snapshots (Slot).Live := False;
            Snapshots (Slot).Ready := False;
            Snapshots (Slot).State := Failed_Escalated;
            Complete_Monitors (Slot, Generation_Terminated, Signals);
            Begin_Terminal (Failure_Escalated, Slot, Termination, Active_Incidents (Slot));
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
            if Slots (Slot) in Queued | Released_Queued | Managed | Released_Managed then
               Stop_Requested (Slot) := True;
            end if;
         end loop;
      end Request_Stop;

      function Is_Finished return Boolean
      is (Flyology.Supervision_Policy.Family_Finished
            (Shutdown, Terminal, Reserved_Children, Queue_Length, Live_Managers));

      function Admission_Is_Open return Boolean
      is (Kernel.Family_Admission_Open (Configured, Shutdown, Terminal));

      function Read_Result return Supervisor_Result
      is (Result);

      function Read_Snapshot (Handle : Child_Handle; Valid : out Boolean) return Child_Snapshot is
         Slot : Slot_Index := Slot_Index'First;
      begin
         Valid := False;
         if Child (Handle) >= First_Child_Id
           and then Interfaces.Unsigned_64 (Child (Handle)) - Interfaces.Unsigned_64 (First_Child_Id)
                    < Interfaces.Unsigned_64 (Maximum_Children)
         then
            Slot :=
              Slot_Index
                (Interfaces.Unsigned_64 (Child (Handle)) - Interfaces.Unsigned_64 (First_Child_Id) + 1);
            Valid :=
              Has_Generation (Slot)
              and then Generation_Is_Current
                         (Handle, Identity, Snapshots (Slot).Id, Snapshots (Slot).Generation);
         end if;
         return Snapshots (Slot);
      end Read_Snapshot;

      function Read_Logical_Snapshot (Child : Child_Id; Valid : out Boolean) return Child_Snapshot is
         Slot  : Slot_Index := Slot_Index'First;
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
           and then Interfaces.Unsigned_64 (Child) - Interfaces.Unsigned_64 (First_Child_Id)
                    < Interfaces.Unsigned_64 (Maximum_Children)
         then
            Slot := Slot_Index (Interfaces.Unsigned_64 (Child) - Interfaces.Unsigned_64 (First_Child_Id) + 1);
            Valid := Slots (Slot) /= Free and then Has_Generation (Slot);
            if Valid then
               Value := Snapshots (Slot);
            end if;
         end if;
         return Value;
      end Read_Logical_Snapshot;

      function Read_Latest (Child : Child_Id; Valid : out Boolean) return Child_Handle is
         Slot  : Slot_Index := Slot_Index'First;
         Value : Child_Handle :=
           (Controller => Identity, Id => First_Child_Id, Generation => Generation'First);
      begin
         Valid := False;
         if Child >= First_Child_Id
           and then Interfaces.Unsigned_64 (Child) - Interfaces.Unsigned_64 (First_Child_Id)
                    < Interfaces.Unsigned_64 (Maximum_Children)
         then
            Slot := Slot_Index (Interfaces.Unsigned_64 (Child) - Interfaces.Unsigned_64 (First_Child_Id) + 1);
            Valid := Slots (Slot) /= Free and then Has_Generation (Slot);
            if Valid then
               Value :=
                 (Controller => Identity,
                  Id         => Snapshots (Slot).Id,
                  Generation => Snapshots (Slot).Generation);
            end if;
         end if;
         return Value;
      end Read_Latest;

      procedure Register_Monitor
        (Handle    : Child_Handle;
         Immediate : out Boolean;
         Status    : out Generation_Observation_Status;
         Snapshot  : out Child_Snapshot;
         Ticket    : not null access Monitor_Index;
         Token     : not null access Monitor_Token;
         Active    : not null access Boolean;
         Valid     : out Boolean)
      is
         Slot     : Slot_Index := Slot_Index'First;
         Selected : Monitor_Index := Monitor_Index'First;
         Found    : Boolean := False;
         Reusable : Boolean := False;
      begin
         Immediate := True;
         Status := Observation_Timed_Out;
         Ticket.all := Monitor_Index'First;
         Token.all := 0;
         Active.all := False;
         Valid := False;
         Snapshot := Snapshots (Slot_Index'First);
         if Controller (Handle) /= Identity
           or else Child (Handle) < First_Child_Id
           or else Interfaces.Unsigned_64 (Child (Handle)) - Interfaces.Unsigned_64 (First_Child_Id)
                   >= Interfaces.Unsigned_64 (Maximum_Children)
         then
            return;
         end if;

         Slot :=
           Slot_Index (Interfaces.Unsigned_64 (Child (Handle)) - Interfaces.Unsigned_64 (First_Child_Id) + 1);
         Snapshot := Snapshots (Slot);
         Valid := Has_Generation (Slot);
         if not Valid then
            return;
         elsif Current_Generation (Handle) /= Snapshots (Slot).Generation then
            Status := Generation_Replaced;
            return;
         elsif Slots (Slot) in Free | Reapable
           or else (not Snapshots (Slot).Live
                    and then Snapshots (Slot).State in Terminated | Backing_Off | Failed_Escalated | Joined)
         then
            Status := Generation_Terminated;
            return;
         end if;

         for Candidate in Monitor_Index loop
            if Monitor_Tokens (Candidate) /= Monitor_Token'Last then
               Reusable := True;
            end if;
            if Monitor_States (Candidate) = Monitor_Free
              and then Monitor_Tokens (Candidate) /= Monitor_Token'Last
            then
               Selected := Candidate;
               Found := True;
               exit;
            end if;
         end loop;
         if not Found then
            if Reusable then
               raise Constraint_Error with "supervision family monitor capacity exhausted";
            else
               raise Program_Error with "supervision family monitor identity exhausted";
            end if;
         end if;

         Monitor_Tokens (Selected) := Monitor_Tokens (Selected) + 1;
         Monitor_Handles (Selected) := Handle;
         Monitor_Snapshots (Selected) := Snapshots (Slot);
         --  A pending monitor owns this snapshot as scratch storage.  The
         --  completed snapshot is published before any waiter observes it.
         Monitor_Snapshots (Selected).Escalated := False;
         Monitor_States (Selected) := Monitor_Pending;
         Ticket.all := Selected;
         Token.all := Monitor_Tokens (Selected);
         Active.all := True;
         Immediate := False;
      end Register_Monitor;

      procedure Register_Admission_Monitor
        (Admission : Child_Handle;
         Observed  : Child_Handle;
         Signal    : Interfaces.C.int;
         Immediate : out Boolean;
         Status    : out Generation_Observation_Status;
         Snapshot  : out Child_Snapshot;
         Ticket    : not null access Monitor_Index;
         Token     : not null access Monitor_Token;
         Active    : not null access Boolean;
         Valid     : out Boolean)
      is
         Slot     : Slot_Index := Slot_Index'First;
         Selected : Monitor_Index := Monitor_Index'First;
         Found    : Boolean := False;
         Reusable : Boolean := False;
      begin
         Valid := False;
         Immediate := True;
         Status := Observation_Timed_Out;
         Snapshot := Snapshots (Slot_Index'First);
         Ticket.all := Monitor_Index'First;
         Token.all := 0;
         Active.all := False;
         if Controller (Admission) /= Identity
           or else Controller (Observed) /= Identity
           or else Child (Admission) /= Child (Observed)
           or else Child (Admission) < First_Child_Id
           or else Interfaces.Unsigned_64 (Child (Admission)) - Interfaces.Unsigned_64 (First_Child_Id)
                   >= Interfaces.Unsigned_64 (Maximum_Children)
         then
            return;
         end if;
         Slot :=
           Slot_Index
             (Interfaces.Unsigned_64 (Child (Admission)) - Interfaces.Unsigned_64 (First_Child_Id) + 1);
         if Slots (Slot) not in Released_Queued | Released_Managed | Released_Reapable
           or else Current_Generation (Admission) > Snapshots (Slot).Generation
           or else Current_Generation (Observed) < Current_Generation (Admission)
           or else Current_Generation (Observed) > Snapshots (Slot).Generation
           or else Signal < 0
         then
            return;
         end if;
         Snapshot := Snapshots (Slot);
         Valid := True;
         if Current_Generation (Observed) < Snapshots (Slot).Generation then
            Status := Generation_Replaced;
            return;
         elsif Slots (Slot) = Released_Reapable or else Snapshots (Slot).State in Failed_Escalated | Joined
         then
            Status := Generation_Terminated;
            return;
         end if;

         for Candidate in Monitor_Index loop
            if Monitor_Tokens (Candidate) /= Monitor_Token'Last then
               Reusable := True;
            end if;
            if Monitor_States (Candidate) = Monitor_Free
              and then Monitor_Tokens (Candidate) /= Monitor_Token'Last
            then
               Selected := Candidate;
               Found := True;
               exit;
            end if;
         end loop;
         if not Found then
            if Reusable then
               raise Constraint_Error with "supervision family monitor capacity exhausted";
            else
               raise Program_Error with "supervision family monitor identity exhausted";
            end if;
         end if;

         Monitor_Tokens (Selected) := Monitor_Tokens (Selected) + 1;
         Monitor_Handles (Selected) := Observed;
         Monitor_Snapshots (Selected) := Snapshots (Slot);
         Monitor_Snapshots (Selected).Attempts := Interfaces.Unsigned_64 (Signal);
         Monitor_Snapshots (Selected).Escalated := True;
         Monitor_States (Selected) := Monitor_Pending;
         Ticket.all := Selected;
         Token.all := Monitor_Tokens (Selected);
         Active.all := True;
         Immediate := False;
      end Register_Admission_Monitor;

      procedure Claim_Monitor_Signal (Signals : not null access Monitor_Signal_Guard) is
      begin
         if Signals.Claimed then
            raise Program_Error with "admission monitor signal guard is already claimed";
         end if;
         for Ticket in Monitor_Index loop
            if Monitor_States (Ticket)
               in Monitor_Termination_Signal_Pending | Monitor_Replacement_Signal_Pending
            then
               Signals.Ticket := Ticket;
               Signals.Token := Monitor_Tokens (Ticket);
               Signals.Descriptor := Interfaces.C.int (Monitor_Handles (Ticket).Controller);
               Signals.Claimed := True;
               Monitor_States (Ticket) :=
                 (if Monitor_States (Ticket) = Monitor_Termination_Signal_Pending
                  then Monitor_Termination_Signal_Claimed
                  else Monitor_Replacement_Signal_Claimed);
               return;
            end if;
         end loop;
         Signals.Armed := False;
      end Claim_Monitor_Signal;

      procedure Try_Acknowledge_Monitor_Signal
        (Signals : not null access Monitor_Signal_Guard;
         Result  : out Flyology.Wake_Sources.Signal_Attempt_Result)
      is
         Ticket : constant Monitor_Index := Signals.Ticket;
      begin
         if not Signals.Claimed or else Signals.Token /= Monitor_Tokens (Ticket) then
            raise Program_Error with "admission monitor signal claim is stale";
         end if;
         if Flyology.Task_Lifecycle_Test_Hooks.Enabled
           and then Flyology.Task_Lifecycle_Test_Hooks.Consume_Admission_Signal_Interrupted
         then
            Result := Flyology.Wake_Sources.Signal_Interrupted;
            return;
         end if;
         Result := Flyology.Wake_Sources.Try_Signal_Borrowed (Signals.Descriptor);
         if Result /= Flyology.Wake_Sources.Signal_Delivered then
            return;
         end if;
         case Monitor_States (Ticket) is
            when Monitor_Termination_Signal_Claimed =>
               Monitor_States (Ticket) := Monitor_Terminated;

            when Monitor_Replacement_Signal_Claimed =>
               Monitor_States (Ticket) := Monitor_Replaced;

            when others                             =>
               raise Program_Error with "admission monitor signal claim is inconsistent";
         end case;
         Signals.Claimed := False;
      end Try_Acknowledge_Monitor_Signal;

      entry Await_Monitor (for Ticket in Monitor_Index)
        (Token : Monitor_Token; Status : out Generation_Observation_Status; Snapshot : out Child_Snapshot)
        when Monitor_States (Ticket) in Monitor_Terminated | Monitor_Replaced
      is
      begin
         pragma Assert (Token = Monitor_Tokens (Ticket));
         Status :=
           (if Monitor_States (Ticket) = Monitor_Terminated
            then Generation_Terminated
            else Generation_Replaced);
         Snapshot := Monitor_Snapshots (Ticket);
         Monitor_States (Ticket) := Monitor_Free;
      end Await_Monitor;

      procedure Cancel_Monitor
        (Ticket    : Monitor_Index;
         Token     : Monitor_Token;
         Released  : out Boolean;
         Completed : out Boolean;
         Status    : out Generation_Observation_Status;
         Snapshot  : out Child_Snapshot) is
      begin
         if Token /= Monitor_Tokens (Ticket) then
            Released := True;
            Completed := False;
            Status := Observation_Timed_Out;
            Snapshot := Monitor_Snapshots (Ticket);
            return;
         end if;
         Released :=
           Monitor_States (Ticket)
           not in Monitor_Termination_Signal_Pending
                | Monitor_Replacement_Signal_Pending
                | Monitor_Termination_Signal_Claimed
                | Monitor_Replacement_Signal_Claimed;
         Completed := Monitor_States (Ticket) in Monitor_Terminated | Monitor_Replaced;
         Status :=
           (if Monitor_States (Ticket)
               in Monitor_Terminated | Monitor_Termination_Signal_Pending | Monitor_Termination_Signal_Claimed
            then Generation_Terminated
            elsif Monitor_States (Ticket)
                  in Monitor_Replaced
                   | Monitor_Replacement_Signal_Pending
                   | Monitor_Replacement_Signal_Claimed
            then Generation_Replaced
            else Observation_Timed_Out);
         Snapshot := Monitor_Snapshots (Ticket);
         if Released then
            Monitor_States (Ticket) := Monitor_Free;
         end if;
      end Cancel_Monitor;

      procedure Copy_Events
        (Cursor  : in out Event_Sequence;
         Target  : out Supervisor_Event_Array;
         Count   : out Natural;
         Dropped : out Event_Sequence)
      is
         Oldest     : Event_Sequence;
         Desired    : Event_Sequence;
         Event_Slot : Positive;
      begin
         Target := (others => <>);
         Count := 0;
         Dropped := 0;
         if Event_Length = 0 or else Cursor >= Event_Last_Sequence then
            return;
         end if;

         Oldest := Event_Last_Sequence - Event_Sequence (Event_Length) + 1;
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
                (((Event_First - Event_Buffer'First + Offset) mod Event_Capacity) + Event_Buffer'First);
            if Events (Event_Slot).Sequence >= Desired then
               Count := Count + 1;
               Target (Target'First + Count - 1) := Events (Event_Slot);
               Cursor := Events (Event_Slot).Sequence;
            end if;
         end loop;
      end Copy_Events;
   end Family_State;

   overriding
   procedure Finalize (Item : in out Monitor_Guard) is
      Completed : Boolean;
      Released  : Boolean;
      Status    : Generation_Observation_Status;
      Snapshot  : Child_Snapshot;
   begin
      if Item.Active and then Item.State /= null then
         Item.State.Cancel_Monitor (Item.Ticket, Item.Token, Released, Completed, Status, Snapshot);
         if not Released then
            Item.State.Await_Monitor (Item.Ticket) (Item.Token, Status, Snapshot);
         end if;
         Item.Active := False;
      end if;
   exception
      when others =>
         null;
   end Finalize;

   procedure Validate is
   begin
      if Interfaces.Unsigned_64 (Maximum_Children - 1)
        > Interfaces.Unsigned_64'Last - Interfaces.Unsigned_64 (First_Child_Id)
        or else (Policy.Task_Model /= Flyology.Lightweight_Task
                 and then Policy.Task_Model /= Flyology.Native_Task)
        or else Policy.Impact not in Isolate_Child | Escalate
        or else (Policy.Restart /= Never and then not Policy.Restart_Safe)
        or else Policy.Readiness_Timeout < Ada.Real_Time.Time_Span_Zero
        or else Policy.Recovery.Window <= Ada.Real_Time.Time_Span_Zero
        or else Policy.Recovery.Initial_Backoff < Ada.Real_Time.Time_Span_Zero
        or else Policy.Recovery.Maximum_Backoff < Policy.Recovery.Initial_Backoff
        or else Policy.Recovery.Stability_Reset <= Ada.Real_Time.Time_Span_Zero
        or else Policy.Recovery.Recovery_Deadline < Ada.Real_Time.Time_Span_Zero
        or else Policy.Stopping.Grace < Ada.Real_Time.Time_Span_Zero
        or else Policy.Stopping.Abort_Observation < Ada.Real_Time.Time_Span_Zero
        or else Policy.Stopping.Grace > Ada.Real_Time.Time_Span_Last - Policy.Stopping.Abort_Observation
        or else (Policy.Task_Model = Flyology.Native_Task and then Policy.Has_Group)
        or else (Policy.Task_Model = Flyology.Lightweight_Task
                 and then Policy.Has_Group
                 and then Integer (Policy.Group) = Integer (Control_Group))
      then
         raise Configuration_Error with "invalid supervision family policy";
      end if;
   end Validate;

   procedure Start (Item : in out Family; Input : Request; Handle : out Child_Handle) is
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

   procedure Stop (Item : in out Family; Handle : Child_Handle) is
      Valid : Boolean;
   begin
      Item.State.Stop_One (Handle, Valid);
      if not Valid then
         raise Stale_Handle;
      end if;
   end Stop;

   procedure Restart (Item : in out Family; Handle : Child_Handle) is
      Valid : Boolean;
   begin
      if Policy.Restart = Never or else Policy.Impact = Escalate or else not Policy.Restart_Safe then
         raise Program_Error with "manual restart requires a restart-safe replacement policy";
      end if;
      Item.State.Request_Intervention
        (Handle, Diagnostic_Summary (Restart_Requested, "manual restart requested"), Valid);
      if not Valid then
         raise Stale_Handle with "manual restart requires the current running generation";
      end if;
   end Restart;

   procedure Report_Unhealthy (Item : in out Family; Handle : Child_Handle; Diagnostic : String) is
      Summary : constant Termination_Summary := Diagnostic_Summary (Unhealthy, Diagnostic);
      Valid   : Boolean;
   begin
      Item.State.Request_Intervention (Handle, Summary, Valid);
      if not Valid then
         raise Stale_Handle with "health report requires the current running generation";
      end if;
   end Report_Unhealthy;

   procedure Request_Shutdown (Item : in out Family) is
   begin
      Item.State.Request_Stop;
   end Request_Shutdown;

   function Accepting (Item : Family) return Boolean
   is (Item.State.Admission_Is_Open);

   function Current (Item : Family; Handle : Child_Handle) return Child_Snapshot is
      Valid : Boolean;
      Value : constant Child_Snapshot := Item.State.Read_Snapshot (Handle, Valid);
   begin
      if not Valid then
         raise Stale_Handle;
      end if;
      return Value;
   end Current;

   function Current (Item : Family; Child : Child_Id) return Child_Snapshot is
      Valid : Boolean;
      Value : constant Child_Snapshot := Item.State.Read_Logical_Snapshot (Child, Valid);
   begin
      if not Valid then
         raise Stale_Handle;
      end if;
      return Value;
   end Current;

   function Latest (Item : Family; Child : Child_Id) return Child_Handle is
      Valid : Boolean;
      Value : constant Child_Handle := Item.State.Read_Latest (Child, Valid);
   begin
      if not Valid then
         raise Stale_Handle;
      end if;
      return Value;
   end Latest;

   function Wait_Termination
     (Item : in out Family; Handle : Child_Handle; Timeout : Duration := -1.0) return Generation_Observation
   is
      Immediate : Boolean;
      Completed : Boolean := False;
      Released  : Boolean := False;
      Valid     : Boolean;
      Status    : Generation_Observation_Status;
      Snapshot  : Child_Snapshot;
      Guard     : Monitor_Guard;
   begin
      Guard.State := Item.State'Unchecked_Access;
      Item.State.Register_Monitor
        (Handle,
         Immediate,
         Status,
         Snapshot,
         Guard.Ticket'Access,
         Guard.Token'Access,
         Guard.Active'Access,
         Valid);
      if Flyology.Task_Lifecycle_Test_Hooks.Enabled and then Guard.Active then
         Flyology.Task_Lifecycle_Test_Hooks.Barrier
           (Flyology.Task_Lifecycle_Test_Hooks.Family_Monitor_Registered);
      end if;
      if not Valid then
         raise Stale_Handle;
      elsif Immediate then
         return Completed_Observation (Status, Snapshot);
      end if;

      if Timeout < 0.0 then
         Item.State.Await_Monitor (Guard.Ticket) (Guard.Token, Status, Snapshot);
         Guard.Active := False;
         return Completed_Observation (Status, Snapshot);
      elsif Timeout = 0.0 then
         Item.State.Cancel_Monitor (Guard.Ticket, Guard.Token, Released, Completed, Status, Snapshot);
         if not Released then
            Item.State.Await_Monitor (Guard.Ticket) (Guard.Token, Status, Snapshot);
            Completed := True;
         end if;
         Guard.Active := False;
      else
         select
            Item.State.Await_Monitor (Guard.Ticket) (Guard.Token, Status, Snapshot);
            Completed := True;
         or
            delay Timeout;
         end select;
         if not Completed then
            Item.State.Cancel_Monitor (Guard.Ticket, Guard.Token, Released, Completed, Status, Snapshot);
            if not Released then
               Item.State.Await_Monitor (Guard.Ticket) (Guard.Token, Status, Snapshot);
               Completed := True;
            end if;
         end if;
         Guard.Active := False;
      end if;

      if Completed then
         return Completed_Observation (Status, Snapshot);
      else
         return (Status => Observation_Timed_Out);
      end if;
   end Wait_Termination;

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
     (Item        : not null access Family;
      Context     : aliased in out Application_Context;
      Inherited   : Incident_Context;
      Parent_Stop : access Flyology.Cancellation.Token;
      Result      : out Supervisor_Result)
   is
      Identity : Controller_Id;
   begin
      Validate;
      Identity := New_Controller;
      Item.State.Configure (Identity, Inherited);
      declare
         task type Manager with CPU => Control_Group is
            pragma Task_Info (Flyology.Lightweight_Task);
            entry Start (Slot : Slot_Index; Handle : Child_Handle; Incident : Incident_Context);
            entry Finish;
         end Manager;
         type Manager_Access is access Manager;
         type Manager_Array is array (Slot_Index) of Manager_Access;
         procedure Free_Manager is new Ada.Unchecked_Deallocation (Manager, Manager_Access);
         Managers : Manager_Array := (others => null);

         procedure Finish_Managers is
         begin
            for Candidate in Slot_Index loop
               if Managers (Candidate) /= null then
                  begin
                     Managers (Candidate).Finish;
                  exception
                     when Tasking_Error =>
                        null;
                  end;
               end if;
            end loop;
            for Candidate in Slot_Index loop
               if Managers (Candidate) /= null then
                  while not Ada.Task_Identification.Is_Terminated (Managers (Candidate).all'Identity) loop
                     delay 0.001;
                  end loop;
                  Free_Manager (Managers (Candidate));
               end if;
            end loop;
         end Finish_Managers;

         task body Manager is
            Managed_Slot : Slot_Index := Slot_Index'First;
            Value        : Child_Handle :=
              (Controller => Controller_Id'First, Id => First_Child_Id, Generation => Generation'First);
            Input        : Request;

            procedure Run_Generation
              (Current  : Child_Handle;
               Incident : Incident_Context;
               Started  : out Boolean;
               Restart  : out Boolean;
               Backoff  : out Ada.Real_Time.Time_Span;
               Next     : out Child_Handle;
               Recovery : out Incident_Context)
            is
               Control          : aliased Generation_Control;
               Generation_Value : Generation_Result;
               Signals          : aliased Monitor_Signal_Guard (Item);
            begin
               Item.State.Publish_Starting (Managed_Slot, Current, Incident, Signals'Access, Started);
               Flush_Monitor_Signals (Signals);
               Restart := False;
               Backoff := Ada.Real_Time.Time_Span_Zero;
               Next := Current;
               Recovery := Incident;
               if not Started then
                  return;
               end if;
               Open (Control, Current, Incident);
               declare
                  protected type Completion_State is
                     procedure Store (Value : Generation_Result);
                     procedure Read (Done : out Boolean; Value : out Generation_Result);
                  private
                     Finished : Boolean := False;
                     Stored   : Generation_Result;
                  end Completion_State;

                  protected body Completion_State is
                     procedure Store (Value : Generation_Result) is
                     begin
                        if not Finished then
                           Stored := Value;
                           Finished := True;
                        end if;
                     end Store;

                     procedure Read (Done : out Boolean; Value : out Generation_Result) is
                     begin
                        Done := Finished;
                        Value := Stored;
                     end Read;
                  end Completion_State;

                  Completion : aliased Completion_State;
                  task Runner
                    with CPU => Control_Group is
                     pragma Task_Info (Flyology.Lightweight_Task);
                  end Runner;
                  task body Runner is
                     Value : Generation_Result;
                  begin
                     begin
                        Run_One_Generation (Context, Input, Control, Value);
                     exception
                        when Occurrence : Tasking_Error =>
                           Value :=
                             (Termination    => Failure_Summary (Occurrence, Activation_Failure),
                              Reported_Ready => Is_Ready (Control),
                              Incident       => Recovery_Incident (Control));
                        when Occurrence : others =>
                           Value :=
                             (Termination    => Failure_Summary (Occurrence),
                              Reported_Ready => Is_Ready (Control),
                              Incident       => Recovery_Incident (Control));
                     end;
                     Completion.Store (Value);
                  end Runner;

                  Started_At        : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
                  Stop_At           : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
                  Done              : Boolean;
                  Ready             : Boolean := False;
                  Stop_Published    : Boolean := False;
                  Abort_Published   : Boolean := False;
                  Stuck_Published   : Boolean := False;
                  Incident_Closed   : Boolean := not Active (Incident);
                  Stop_Now          : Boolean;
                  Shutdown          : Boolean;
                  Override          : Termination_Summary := Empty_Summary (No_Termination);
                  Decision_Override : Termination_Summary;
                  Now               : Ada.Real_Time.Time;
               begin
                  loop
                     Completion.Read (Done, Generation_Value);
                     Now := Ada.Real_Time.Clock;
                     if not Ready and then Is_Ready (Control) then
                        Ready := True;
                        Item.State.Publish_Ready (Managed_Slot, Current, Now);
                     end if;
                     if not Incident_Closed
                       and then Item.State.Incident_Can_Close (Managed_Slot, Current, Now)
                     then
                        Close_Recovery_Incident (Control);
                        Incident_Closed := True;
                     end if;
                     exit when Done;
                     Item.State.Stop_Status (Managed_Slot, Current, Stop_Now, Shutdown, Decision_Override);
                     if Decision_Override.Kind /= No_Termination then
                        Override := Decision_Override;
                     end if;
                     if not Ready and then Now - Started_At >= Policy.Readiness_Timeout then
                        Stop_Now := True;
                        Shutdown := False;
                        Override := Empty_Summary (Readiness_Timeout);
                     end if;
                     if Stop_Now and then not Stop_Published then
                        Stop_Published := True;
                        Stop_At := Now;
                        Request_Stop (Control, Shutdown);
                     end if;
                     if Stop_Published and then Now - Stop_At >= Policy.Stopping.Grace then
                        if not Shutdown and then Override.Kind = No_Termination then
                           Override := Empty_Summary (Stop_Timeout);
                        end if;
                        if Policy.Stopping.Request_Abort and then not Abort_Published then
                           Abort_Published := True;
                           Request_Abort (Control);
                        end if;
                        if not Stuck_Published
                          and then Now - Stop_At >= Policy.Stopping.Grace + Policy.Stopping.Abort_Observation
                        then
                           Stuck_Published := True;
                           Item.State.Publish_Stuck (Managed_Slot, Current);
                        end if;
                     end if;
                     delay 0.001;
                  end loop;
                  Generation_Value.Incident := Recovery_Incident (Control);
                  if Generation_Value.Termination.Kind = No_Termination then
                     Generation_Value.Termination := Empty_Summary (Abnormal_Completion);
                  elsif Override.Kind /= No_Termination
                    and then Generation_Value.Termination.Kind
                             in Normal_Return | Cancelled | Supervisor_Shutdown | Abnormal_Completion
                  then
                     declare
                        Task_Id : constant Ada.Task_Identification.Task_Id :=
                          Generation_Value.Termination.Task_Id;
                     begin
                        Generation_Value.Termination := Override;
                        Generation_Value.Termination.Task_Id := Task_Id;
                     end;
                  elsif Stop_Published
                    and then Shutdown
                    and then Generation_Value.Termination.Kind in Normal_Return | Cancelled
                  then
                     Generation_Value.Termination.Kind := Supervisor_Shutdown;
                  end if;
               end;
               declare
                  Finished_At : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
                  Cascade     : Incident_Context := Generation_Value.Incident;
                  Deadline    : Ada.Real_Time.Time;
               begin
                  if not Active (Cascade) then
                     if Policy.Recovery.Recovery_Deadline > Ada.Real_Time.Time_Last - Finished_At then
                        Deadline := Ada.Real_Time.Time_Last;
                     else
                        Deadline := Finished_At + Policy.Recovery.Recovery_Deadline;
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
                     Recovery,
                     Signals'Access);
                  Flush_Monitor_Signals (Signals);
               end;
            end Run_Generation;

            Restart        : Boolean;
            Started        : Boolean;
            Backoff        : Ada.Real_Time.Time_Span;
            Next           : Child_Handle;
            Incident       : Incident_Context := No_Incident;
            Recovery       : Incident_Context := No_Incident;
            Start_Incident : Incident_Context := No_Incident;
         begin
            loop
               select
                  accept Start (Slot : Slot_Index; Handle : Child_Handle; Incident : Incident_Context) do
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
                  declare
                     Candidate : Child_Handle := Value;
                  begin
                     loop
                        Run_Generation (Candidate, Incident, Started, Restart, Backoff, Next, Recovery);
                        exit when not Started;
                        Value := Candidate;
                        exit when not Restart;
                        declare
                           Now : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
                           Due : constant Ada.Real_Time.Time :=
                             (if Backoff > Ada.Real_Time.Time_Last - Now
                              then Ada.Real_Time.Time_Last
                              else Now + Backoff);
                        begin
                           while Ada.Real_Time.Clock < Due
                             and then Item.State.Replacement_Wait_Allowed (Managed_Slot)
                           loop
                              delay 0.001;
                           end loop;
                        end;
                        exit when not Item.State.Replacement_Wait_Allowed (Managed_Slot);
                        Incident := Recovery;
                        Candidate := Next;
                     end loop;
                  end;
               exception
                  when Occurrence : others =>
                     declare
                        Signals : aliased Monitor_Signal_Guard (Item);
                     begin
                        Item.State.Manager_Failed
                          (Managed_Slot, Value, Failure_Summary (Occurrence), Signals'Access);
                        Flush_Monitor_Signals (Signals);
                     end;
               end;
               if Flyology.Task_Lifecycle_Test_Hooks.Enabled then
                  Flyology.Task_Lifecycle_Test_Hooks.Barrier
                    (Flyology.Task_Lifecycle_Test_Hooks.Admission_Before_Manager_Done);
               end if;
               declare
                  Signals : aliased Monitor_Signal_Guard (Item);
               begin
                  Item.State.Manager_Done (Managed_Slot, Value, Signals'Access);
                  Flush_Monitor_Signals (Signals);
               end;
            end loop;
         end Manager;

         Available : Boolean;
         Slot      : Slot_Index;
         Handle    : Child_Handle;
         Incident  : Incident_Context;
      begin
         loop
            if Parent_Stop /= null and then Parent_Stop.Requested then
               Item.State.Request_Stop;
            end if;
            Item.State.Take_Start (Available, Slot, Handle, Incident);
            if Available then
               begin
                  if Managers (Slot) = null then
                     Managers (Slot) := new Manager;
                  end if;
                  Managers (Slot).Start (Slot, Handle, Incident);
               exception
                  when others =>
                     declare
                        Signals : aliased Monitor_Signal_Guard (Item);
                     begin
                        Item.State.Manager_Done (Slot, Handle, Signals'Access);
                        Flush_Monitor_Signals (Signals);
                     end;
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
      Run_Internal (Item'Access, Context, No_Incident, null, Result);
   end Run;

   procedure Run_Nested
     (Item    : aliased in out Family;
      Context : aliased in out Application_Context;
      Parent  : aliased in out Generation_Control;
      Result  : out Supervisor_Result)
   is
      Parent_Handle : constant Child_Handle := Handle (Parent);
      Inherited     : constant Incident_Context := Recovery_Incident (Parent);
      Parent_Stop   : constant not null access Flyology.Cancellation.Token := Stopping (Parent);
      pragma Unreferenced (Parent_Handle);
   begin
      Run_Internal (Item'Access, Context, Inherited, Parent_Stop, Result);
      if Active (Result.Incident) and then Result.Outcome /= Shutdown_Completed then
         Report_Escalation (Parent, Result.Incident);
      end if;
   end Run_Nested;

end Flyology.Supervision.Families;
