with Ada.Real_Time;
with Flyology;
with Flyology.Cancellation;
with Flyology.Operations;
with Flyology.Supervision;
with Flyology.Supervision.Children;
with Flyology.Supervision.Families;
with Flyology.Supervision.Families.Prepared_Admissions;
with Flyology.Task_Lifecycle_Testing;

procedure Prepared_Admission_Abort_Smoke is
   use Flyology;
   use Flyology.Supervision;
   use type Ada.Real_Time.Time;
   use type Flyology.Supervision.Generation;
   use type Flyology.Supervision.Generation_Observation_Status;

   type Request is new Positive;

   type Context is limited null record;

   procedure Execute (State : in out Context; Control : not null access Generation_Control) is
      pragma Unreferenced (State);
   begin
      Mark_Ready (Control.all);
      loop
         if Stop_Requested (Control.all) then
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
         delay 0.001;
      end loop;
   end Execute;

   package Generation is new
     Flyology.Supervision.Children
       (Application_Context => Context,
        Execute             => Execute,
        Task_Model          => Native_Task);

   procedure Run_Generation
     (State   : aliased in out Context;
      Input   : Request;
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result)
   is
      pragma Unreferenced (Input);
   begin
      Generation.Run (State, Control, Result);
   end Run_Generation;

   Policy : constant Child_Specification :=
     (Restart           => Never,
      Impact            => Isolate_Child,
      Recovery          => Default_Recovery_Limits,
      Stopping          => Default_Stop_Policy,
      Readiness_Timeout => Ada.Real_Time.Seconds (1),
      Restart_Safe      => True,
      Task_Model        => Native_Task,
      Has_Group         => False,
      Group             => 0);

   package Families is new
     Flyology.Supervision.Families
       (Request             => Request,
        Application_Context => Context,
        Run_One_Generation  => Run_Generation,
        Policy              => Policy,
        First_Child_Id      => 42_000_000_000,
        Maximum_Children    => 1,
        Event_Capacity      => 8,
        Monitor_Capacity    => 1);

   package Prepared is new
     Families.Prepared_Admissions (Request_Assignment_And_Cleanup_Are_Nonraising => True);

   use type Prepared.Commit_Result;
   use type Prepared.Prepare_Result;
   use type Prepared.Release_Result;

   State        : aliased Context;
   Item         : aliased Families.Family;
   Result       : Supervisor_Result;
   Abort_State  : aliased Context;
   Abort_Item   : aliased Families.Family;
   Abort_Result : Supervisor_Result;

   task Owner is
      entry Start;
      entry Join;
   end Owner;

   task body Owner is
   begin
      accept Start;
      Families.Run (Item, State, Result);
      accept Join;
   end Owner;

   task Abort_Owner is
      entry Start;
      entry Join;
   end Abort_Owner;

   task body Abort_Owner is
   begin
      accept Start;
      Families.Run (Abort_Item, Abort_State, Abort_Result);
      accept Join;
   end Abort_Owner;

   type Abort_Stage is (After_Reserve, After_Publish, After_Commit, After_Release);

   function Point_For (Stage : Abort_Stage) return Flyology.Task_Lifecycle_Testing.Barrier_Point
   is (case Stage is
         when After_Reserve => Flyology.Task_Lifecycle_Testing.Prepared_Admission_Reserved,
         when After_Publish => Flyology.Task_Lifecycle_Testing.Prepared_Admission_Published,
         when After_Commit  => Flyology.Task_Lifecycle_Testing.Prepared_Admission_Committed,
         when After_Release => Flyology.Task_Lifecycle_Testing.Prepared_Admission_Released);

   procedure Assert_Reusable is
      Claim    : Prepared.Start_Claim := Prepared.Vacant_Start_Claim (Item'Access);
      P_Result : Prepared.Prepare_Result;
   begin
      Prepared.Prepare_Start (Item'Access, 1, Claim, P_Result);
      if P_Result /= Prepared.Start_Prepared then
         raise Program_Error with "aborted prepared ownership did not restore capacity";
      end if;
      Prepared.Rollback (Claim);
   end Assert_Reusable;

   procedure Exercise_Commit_Evidence_Failures is
      Claim     : Prepared.Start_Claim := Prepared.Vacant_Start_Claim (Item'Access);
      Admission : Prepared.Started_Admission := Prepared.Vacant_Started_Admission (Item'Access);
      P_Result  : Prepared.Prepare_Result;
      C_Result  : Prepared.Commit_Result;
      Committed : aliased Boolean := True;
      Rejected  : Boolean := False;
   begin
      begin
         Prepared.Commit_Start (Claim, Admission, Committed'Access, C_Result);
      exception
         when Program_Error =>
            Rejected := True;
      end;
      if not Rejected
        or else Committed
        or else Prepared.Is_Active (Claim)
        or else Prepared.Is_Active (Admission)
      then
         raise Program_Error with "invalid commit published ownership evidence";
      end if;

      Prepared.Prepare_Start (Item'Access, 1, Claim, P_Result);
      if P_Result /= Prepared.Start_Prepared then
         raise Program_Error with "closed commit evidence setup did not prepare";
      end if;
      Families.Request_Shutdown (Item);
      Committed := True;
      Prepared.Commit_Start (Claim, Admission, Committed'Access, C_Result);
      if C_Result /= Prepared.Start_Admission_Closed
        or else Committed
        or else not Prepared.Is_Active (Claim)
        or else Prepared.Is_Active (Admission)
      then
         raise Program_Error with "closed commit published ownership evidence";
      end if;
      Prepared.Rollback (Claim);
   end Exercise_Commit_Evidence_Failures;

   procedure Exercise_Abort (Stage : Abort_Stage) is
      Point             : constant Flyology.Task_Lifecycle_Testing.Barrier_Point := Point_For (Stage);
      Release_Result    : aliased Prepared.Release_Result := Prepared.Admission_Cancelled;
      Release_Completed : aliased Boolean := False;
      Commit_Completed  : aliased Boolean := False;

      task Worker is
         entry Start;
      end Worker;

      task body Worker is
         Claim     : Prepared.Start_Claim := Prepared.Vacant_Start_Claim (Item'Access);
         Admission : Prepared.Started_Admission := Prepared.Vacant_Started_Admission (Item'Access);
         P_Result  : Prepared.Prepare_Result;
         C_Result  : Prepared.Commit_Result;
      begin
         accept Start;
         Prepared.Prepare_Start (Item'Access, 1, Claim, P_Result);
         if Stage in After_Commit | After_Release then
            Prepared.Commit_Start (Claim, Admission, Commit_Completed'Access, C_Result);
         end if;
         if Stage = After_Release then
            Prepared.Release_To_Run (Admission, Release_Result'Access, Release_Completed'Access);
         end if;
      end Worker;
   begin
      Flyology.Task_Lifecycle_Testing.Reset;
      Flyology.Task_Lifecycle_Testing.Arm (Point);
      Worker.Start;
      begin
         Flyology.Task_Lifecycle_Testing.Wait_Reached (Point);
      exception
         when others =>
            abort Worker;
            Flyology.Task_Lifecycle_Testing.Reset;
            raise Program_Error with "prepared abort stage was not reached: " & Abort_Stage'Image (Stage);
      end;
      abort Worker;
      Flyology.Task_Lifecycle_Testing.Release (Point);
      while not Worker'Terminated loop
         delay 0.001;
      end loop;
      if Stage = After_Release
        and then (Release_Result /= Prepared.Admission_Released or else not Release_Completed)
      then
         raise Program_Error with "aborted post-cut release lost its completed publication";
      elsif Stage in After_Commit | After_Release and then not Commit_Completed then
         raise Program_Error with "aborted post-cut commit lost its completed publication";
      end if;
      Flyology.Task_Lifecycle_Testing.Reset;
      Assert_Reusable;
   end Exercise_Abort;

   procedure Exercise_Producer_Abort is
      Claim       : Prepared.Start_Claim := Prepared.Vacant_Start_Claim (Abort_Item'Access);
      Admission   : Prepared.Started_Admission := Prepared.Vacant_Started_Admission (Abort_Item'Access);
      P_Result    : Prepared.Prepare_Result;
      C_Result    : Prepared.Commit_Result;
      R_Result    : aliased Prepared.Release_Result := Prepared.Admission_Cancelled;
      Set         : aliased Flyology.Operations.Completion_Set (1);
      Observation : Generation_Observation;

      task Canceller is
         entry Start;
      end Canceller;

      task body Canceller is
      begin
         accept Start;
         Prepared.Cancel_And_Join (Admission);
      end Canceller;
   begin
      Prepared.Prepare_Start (Abort_Item'Access, 1, Claim, P_Result);
      Prepared.Commit_Start (Claim, Admission, C_Result);
      Prepared.Release_To_Run (Admission, R_Result'Access);
      if P_Result /= Prepared.Start_Prepared
        or else C_Result /= Prepared.Start_Committed
        or else R_Result /= Prepared.Admission_Released
      then
         raise Program_Error with "producer-abort admission setup failed";
      end if;
      declare
         Wait : Prepared.Observation_Operation :=
           Prepared.Observe_Exact
             (Set'Access, Abort_Item'Access, Admission, Prepared.First_Handle (Admission), Timeout => -1.0);
      begin
         Flyology.Task_Lifecycle_Testing.Reset;
         Flyology.Task_Lifecycle_Testing.Arm (Flyology.Task_Lifecycle_Testing.Admission_Signal_Claimed);
         Flyology.Task_Lifecycle_Testing.Arm (Flyology.Task_Lifecycle_Testing.Admission_Signal_Finalizing);
         Canceller.Start;
         Flyology.Task_Lifecycle_Testing.Wait_Reached
           (Flyology.Task_Lifecycle_Testing.Admission_Signal_Claimed);
         abort Abort_Owner;
         Flyology.Task_Lifecycle_Testing.Wait_Reached
           (Flyology.Task_Lifecycle_Testing.Admission_Signal_Finalizing);
         Flyology.Task_Lifecycle_Testing.Release
           (Flyology.Task_Lifecycle_Testing.Admission_Signal_Finalizing);
         Flyology.Operations.Wait_All (Set);
         Prepared.Finish (Wait, Observation);
         if Observation.Status /= Generation_Terminated then
            raise Program_Error with "producer abort lost the claimed terminal fact";
         end if;
      end;
      while not Abort_Owner'Terminated loop
         delay 0.001;
      end loop;
      while not Canceller'Terminated loop
         delay 0.001;
      end loop;
      if Prepared.Is_Active (Admission) then
         raise Program_Error with "producer abort did not retire its exact admission";
      end if;
      Flyology.Task_Lifecycle_Testing.Release (Flyology.Task_Lifecycle_Testing.Admission_Signal_Claimed);
      Flyology.Task_Lifecycle_Testing.Reset;
   exception
      when others =>
         Flyology.Task_Lifecycle_Testing.Release (Flyology.Task_Lifecycle_Testing.Admission_Signal_Claimed);
         Flyology.Task_Lifecycle_Testing.Release
           (Flyology.Task_Lifecycle_Testing.Admission_Signal_Finalizing);
         abort Abort_Owner;
         abort Canceller;
         Flyology.Task_Lifecycle_Testing.Reset;
         raise;
   end Exercise_Producer_Abort;

   procedure Exercise_Snapshot_Integrity is
      Claim     : Prepared.Start_Claim := Prepared.Vacant_Start_Claim (Item'Access);
      Reuse     : Prepared.Start_Claim := Prepared.Vacant_Start_Claim (Item'Access);
      Admission : Prepared.Started_Admission := Prepared.Vacant_Started_Admission (Item'Access);
      P_Result  : Prepared.Prepare_Result;
      C_Result  : Prepared.Commit_Result;
      R_Result  : aliased Prepared.Release_Result := Prepared.Admission_Cancelled;
      Handle    : Child_Handle;
      Snapshot  : Generation_Observation;
   begin
      Prepared.Prepare_Start (Item'Access, 1, Claim, P_Result);
      Prepared.Commit_Start (Claim, Admission, C_Result);
      Prepared.Release_To_Run (Admission, R_Result'Access);
      if P_Result /= Prepared.Start_Prepared
        or else C_Result /= Prepared.Start_Committed
        or else R_Result /= Prepared.Admission_Released
      then
         raise Program_Error with "snapshot-integrity admission setup failed";
      end if;
      Handle := Prepared.First_Handle (Admission);
      loop
         exit when Families.Current (Item, Handle).Live;
         delay 0.001;
      end loop;

      Flyology.Task_Lifecycle_Testing.Reset;
      Flyology.Task_Lifecycle_Testing.Arm (Flyology.Task_Lifecycle_Testing.Admission_Before_Manager_Done);
      declare
         First_Set  : aliased Flyology.Operations.Completion_Set (1);
         First_Wait : Prepared.Observation_Operation :=
           Prepared.Observe_Exact (First_Set'Access, Item'Access, Admission, Handle, Timeout => -1.0);
      begin
         Families.Stop (Item, Handle);
         Flyology.Operations.Wait_All (First_Set);
         Prepared.Finish (First_Wait, Snapshot);
      end;
      Flyology.Task_Lifecycle_Testing.Wait_Reached
        (Flyology.Task_Lifecycle_Testing.Admission_Before_Manager_Done);

      Flyology.Task_Lifecycle_Testing.Arm (Flyology.Task_Lifecycle_Testing.Admission_Signal_Claimed);
      declare
         Old_Set  : aliased Flyology.Operations.Completion_Set (1);
         Old_Wait : Prepared.Observation_Operation :=
           Prepared.Observe_Exact (Old_Set'Access, Item'Access, Admission, Handle, Timeout => -1.0);
      begin
         Flyology.Task_Lifecycle_Testing.Release
           (Flyology.Task_Lifecycle_Testing.Admission_Before_Manager_Done);
         Flyology.Task_Lifecycle_Testing.Wait_Reached
           (Flyology.Task_Lifecycle_Testing.Admission_Signal_Claimed);
         Prepared.Cancel_And_Join (Admission);
         Prepared.Prepare_Start (Item'Access, 2, Reuse, P_Result);
         if P_Result /= Prepared.Start_Prepared then
            raise Program_Error with "old signal claim did not permit exact slot reuse";
         end if;
         Flyology.Task_Lifecycle_Testing.Release (Flyology.Task_Lifecycle_Testing.Admission_Signal_Claimed);
         Flyology.Operations.Wait_All (Old_Set);
         Prepared.Finish (Old_Wait, Snapshot);
         if Snapshot.Status /= Generation_Terminated
           or else Snapshot.Snapshot.Generation /= Current_Generation (Handle)
           or else Snapshot.Snapshot.State /= Joined
         then
            raise Program_Error with "slot reuse changed the claimed terminal snapshot";
         end if;
      end;
      Prepared.Rollback (Reuse);

      Prepared.Prepare_Start (Item'Access, 3, Reuse, P_Result);
      Prepared.Commit_Start (Reuse, Admission, C_Result);
      R_Result := Prepared.Admission_Cancelled;
      Prepared.Release_To_Run (Admission, R_Result'Access);
      if P_Result /= Prepared.Start_Prepared
        or else C_Result /= Prepared.Start_Committed
        or else R_Result /= Prepared.Admission_Released
      then
         raise Program_Error with "stale-observation admission setup failed";
      end if;
      declare
         Stale_Set : aliased Flyology.Operations.Completion_Set (1);
         Stale     : Prepared.Observation_Operation (Stale_Set'Access, Item'Access);
         Rejected  : Boolean := False;
      begin
         begin
            Prepared.Observe_Exact (Admission, Handle, Timeout => 0.0, Operation => Stale);
         exception
            when Families.Stale_Handle =>
               Rejected := True;
         end;
         if not Rejected then
            raise Program_Error with "prior admission generation was accepted as exact";
         end if;
      end;
      declare
         Foreign_Set : aliased Flyology.Operations.Completion_Set (1);
         Foreign     : Prepared.Observation_Operation (Foreign_Set'Access, Abort_Item'Access);
         Rejected    : Boolean := False;
      begin
         begin
            Prepared.Observe_Exact
              (Admission, Prepared.First_Handle (Admission), Timeout => 0.0, Operation => Foreign);
         exception
            when Program_Error =>
               Rejected := True;
         end;
         if not Rejected then
            raise Program_Error with "foreign observation owner was accepted";
         end if;
      end;
      Prepared.Cancel_And_Join (Admission);
      Flyology.Task_Lifecycle_Testing.Reset;
   exception
      when others =>
         Flyology.Task_Lifecycle_Testing.Release
           (Flyology.Task_Lifecycle_Testing.Admission_Before_Manager_Done);
         Flyology.Task_Lifecycle_Testing.Release (Flyology.Task_Lifecycle_Testing.Admission_Signal_Claimed);
         if Prepared.Is_Active (Admission) then
            Prepared.Cancel_And_Join (Admission);
         end if;
         Prepared.Rollback (Reuse);
         Flyology.Task_Lifecycle_Testing.Reset;
         raise;
   end Exercise_Snapshot_Integrity;

   Deadline : constant Ada.Real_Time.Time := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
begin
   Owner.Start;
   Abort_Owner.Start;
   loop
      exit when Families.Accepting (Item) and then Families.Accepting (Abort_Item);
      if Ada.Real_Time.Clock >= Deadline then
         raise Program_Error with "abort-test family did not open";
      end if;
      delay 0.001;
   end loop;

   for Stage in Abort_Stage loop
      Exercise_Abort (Stage);
   end loop;

   declare
      Claim     : Prepared.Start_Claim := Prepared.Vacant_Start_Claim (Item'Access);
      Admission : Prepared.Started_Admission := Prepared.Vacant_Started_Admission (Item'Access);
      P_Result  : Prepared.Prepare_Result;
      C_Result  : Prepared.Commit_Result;
      R_Result  : aliased Prepared.Release_Result := Prepared.Admission_Cancelled;
   begin
      Prepared.Prepare_Start (Item'Access, 1, Claim, P_Result);
      Prepared.Commit_Start (Claim, Admission, C_Result);
      Prepared.Release_To_Run (Admission, R_Result'Access);
      if P_Result /= Prepared.Start_Prepared
        or else C_Result /= Prepared.Start_Committed
        or else R_Result /= Prepared.Admission_Released
      then
         raise Program_Error with "monitor-abort admission setup failed";
      end if;

      Flyology.Task_Lifecycle_Testing.Reset;
      Flyology.Task_Lifecycle_Testing.Arm (Flyology.Task_Lifecycle_Testing.Admission_Monitor_Registered);
      declare
         task Observer is
            entry Start;
         end Observer;

         task body Observer is
         begin
            accept Start;
            declare
               Set  : aliased Flyology.Operations.Completion_Set (1);
               Wait : Prepared.Observation_Operation :=
                 Prepared.Observe_Exact
                   (Set'Access, Item'Access, Admission, Prepared.First_Handle (Admission), Timeout => -1.0);
               pragma Unreferenced (Wait);
            begin
               Flyology.Operations.Wait_All (Set);
            end;
         end Observer;
      begin
         Observer.Start;
         Flyology.Task_Lifecycle_Testing.Wait_Reached
           (Flyology.Task_Lifecycle_Testing.Admission_Monitor_Registered);
         abort Observer;
         Flyology.Task_Lifecycle_Testing.Release
           (Flyology.Task_Lifecycle_Testing.Admission_Monitor_Registered);
         while not Observer'Terminated loop
            delay 0.001;
         end loop;
      end;

      Flyology.Task_Lifecycle_Testing.Reset;
      declare
         Set         : aliased Flyology.Operations.Completion_Set (1);
         Observation : Generation_Observation;
         Wait        : Prepared.Observation_Operation :=
           Prepared.Observe_Exact
             (Set'Access, Item'Access, Admission, Prepared.First_Handle (Admission), Timeout => 0.01);

         task Canceller is
            entry Start;
         end Canceller;

         task body Canceller is
         begin
            accept Start;
            Prepared.Cancel_And_Join (Admission);
         end Canceller;

         task Releaser;

         task body Releaser is
         begin
            Flyology.Task_Lifecycle_Testing.Wait_Reached
              (Flyology.Task_Lifecycle_Testing.Admission_Signal_Interrupted);
            delay 0.05;
            Flyology.Task_Lifecycle_Testing.Release
              (Flyology.Task_Lifecycle_Testing.Admission_Signal_Interrupted);
         end Releaser;
      begin
         Flyology.Task_Lifecycle_Testing.Arm (Flyology.Task_Lifecycle_Testing.Admission_Signal_Interrupted);
         Flyology.Task_Lifecycle_Testing.Interrupt_Next_Admission_Signal;
         Canceller.Start;
         Flyology.Task_Lifecycle_Testing.Wait_Reached
           (Flyology.Task_Lifecycle_Testing.Admission_Signal_Interrupted);
         Flyology.Operations.Wait_All (Set);
         Prepared.Finish (Wait, Observation);
         if Observation.Status /= Generation_Terminated then
            raise Program_Error with "pre-ack lifecycle outcome lost to expired deadline";
         end if;
         Flyology.Task_Lifecycle_Testing.Reset;
      end;

      Prepared.Prepare_Start (Item'Access, 1, Claim, P_Result);
      Prepared.Commit_Start (Claim, Admission, C_Result);
      R_Result := Prepared.Admission_Cancelled;
      Prepared.Release_To_Run (Admission, R_Result'Access);
      if P_Result /= Prepared.Start_Prepared
        or else C_Result /= Prepared.Start_Committed
        or else R_Result /= Prepared.Admission_Released
      then
         raise Program_Error with "signal-lifetime admission setup failed";
      end if;

      Flyology.Task_Lifecycle_Testing.Reset;
      declare
         protected type Fence_State is
            procedure Mark_Registered;
            procedure Mark_Cancelled (Still_Active : Boolean);
            procedure Mark_Finished;
            procedure Mark_Failed;
            function Registered return Boolean;
            function Cancelled return Boolean;
            function Active_After_Cancel return Boolean;
            function Finished return Boolean;
            function Failed return Boolean;
         private
            Is_Registered : Boolean := False;
            Is_Cancelled  : Boolean := False;
            Was_Active    : Boolean := False;
            Is_Finished   : Boolean := False;
            Has_Failed    : Boolean := False;
         end Fence_State;

         protected body Fence_State is
            procedure Mark_Registered is
            begin
               Is_Registered := True;
            end Mark_Registered;

            procedure Mark_Cancelled (Still_Active : Boolean) is
            begin
               Is_Cancelled := True;
               Was_Active := Still_Active;
            end Mark_Cancelled;

            procedure Mark_Finished is
            begin
               Is_Finished := True;
            end Mark_Finished;

            procedure Mark_Failed is
            begin
               Has_Failed := True;
            end Mark_Failed;

            function Registered return Boolean
            is (Is_Registered);
            function Cancelled return Boolean
            is (Is_Cancelled);
            function Active_After_Cancel return Boolean
            is (Was_Active);
            function Finished return Boolean
            is (Is_Finished);
            function Failed return Boolean
            is (Has_Failed);
         end Fence_State;

         Fence : Fence_State;

         task Observation_Owner is
            entry Start;
            entry Cancel;
         end Observation_Owner;

         task body Observation_Owner is
         begin
            accept Start;
            declare
               Set  : aliased Flyology.Operations.Completion_Set (1);
               Wait : Prepared.Observation_Operation :=
                 Prepared.Observe_Exact
                   (Set'Access, Item'Access, Admission, Prepared.First_Handle (Admission), Timeout => -1.0);
            begin
               Fence.Mark_Registered;
               accept Cancel;
               Flyology.Operations.Cancel (Wait);
               Fence.Mark_Cancelled (Flyology.Operations.Is_Active (Wait));
            end;
            Fence.Mark_Finished;
         exception
            when others =>
               Fence.Mark_Failed;
         end Observation_Owner;

         task Lifetime_Canceller is
            entry Start;
         end Lifetime_Canceller;

         task body Lifetime_Canceller is
         begin
            accept Start;
            Prepared.Cancel_And_Join (Admission);
         end Lifetime_Canceller;
      begin
         Observation_Owner.Start;
         while not Fence.Registered loop
            delay 0.001;
         end loop;
         Flyology.Task_Lifecycle_Testing.Arm (Flyology.Task_Lifecycle_Testing.Admission_Signal_Claimed);
         Lifetime_Canceller.Start;
         Flyology.Task_Lifecycle_Testing.Wait_Reached
           (Flyology.Task_Lifecycle_Testing.Admission_Signal_Claimed);
         Observation_Owner.Cancel;
         while not Fence.Cancelled loop
            delay 0.001;
         end loop;
         if not Fence.Active_After_Cancel or else Observation_Owner'Terminated then
            raise Program_Error with "claimed signal did not fence completion-set lifetime";
         end if;
         delay 0.01;
         if Observation_Owner'Terminated then
            raise Program_Error with "completion-set owner escaped a claimed signal";
         end if;
         Flyology.Task_Lifecycle_Testing.Release (Flyology.Task_Lifecycle_Testing.Admission_Signal_Claimed);
         while not Observation_Owner'Terminated loop
            delay 0.001;
         end loop;
         if not Fence.Finished or else Fence.Failed then
            raise Program_Error with "completion-set owner did not drain after signal ack";
         end if;
         Flyology.Task_Lifecycle_Testing.Reset;
      exception
         when others =>
            Flyology.Task_Lifecycle_Testing.Release
              (Flyology.Task_Lifecycle_Testing.Admission_Signal_Claimed);
            abort Observation_Owner;
            abort Lifetime_Canceller;
            Flyology.Task_Lifecycle_Testing.Reset;
            raise;
      end;
   end;

   Exercise_Snapshot_Integrity;
   Exercise_Producer_Abort;
   Assert_Reusable;
   Exercise_Commit_Evidence_Failures;
   Owner.Join;
exception
   when others =>
      Families.Request_Shutdown (Item);
      begin
         Owner.Join;
      exception
         when Tasking_Error =>
            null;
      end;
      if not Abort_Owner'Terminated then
         Families.Request_Shutdown (Abort_Item);
         begin
            Abort_Owner.Join;
         exception
            when Tasking_Error =>
               null;
         end;
      end if;
      raise;
end Prepared_Admission_Abort_Smoke;
