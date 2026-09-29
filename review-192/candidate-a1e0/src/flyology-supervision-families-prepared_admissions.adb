with Flyology.Operations.Drivers;
with Flyology.Task_Lifecycle_Test_Hooks;
with Interfaces.C;

package body Flyology.Supervision.Families.Prepared_Admissions is
   use type Flyology.Operations.Driver_Event;

   type Immediate_Claim_Guard (Owner : not null access Family) is new Ada.Finalization.Limited_Controlled
   with record
      Ticket : Monitor_Index := Monitor_Index'First;
      Token  : Monitor_Token := 0;
      Active : aliased Boolean := False;
   end record;

   overriding
   procedure Finalize (Item : in out Immediate_Claim_Guard) is
      Resolved : Boolean;
   begin
      if Item.Active then
         Item.Owner.State.Resolve_Prepared_Immediate_Claim
           (Item.Ticket, Item.Token, False, Item.Active'Access, Resolved);
      end if;
   exception
      when others =>
         null;
   end Finalize;

   function Vacant_Start_Claim (Owner : not null access Family) return Start_Claim is
   begin
      return Result : Start_Claim (Owner);
   end Vacant_Start_Claim;

   function Vacant_Started_Admission (Owner : not null access Family) return Started_Admission is
   begin
      return Result : Started_Admission (Owner);
   end Vacant_Started_Admission;

   function Vacant_Observation_Claim (Owner : not null access Family) return Prepared_Observation_Claim is
   begin
      return Result : Prepared_Observation_Claim (Owner);
   end Vacant_Observation_Claim;

   function Is_Active (Item : Start_Claim) return Boolean
   is (Item.State.Active);
   function Is_Active (Item : Started_Admission) return Boolean
   is (Item.State.Active);
   function Is_Active (Item : Prepared_Observation_Claim) return Boolean
   is (Item.State.Active);
   function Is_Released (Item : Started_Admission) return Boolean
   is (Item.State.Released);
   function Admission_Join_Is_Immediate
     (Admission : Started_Admission; Observed : Flyology.Supervision.Generation) return Boolean is
   begin
      return
        Admission.State.Active
        and then Admission.State.Released
        and then Admission.Owner.State.Prepared_Admission_Join_Is_Immediate
                   (Admission.State.Slot, Admission.State.Handle, Observed);
   end Admission_Join_Is_Immediate;
   function First_Handle (Item : Start_Claim) return Child_Handle
   is (Item.State.Handle);
   function First_Handle (Item : Started_Admission) return Child_Handle
   is (Item.State.Handle);

   procedure Prepare_Start
     (Item : not null access Family; Input : Request; Claim : in out Start_Claim; Result : out Prepare_Result)
   is
      Status : Prepared_Reserve_Status;
   begin
      if Claim.Owner /= Item then
         raise Program_Error with "prepared claim belongs to another family";
      elsif Claim.State.Active then
         raise Program_Error with "prepared claim is occupied";
      end if;

      Item.State.Reserve_Prepared
        (Claim.State.Slot'Access, Claim.State.Handle'Access, Claim.State.Active'Access, Status);
      if Flyology.Task_Lifecycle_Test_Hooks.Enabled and then Claim.State.Active then
         Flyology.Task_Lifecycle_Test_Hooks.Barrier
           (Flyology.Task_Lifecycle_Test_Hooks.Prepared_Admission_Reserved);
      end if;
      case Status is
         when Prepared_Admission_Closed     =>
            Result := Start_Admission_Closed;
            return;

         when Prepared_Capacity_Exhausted   =>
            Result := Start_Capacity_Exhausted;
            return;

         when Prepared_Generation_Exhausted =>
            Result := Start_Generation_Exhausted;
            return;

         when Prepared_Reserved             =>
            null;
      end case;

      begin
         Item.Inputs (Claim.State.Slot) := Input;
         Item.State.Publish_Prepared (Claim.State.Slot, Claim.State.Handle);
         if Flyology.Task_Lifecycle_Test_Hooks.Enabled then
            Flyology.Task_Lifecycle_Test_Hooks.Barrier
              (Flyology.Task_Lifecycle_Test_Hooks.Prepared_Admission_Published);
         end if;
      exception
         when others =>
            Item.State.Rollback_Prepared (Claim.State.Slot, Claim.State.Handle, Claim.State.Active'Access);
            raise;
      end;
      Result := Start_Prepared;
   end Prepare_Start;

   procedure Commit_Start
     (Claim : in out Start_Claim; Admission : in out Started_Admission; Result : out Commit_Result)
   is
      Committed : aliased Boolean := False;
   begin
      Commit_Start (Claim, Admission, Committed'Access, Result);
   end Commit_Start;

   procedure Commit_Start
     (Claim     : in out Start_Claim;
      Admission : in out Started_Admission;
      Committed : not null access Boolean;
      Result    : out Commit_Result)
   is
      Status : Prepared_Commit_Status;
   begin
      Committed.all := False;
      if Claim.Owner /= Admission.Owner then
         raise Program_Error with "prepared owners belong to different families";
      elsif not Claim.State.Active then
         raise Program_Error with "prepared claim is vacant";
      elsif Admission.State.Active then
         raise Program_Error with "started admission is occupied";
      end if;
      Claim.Owner.State.Commit_Prepared
        (Claim.State.Slot,
         Claim.State.Handle,
         Claim.State.Active'Access,
         Admission.State.Slot'Access,
         Admission.State.Handle'Access,
         Admission.State.Active'Access,
         Committed,
         Status);
      if Flyology.Task_Lifecycle_Test_Hooks.Enabled and then Admission.State.Active then
         Flyology.Task_Lifecycle_Test_Hooks.Barrier
           (Flyology.Task_Lifecycle_Test_Hooks.Prepared_Admission_Committed);
      end if;
      Result := (if Status = Prepared_Committed then Start_Committed else Start_Admission_Closed);
   end Commit_Start;

   procedure Release_To_Run (Admission : in out Started_Admission; Result : not null access Release_Result) is
      Completed : aliased Boolean := False;
   begin
      Release_To_Run (Admission, Result, Completed'Access);
   end Release_To_Run;

   procedure Reserve_Observation
     (Admission : Started_Admission;
      Claim     : in out Prepared_Observation_Claim;
      Result    : out Observation_Reserve_Result)
   is
      Reserved : aliased Boolean := False;
   begin
      Reserve_Observation (Admission, Claim, Reserved'Access, Result);
   end Reserve_Observation;

   procedure Reserve_Observation
     (Admission : Started_Admission;
      Claim     : in out Prepared_Observation_Claim;
      Reserved  : not null access Boolean;
      Result    : out Observation_Reserve_Result)
   is
      Status : Prepared_Monitor_Reserve_Status;
   begin
      Reserved.all := False;
      if Claim.Owner /= Admission.Owner then
         raise Program_Error with "observation claim belongs to another family";
      elsif Claim.State.Active then
         raise Program_Error with "observation claim is occupied";
      elsif not Admission.State.Active or else Admission.State.Released then
         Result := Observation_Admission_Closed;
         return;
      end if;
      if Flyology.Task_Lifecycle_Test_Hooks.Enabled then
         Flyology.Task_Lifecycle_Test_Hooks.Barrier
           (Flyology.Task_Lifecycle_Test_Hooks.Prepared_Observation_Before_Reserve);
      end if;
      Claim.State.Admission := Admission.State.Handle;
      Claim.Owner.State.Reserve_Prepared_Admission_Monitor
        (Claim.State.Admission,
         Claim.State.Ticket'Access,
         Claim.State.Token'Access,
         Claim.State.Active'Access,
         Reserved,
         Status);
      if Flyology.Task_Lifecycle_Test_Hooks.Enabled and then Reserved.all then
         Flyology.Task_Lifecycle_Test_Hooks.Barrier
           (Flyology.Task_Lifecycle_Test_Hooks.Prepared_Observation_Reserved);
      end if;
      Result :=
        (case Status is
           when Prepared_Monitor_Reserved           => Observation_Reserved,
           when Prepared_Monitor_Admission_Closed   => Observation_Admission_Closed,
           when Prepared_Monitor_Capacity_Exhausted => Observation_Capacity_Exhausted,
           when Prepared_Monitor_Identity_Exhausted => Observation_Identity_Exhausted);
   end Reserve_Observation;

   procedure Release_Observation_Claim (Claim : in out Prepared_Observation_Claim) is
      Released : Boolean;
   begin
      if not Claim.State.Active then
         return;
      end if;
      Claim.Owner.State.Release_Prepared_Monitor
        (Claim.State.Ticket, Claim.State.Token, Claim.State.Active'Access, Released);
      if not Released then
         Claim.Owner.State.Await_Prepared_Monitor_Release (Claim.State.Ticket)
           (Claim.State.Token, Claim.State.Active'Access);
      end if;
   end Release_Observation_Claim;

   procedure Release_To_Run
     (Admission : in out Started_Admission;
      Result    : not null access Release_Result;
      Completed : not null access Boolean) is
   begin
      Completed.all := False;
      if not Admission.State.Active then
         raise Program_Error with "started admission is vacant";
      end if;
      Admission.Owner.State.Release_Prepared
        (Admission.State.Slot,
         Admission.State.Handle,
         Admission.State.Released'Access,
         Result.Succeeded'Access,
         Completed);
      if Flyology.Task_Lifecycle_Test_Hooks.Enabled and then Admission.State.Released then
         Flyology.Task_Lifecycle_Test_Hooks.Barrier
           (Flyology.Task_Lifecycle_Test_Hooks.Prepared_Admission_Released);
      end if;
   end Release_To_Run;

   procedure Rollback (Claim : in out Start_Claim) is
   begin
      if Claim.State.Active then
         Claim.Owner.State.Rollback_Prepared
           (Claim.State.Slot, Claim.State.Handle, Claim.State.Active'Access);
      end if;
   end Rollback;

   procedure Cancel_And_Join (Admission : in out Started_Admission) is
      Completed : Boolean;
      Signals   : aliased Monitor_Signal_Guard (Admission.Owner);
   begin
      if not Admission.State.Active then
         return;
      end if;
      Admission.Owner.State.Begin_Admission_Cancel
        (Admission.State.Slot,
         Admission.State.Handle,
         Admission.State.Active'Access,
         Admission.State.Released'Access,
         Signals'Access,
         Completed);
      Flush_Monitor_Signals (Signals);
      if not Completed then
         Admission.Owner.State.Await_Admission_Cancel (Admission.State.Slot)
           (Admission.State.Handle, Admission.State.Active'Access, Admission.State.Released'Access);
      end if;
   end Cancel_And_Join;

   procedure Request_Cancellation
     (Admission  : Started_Admission;
      Generation : Flyology.Supervision.Generation;
      Applied    : not null access Boolean) is
   begin
      Applied.all := False;
      if not Admission.State.Active or else not Admission.State.Released then
         return;
      end if;
      Admission.Owner.State.Stop_One
        ((Controller => Admission.State.Handle.Controller,
          Id         => Admission.State.Handle.Id,
          Generation => Generation),
         Applied);
      if Flyology.Task_Lifecycle_Test_Hooks.Enabled and then Applied.all then
         Flyology.Task_Lifecycle_Test_Hooks.Barrier
           (Flyology.Task_Lifecycle_Test_Hooks.Prepared_Admission_Cancellation_Requested);
      end if;
   end Request_Cancellation;

   overriding
   procedure Finalize (Item : in out Claim_Owner) is
   begin
      if Item.Active then
         Item.Owner.State.Rollback_Prepared (Item.Slot, Item.Handle, Item.Active'Access);
      end if;
   exception
      when others =>
         null;
   end Finalize;

   overriding
   procedure Finalize (Item : in out Admission_Owner) is
      Completed : Boolean;
      Signals   : aliased Monitor_Signal_Guard (Item.Owner);
   begin
      if Item.Active then
         Item.Owner.State.Begin_Admission_Cancel
           (Item.Slot, Item.Handle, Item.Active'Access, Item.Released'Access, Signals'Access, Completed);
         Flush_Monitor_Signals (Signals);
         if not Completed then
            Item.Owner.State.Await_Admission_Cancel (Item.Slot)
              (Item.Handle, Item.Active'Access, Item.Released'Access);
         end if;
      end if;
   exception
      when others =>
         null;
   end Finalize;

   overriding
   procedure Finalize (Item : in out Observation_Claim_Owner) is
      Released : Boolean;
   begin
      if Item.Active then
         Item.Owner.State.Release_Prepared_Monitor (Item.Ticket, Item.Token, Item.Active'Access, Released);
         if not Released then
            Item.Owner.State.Await_Prepared_Monitor_Release (Item.Ticket) (Item.Token, Item.Active'Access);
         end if;
      end if;
   exception
      when others =>
         null;
   end Finalize;

   function Complete_Observation
     (Status : Generation_Observation_Status; Snapshot : Child_Snapshot) return Generation_Observation is
   begin
      case Status is
         when Generation_Terminated =>
            return (Status => Generation_Terminated, Snapshot => Snapshot);

         when Generation_Replaced   =>
            return (Status => Generation_Replaced, Snapshot => Snapshot);

         when Observation_Timed_Out =>
            return (Status => Observation_Timed_Out);
      end case;
   end Complete_Observation;

   procedure Start_Observation
     (Admission : Started_Admission;
      Observed  : Child_Handle;
      Timeout   : Duration;
      Operation : in out Observation_Operation)
   is
      Immediate                          : Boolean;
      Valid                              : Boolean;
      Read_Descriptor, Signal_Descriptor : Interfaces.C.int;
   begin
      if Operation.Owner /= Admission.Owner then
         raise Program_Error with "observation operation belongs to another family";
      end if;
      Flyology.Operations.Drivers.Start (Operation);
      if not Admission.State.Active or else not Admission.State.Released then
         Operation.Provider.Failure := Invalid_Admission;
         Flyology.Operations.Drivers.Rollback_Start (Operation);
         raise Program_Error with "exact observation requires a released admission";
      end if;
      Operation.Provider.Admission := Admission.State.Handle;
      Operation.Provider.Observed := Observed;
      Operation.Provider.Status := Observation_Timed_Out;
      Operation.Provider.Failure := No_Failure;
      Operation.Provider.Cancellation_Pending := False;
      Operation.Provider.Prepared := False;
      Flyology.Operations.Drivers.Completion_Source (Operation, Read_Descriptor, Signal_Descriptor);
      Operation.Owner.State.Register_Admission_Monitor
        (Operation.Provider.Admission,
         Observed,
         Signal_Descriptor,
         Immediate,
         Operation.Provider.Status,
         Operation.Provider.Snapshot,
         Operation.Provider.Ticket'Access,
         Operation.Provider.Token'Access,
         Operation.Provider.Active'Access,
         Valid);
      if Flyology.Task_Lifecycle_Test_Hooks.Enabled and then Operation.Provider.Active then
         Flyology.Task_Lifecycle_Test_Hooks.Barrier
           (Flyology.Task_Lifecycle_Test_Hooks.Admission_Monitor_Registered);
      end if;
      if not Valid then
         Operation.Provider.Failure := Invalid_Admission;
         Flyology.Operations.Drivers.Rollback_Start (Operation);
         raise Stale_Handle with "exact admission observation is stale";
      elsif Immediate then
         Flyology.Operations.Drivers.Complete (Operation, Flyology.Operations.Succeeded);
      else
         if Timeout = 0.0 then
            declare
               Completed : Boolean;
               Released  : Boolean;
            begin
               Operation.Owner.State.Cancel_Monitor
                 (Operation.Provider.Ticket,
                  Operation.Provider.Token,
                  Released,
                  Completed,
                  Operation.Provider.Status,
                  Operation.Provider.Snapshot);
               Operation.Provider.Active := not Released;
               if Released then
                  Flyology.Operations.Drivers.Complete (Operation, Flyology.Operations.Succeeded);
               else
                  Flyology.Operations.Drivers.Arm_Readiness (Operation, Read_Descriptor, False);
               end if;
            end;
         else
            if Timeout > 0.0 then
               Flyology.Operations.Drivers.Arm_Deadline (Operation, Timeout);
            end if;
            Flyology.Operations.Drivers.Arm_Readiness (Operation, Read_Descriptor, False);
         end if;
      end if;
   exception
      when others =>
         if Operation.Provider.Active then
            declare
               Completed : Boolean;
               Released  : Boolean;
            begin
               Operation.Owner.State.Cancel_Monitor
                 (Operation.Provider.Ticket,
                  Operation.Provider.Token,
                  Released,
                  Completed,
                  Operation.Provider.Status,
                  Operation.Provider.Snapshot);
               if not Released then
                  Operation.Owner.State.Await_Monitor (Operation.Provider.Ticket)
                    (Operation.Provider.Token, Operation.Provider.Status, Operation.Provider.Snapshot);
               end if;
               Operation.Provider.Active := False;
            end;
         end if;
         if Flyology.Operations.Is_Active (Operation) then
            Flyology.Operations.Drivers.Rollback_Start (Operation);
         end if;
         raise;
   end Start_Observation;

   procedure Start_Prepared_Observation
     (Claim     : in out Prepared_Observation_Claim;
      Observed  : Child_Handle;
      Timeout   : Duration;
      Operation : in out Observation_Operation)
   is
      Immediate                          : Boolean;
      Valid                              : Boolean;
      Completed                          : Boolean;
      Released                           : Boolean;
      Immediate_Guard                    : Immediate_Claim_Guard (Claim.Owner);
      Immediate_Resolved                 : Boolean;
      Read_Descriptor, Signal_Descriptor : Interfaces.C.int;
   begin
      if Operation.Owner /= Claim.Owner then
         raise Program_Error with "observation operation belongs to another family";
      elsif not Claim.State.Active then
         raise Program_Error with "prepared observation claim is vacant";
      end if;
      Flyology.Operations.Drivers.Start (Operation);
      Operation.Provider.Admission := Claim.State.Admission;
      Operation.Provider.Observed := Observed;
      Operation.Provider.Ticket := Claim.State.Ticket;
      Operation.Provider.Token := Claim.State.Token;
      Operation.Provider.Active := False;
      Operation.Provider.Prepared := True;
      Operation.Provider.Status := Observation_Timed_Out;
      Operation.Provider.Failure := No_Failure;
      Operation.Provider.Cancellation_Pending := False;
      Immediate_Guard.Ticket := Operation.Provider.Ticket;
      Immediate_Guard.Token := Operation.Provider.Token;
      Flyology.Operations.Drivers.Completion_Source (Operation, Read_Descriptor, Signal_Descriptor);
      Flyology.Operations.Drivers.Arm_Readiness (Operation, Read_Descriptor, False);
      Operation.Owner.State.Activate_Prepared_Admission_Monitor
        (Operation.Provider.Admission,
         Operation.Provider.Ticket,
         Operation.Provider.Token,
         Observed,
         Signal_Descriptor,
         Immediate,
         Operation.Provider.Status,
         Operation.Provider.Snapshot,
         Operation.Provider.Active'Access,
         Immediate_Guard.Active'Access,
         Valid);
      if Flyology.Task_Lifecycle_Test_Hooks.Enabled and then Operation.Provider.Active then
         Flyology.Task_Lifecycle_Test_Hooks.Barrier
           (Flyology.Task_Lifecycle_Test_Hooks.Admission_Monitor_Registered);
      end if;
      if Flyology.Task_Lifecycle_Test_Hooks.Enabled and then Immediate and then Immediate_Guard.Active then
         Flyology.Task_Lifecycle_Test_Hooks.Barrier
           (Flyology.Task_Lifecycle_Test_Hooks.Admission_Immediate_Claimed);
      end if;
      if not Valid then
         Operation.Provider.Failure := Invalid_Admission;
         Flyology.Operations.Drivers.Rollback_Start (Operation);
         raise Stale_Handle with "prepared admission observation is stale";
      elsif Immediate then
         Flyology.Operations.Drivers.Complete (Operation, Flyology.Operations.Succeeded);
         Operation.Owner.State.Resolve_Prepared_Immediate_Claim
           (Operation.Provider.Ticket,
            Operation.Provider.Token,
            True,
            Immediate_Guard.Active'Access,
            Immediate_Resolved);
         if not Immediate_Resolved then
            raise Program_Error with "prepared immediate observation claim is inconsistent";
         end if;
      elsif Timeout = 0.0 then
         Operation.Owner.State.Take_Prepared_Monitor
           (Operation.Provider.Ticket,
            Operation.Provider.Token,
            False,
            Released,
            Completed,
            Operation.Provider.Status,
            Operation.Provider.Snapshot);
         Operation.Provider.Active := not Released;
         if Released then
            Flyology.Operations.Drivers.Complete (Operation, Flyology.Operations.Succeeded);
         end if;
      elsif Timeout > 0.0 then
         Flyology.Operations.Drivers.Arm_Deadline (Operation, Timeout);
      end if;
   exception
      when others =>
         if Operation.Provider.Active then
            Operation.Owner.State.Take_Prepared_Monitor
              (Operation.Provider.Ticket,
               Operation.Provider.Token,
               True,
               Released,
               Completed,
               Operation.Provider.Status,
               Operation.Provider.Snapshot);
            if not Released then
               Operation.Owner.State.Await_Prepared_Monitor (Operation.Provider.Ticket)
                 (Operation.Provider.Token, True, Operation.Provider.Status, Operation.Provider.Snapshot);
            end if;
            Operation.Provider.Active := False;
         end if;
         if Flyology.Operations.Is_Active (Operation) then
            Flyology.Operations.Drivers.Rollback_Start (Operation);
         end if;
         raise;
   end Start_Prepared_Observation;

   function Observe_Exact
     (Set       : not null access Flyology.Operations.Completion_Set'Class;
      Owner     : not null access Family;
      Admission : Started_Admission;
      Observed  : Child_Handle;
      Timeout   : Duration := -1.0) return Observation_Operation is
   begin
      if Owner /= Admission.Owner then
         raise Program_Error with "observation owner does not match admission";
      end if;
      return Result : Observation_Operation (Set, Owner) do
         Start_Observation (Admission, Observed, Timeout, Result);
      end return;
   end Observe_Exact;

   procedure Observe_Exact
     (Admission : Started_Admission;
      Observed  : Child_Handle;
      Timeout   : Duration := -1.0;
      Operation : in out Observation_Operation) is
   begin
      Start_Observation (Admission, Observed, Timeout, Operation);
   end Observe_Exact;

   procedure Activate_Exact
     (Claim     : in out Prepared_Observation_Claim;
      Observed  : Child_Handle;
      Timeout   : Duration := -1.0;
      Operation : in out Observation_Operation) is
   begin
      Start_Prepared_Observation (Claim, Observed, Timeout, Operation);
   end Activate_Exact;

   procedure Activate_Exact
     (Claim     : in out Prepared_Observation_Claim;
      Observed  : Flyology.Supervision.Generation;
      Timeout   : Duration := -1.0;
      Operation : in out Observation_Operation) is
   begin
      Start_Prepared_Observation
        (Claim,
         (Controller => Claim.State.Admission.Controller,
          Id         => Claim.State.Admission.Id,
          Generation => Observed),
         Timeout,
         Operation);
   end Activate_Exact;

   procedure Drive_Prepared_Observation
     (Item : in out Observation_Operation; Event : Flyology.Operations.Driver_Event)
   is
      Completed                          : Boolean;
      Released                           : Boolean := True;
      Immediate                          : Boolean;
      Immediate_Guard                    : Immediate_Claim_Guard (Item.Owner);
      Immediate_Resolved                 : Boolean;
      Valid                              : Boolean;
      Read_Descriptor, Signal_Descriptor : Interfaces.C.int;
   begin
      case Event is
         when Flyology.Operations.Source_Ready | Flyology.Operations.Deadline_Reached =>
            Item.Owner.State.Take_Prepared_Monitor
              (Item.Provider.Ticket,
               Item.Provider.Token,
               Item.Provider.Cancellation_Pending,
               Released,
               Completed,
               Item.Provider.Status,
               Item.Provider.Snapshot);
            Item.Provider.Active := not Released;
            if not Released then
               Flyology.Operations.Drivers.Clear_Deadline (Item);
               Flyology.Operations.Drivers.Completion_Source (Item, Read_Descriptor, Signal_Descriptor);
               Flyology.Operations.Drivers.Arm_Readiness (Item, Read_Descriptor, False);
            elsif Item.Provider.Cancellation_Pending then
               Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Cancelled);
            elsif Item.Provider.Failure /= No_Failure then
               Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
            elsif Completed or else Event = Flyology.Operations.Deadline_Reached then
               Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Succeeded);
            else
               Flyology.Operations.Drivers.Completion_Source (Item, Read_Descriptor, Signal_Descriptor);
               Flyology.Operations.Drivers.Arm_Readiness (Item, Read_Descriptor, False);
               Immediate_Guard.Ticket := Item.Provider.Ticket;
               Immediate_Guard.Token := Item.Provider.Token;
               Item.Owner.State.Activate_Prepared_Admission_Monitor
                 (Item.Provider.Admission,
                  Item.Provider.Ticket,
                  Item.Provider.Token,
                  Item.Provider.Observed,
                  Signal_Descriptor,
                  Immediate,
                  Item.Provider.Status,
                  Item.Provider.Snapshot,
                  Item.Provider.Active'Access,
                  Immediate_Guard.Active'Access,
                  Valid);
               if Flyology.Task_Lifecycle_Test_Hooks.Enabled
                 and then Immediate
                 and then Immediate_Guard.Active
               then
                  Flyology.Task_Lifecycle_Test_Hooks.Barrier
                    (Flyology.Task_Lifecycle_Test_Hooks.Admission_Immediate_Claimed);
               end if;
               if not Valid then
                  Item.Provider.Failure := Invalid_Admission;
                  Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
               elsif Immediate then
                  Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Succeeded);
                  Item.Owner.State.Resolve_Prepared_Immediate_Claim
                    (Item.Provider.Ticket,
                     Item.Provider.Token,
                     True,
                     Immediate_Guard.Active'Access,
                     Immediate_Resolved);
                  if not Immediate_Resolved then
                     raise Program_Error with "prepared immediate observation claim is inconsistent";
                  end if;
               end if;
            end if;

         when others                                                                  =>
            if Item.Provider.Active then
               Item.Owner.State.Take_Prepared_Monitor
                 (Item.Provider.Ticket,
                  Item.Provider.Token,
                  True,
                  Released,
                  Completed,
                  Item.Provider.Status,
                  Item.Provider.Snapshot);
               Item.Provider.Active := not Released;
            end if;
            Item.Provider.Failure := Monitor_Failure;
            if Released then
               Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
            else
               Flyology.Operations.Drivers.Clear_Deadline (Item);
               Flyology.Operations.Drivers.Completion_Source (Item, Read_Descriptor, Signal_Descriptor);
               Flyology.Operations.Drivers.Arm_Readiness (Item, Read_Descriptor, False);
            end if;
      end case;
   exception
      when others =>
         if Item.Provider.Active then
            begin
               Item.Owner.State.Take_Prepared_Monitor
                 (Item.Provider.Ticket,
                  Item.Provider.Token,
                  True,
                  Released,
                  Completed,
                  Item.Provider.Status,
                  Item.Provider.Snapshot);
               Item.Provider.Active := not Released;
            exception
               when others =>
                  null;
            end;
         end if;
         Item.Provider.Failure := Monitor_Failure;
         if not Item.Provider.Active then
            Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
         end if;
   end Drive_Prepared_Observation;

   overriding
   procedure Drive (Item : in out Observation_Operation; Event : Flyology.Operations.Driver_Event) is
      Completed                          : Boolean;
      Released                           : Boolean := True;
      Immediate                          : Boolean;
      Valid                              : Boolean;
      Read_Descriptor, Signal_Descriptor : Interfaces.C.int;
   begin
      if Item.Provider.Prepared then
         Drive_Prepared_Observation (Item, Event);
         return;
      end if;
      case Event is
         when Flyology.Operations.Source_Ready | Flyology.Operations.Deadline_Reached =>
            Item.Owner.State.Cancel_Monitor
              (Item.Provider.Ticket,
               Item.Provider.Token,
               Released,
               Completed,
               Item.Provider.Status,
               Item.Provider.Snapshot);
            Item.Provider.Active := not Released;
            if not Released then
               Flyology.Operations.Drivers.Clear_Deadline (Item);
               Flyology.Operations.Drivers.Completion_Source (Item, Read_Descriptor, Signal_Descriptor);
               Flyology.Operations.Drivers.Arm_Readiness (Item, Read_Descriptor, False);
            elsif Item.Provider.Cancellation_Pending then
               Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Cancelled);
            elsif Item.Provider.Failure /= No_Failure then
               Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
            elsif Completed or else Event = Flyology.Operations.Deadline_Reached then
               Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Succeeded);
            else
               Flyology.Operations.Drivers.Completion_Source (Item, Read_Descriptor, Signal_Descriptor);
               Item.Owner.State.Register_Admission_Monitor
                 (Item.Provider.Admission,
                  Item.Provider.Observed,
                  Signal_Descriptor,
                  Immediate,
                  Item.Provider.Status,
                  Item.Provider.Snapshot,
                  Item.Provider.Ticket'Access,
                  Item.Provider.Token'Access,
                  Item.Provider.Active'Access,
                  Valid);
               if Flyology.Task_Lifecycle_Test_Hooks.Enabled and then Item.Provider.Active then
                  Flyology.Task_Lifecycle_Test_Hooks.Barrier
                    (Flyology.Task_Lifecycle_Test_Hooks.Admission_Monitor_Registered);
               end if;
               if not Valid then
                  Item.Provider.Failure := Invalid_Admission;
                  Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
               elsif Immediate then
                  Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Succeeded);
               else
                  Flyology.Operations.Drivers.Arm_Readiness (Item, Read_Descriptor, False);
               end if;
            end if;

         when others                                                                  =>
            if Item.Provider.Active then
               Item.Owner.State.Cancel_Monitor
                 (Item.Provider.Ticket,
                  Item.Provider.Token,
                  Released,
                  Completed,
                  Item.Provider.Status,
                  Item.Provider.Snapshot);
               Item.Provider.Active := not Released;
            end if;
            Item.Provider.Failure := Monitor_Failure;
            if Released then
               Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
            else
               Flyology.Operations.Drivers.Clear_Deadline (Item);
               Flyology.Operations.Drivers.Completion_Source (Item, Read_Descriptor, Signal_Descriptor);
               Flyology.Operations.Drivers.Arm_Readiness (Item, Read_Descriptor, False);
            end if;
      end case;
   exception
      when others =>
         if Item.Provider.Active then
            begin
               Item.Owner.State.Cancel_Monitor
                 (Item.Provider.Ticket,
                  Item.Provider.Token,
                  Released,
                  Completed,
                  Item.Provider.Status,
                  Item.Provider.Snapshot);
               Item.Provider.Active := not Released;
            exception
               when others =>
                  null;
            end;
         end if;
         Item.Provider.Failure := Monitor_Failure;
         if not Item.Provider.Active then
            Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
         end if;
   end Drive;

   overriding
   procedure Request_Cancellation (Item : in out Observation_Operation) is
      Completed : Boolean;
      Released  : Boolean;
   begin
      if Item.Provider.Prepared then
         if Item.Provider.Active then
            Item.Owner.State.Take_Prepared_Monitor
              (Item.Provider.Ticket,
               Item.Provider.Token,
               True,
               Released,
               Completed,
               Item.Provider.Status,
               Item.Provider.Snapshot);
            Item.Provider.Active := not Released;
         end if;
         if Item.Provider.Active then
            Item.Provider.Cancellation_Pending := True;
            Flyology.Operations.Drivers.Clear_Deadline (Item);
         else
            Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Cancelled);
         end if;
         return;
      end if;
      if Item.Provider.Active then
         Item.Owner.State.Cancel_Monitor
           (Item.Provider.Ticket,
            Item.Provider.Token,
            Released,
            Completed,
            Item.Provider.Status,
            Item.Provider.Snapshot);
         Item.Provider.Active := not Released;
      end if;
      if Item.Provider.Active then
         Item.Provider.Cancellation_Pending := True;
         Flyology.Operations.Drivers.Clear_Deadline (Item);
      else
         Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Cancelled);
      end if;
   end Request_Cancellation;

   procedure Finish (Operation : in out Observation_Operation; Observation : out Generation_Observation) is
      Outcome  : constant Flyology.Operations.Terminal_Outcome := Flyology.Operations.Outcome (Operation);
      Status   : constant Generation_Observation_Status := Operation.Provider.Status;
      Snapshot : constant Child_Snapshot := Operation.Provider.Snapshot;
      Failure  : constant Observation_Failure := Operation.Provider.Failure;
   begin
      Flyology.Operations.Consume (Operation);
      case Outcome is
         when Flyology.Operations.Succeeded =>
            Observation := Complete_Observation (Status, Snapshot);

         when Flyology.Operations.Cancelled =>
            raise Operation_Cancelled;

         when Flyology.Operations.Failed    =>
            raise Program_Error with "exact admission observation failed: " & Failure'Image;
      end case;
   end Finish;

begin
   if not Request_Assignment_And_Cleanup_Are_Nonraising then
      raise Program_Error with "prepared admission request assignment contract is false";
   end if;
end Flyology.Supervision.Families.Prepared_Admissions;
