with Ada.Real_Time;
with Flyology;
with Flyology.Cancellation;
with Flyology.Operations;
with Flyology.Supervision;
with Flyology.Supervision.Children;
with Flyology.Supervision.Families;
with Flyology.Supervision.Families.Prepared_Admissions;
with Flyology.Task_Lifecycle_Testing;

procedure Prepared_Admission_Persistent_Abort_Smoke is
   use Flyology;
   use Flyology.Supervision;
   use type Ada.Real_Time.Time;
   use type Flyology.Supervision.Generation;
   use type Flyology.Supervision.Generation_Observation_Status;

   type Request is new Positive;
   type Context is limited null record;

   procedure Execute
     (State : in out Context; Control : not null access Generation_Control)
   is
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

   package Generation_Task is new
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
      Generation_Task.Run (State, Control, Result);
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
        First_Child_Id      => 46_000_000_000,
        Maximum_Children    => 1,
        Event_Capacity      => 8,
        Monitor_Capacity    => 1);

   package Prepared is new
     Families.Prepared_Admissions
       (Request_Assignment_And_Cleanup_Are_Nonraising => True);

   use type Prepared.Commit_Result;
   use type Prepared.Observation_Reserve_Result;
   use type Prepared.Prepare_Result;
   use type Prepared.Release_Result;

   State  : aliased Context;
   Item   : aliased Families.Family;
   Result : Supervisor_Result;

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

   procedure Prepare_Admission
     (Input     : Request;
      Admission : in out Prepared.Started_Admission;
      Monitor   : in out Prepared.Prepared_Observation_Claim;
      Observed  : out Child_Handle;
      Release   : Boolean := True)
   is
      Claim     : Prepared.Start_Claim :=
        Prepared.Vacant_Start_Claim (Item'Access);
      P_Result  : Prepared.Prepare_Result;
      C_Result  : Prepared.Commit_Result;
      O_Result  : Prepared.Observation_Reserve_Result;
      R_Result  : aliased Prepared.Release_Result :=
        Prepared.Admission_Cancelled;
      Completed : aliased Boolean := False;
   begin
      Prepared.Prepare_Start (Item'Access, Input, Claim, P_Result);
      Prepared.Commit_Start (Claim, Admission, C_Result);
      Prepared.Reserve_Observation (Admission, Monitor, O_Result);
      if P_Result /= Prepared.Start_Prepared
        or else C_Result /= Prepared.Start_Committed
        or else O_Result /= Prepared.Observation_Reserved
      then
         raise Program_Error with "persistent admission setup failed";
      end if;
      Observed := Prepared.First_Handle (Admission);
      if Release then
         Prepared.Release_To_Run
           (Admission, R_Result'Access, Completed'Access);
         if R_Result /= Prepared.Admission_Released or else not Completed then
            raise Program_Error with "persistent admission release failed";
         end if;
      end if;
   end Prepare_Admission;

   procedure Exercise_Reservation_Cut_Abort is
      type Reservation_Cut is (Before_Reserve, After_Reserve);
   begin
      for Cut in Reservation_Cut loop
         declare
            Admission : Prepared.Started_Admission :=
              Prepared.Vacant_Started_Admission (Item'Access);
            Monitor   : Prepared.Prepared_Observation_Claim :=
              Prepared.Vacant_Observation_Claim (Item'Access);
            Claim     : Prepared.Start_Claim :=
              Prepared.Vacant_Start_Claim (Item'Access);
            P_Result  : Prepared.Prepare_Result;
            C_Result  : Prepared.Commit_Result;
            O_Result  : Prepared.Observation_Reserve_Result;
            Reserved  : aliased Boolean := True;
            Local_Deadline : constant Ada.Real_Time.Time :=
              Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);

            task Worker is
               entry Start;
            end Worker;

            task body Worker is
            begin
               accept Start;
               Prepared.Reserve_Observation
                 (Admission, Monitor, Reserved'Access, O_Result);
            end Worker;
         begin
            Prepared.Prepare_Start (Item'Access, 5, Claim, P_Result);
            Prepared.Commit_Start (Claim, Admission, C_Result);
            if P_Result /= Prepared.Start_Prepared
              or else C_Result /= Prepared.Start_Committed
            then
               raise Program_Error with "reservation-cut admission setup failed";
            end if;

            Flyology.Task_Lifecycle_Testing.Reset;
            Flyology.Task_Lifecycle_Testing.Arm
              ((if Cut = Before_Reserve
                then Flyology.Task_Lifecycle_Testing.Prepared_Observation_Before_Reserve
                else Flyology.Task_Lifecycle_Testing.Prepared_Observation_Reserved));
            Worker.Start;
            Flyology.Task_Lifecycle_Testing.Wait_Reached
              ((if Cut = Before_Reserve
                then Flyology.Task_Lifecycle_Testing.Prepared_Observation_Before_Reserve
                else Flyology.Task_Lifecycle_Testing.Prepared_Observation_Reserved));
            abort Worker;
            Flyology.Task_Lifecycle_Testing.Release
              ((if Cut = Before_Reserve
                then Flyology.Task_Lifecycle_Testing.Prepared_Observation_Before_Reserve
                else Flyology.Task_Lifecycle_Testing.Prepared_Observation_Reserved));
            while not Worker'Terminated loop
               if Ada.Real_Time.Clock >= Local_Deadline then
                  raise Program_Error with "reservation-cut worker did not terminate";
               end if;
               delay 0.001;
            end loop;
            Flyology.Task_Lifecycle_Testing.Reset;

            if Cut = Before_Reserve then
               if Reserved or else Prepared.Is_Active (Monitor) then
                  raise Program_Error with "pre-cut abort retained observation ownership";
               end if;
               Prepared.Reserve_Observation (Admission, Monitor, O_Result);
               if O_Result /= Prepared.Observation_Reserved
                 or else not Prepared.Is_Active (Monitor)
               then
                  raise Program_Error with "legacy reserve did not reuse pre-cut capacity";
               end if;
            elsif Cut = After_Reserve
              and then (not Reserved or else not Prepared.Is_Active (Monitor))
            then
               raise Program_Error with
                 "post-cut abort lost observation ownership evidence";
            end if;

            declare
               Other          : Prepared.Prepared_Observation_Claim :=
                 Prepared.Vacant_Observation_Claim (Item'Access);
               Foreign_Item   : aliased Families.Family;
               Foreign        : Prepared.Prepared_Observation_Claim :=
                 Prepared.Vacant_Observation_Claim (Foreign_Item'Access);
               Other_Reserved : aliased Boolean := True;
               Other_Result   : Prepared.Observation_Reserve_Result;
               Rejected       : Boolean := False;
            begin
               begin
                  Prepared.Reserve_Observation
                    (Admission, Monitor, Other_Reserved'Access, Other_Result);
               exception
                  when Program_Error =>
                     Rejected := True;
               end;
               if not Rejected
                 or else Other_Reserved
                 or else not Prepared.Is_Active (Monitor)
               then
                  raise Program_Error with "occupied reserve changed ownership evidence";
               end if;

               Other_Reserved := True;
               Prepared.Reserve_Observation
                 (Admission, Other, Other_Reserved'Access, Other_Result);
               if Other_Result /= Prepared.Observation_Capacity_Exhausted
                 or else Other_Reserved
                 or else Prepared.Is_Active (Other)
               then
                  raise Program_Error with "capacity failure published observation ownership";
               end if;

               Other_Reserved := True;
               Rejected := False;
               begin
                  Prepared.Reserve_Observation
                    (Admission, Foreign, Other_Reserved'Access, Other_Result);
               exception
                  when Program_Error =>
                     Rejected := True;
               end;
               if not Rejected
                 or else Other_Reserved
                 or else Prepared.Is_Active (Foreign)
               then
                  raise Program_Error with "foreign reserve changed ownership evidence";
               end if;
            end;

            Prepared.Cancel_And_Join (Admission);
            Prepared.Release_Observation_Claim (Monitor);
            if Prepared.Is_Active (Monitor) then
               raise Program_Error with "reservation-cut cleanup retained its claim";
            end if;
            Prepared.Release_Observation_Claim (Monitor);
         exception
            when others =>
               Flyology.Task_Lifecycle_Testing.Reset;
               abort Worker;
               if Prepared.Is_Active (Admission) then
                  Prepared.Cancel_And_Join (Admission);
               end if;
               if Prepared.Is_Active (Monitor) then
                  Prepared.Release_Observation_Claim (Monitor);
               end if;
               raise;
         end;
      end loop;

      declare
         Admission : Prepared.Started_Admission :=
           Prepared.Vacant_Started_Admission (Item'Access);
         Monitor   : Prepared.Prepared_Observation_Claim :=
           Prepared.Vacant_Observation_Claim (Item'Access);
         Claim     : Prepared.Start_Claim :=
           Prepared.Vacant_Start_Claim (Item'Access);
         P_Result  : Prepared.Prepare_Result;
         C_Result  : Prepared.Commit_Result;
         O_Result  : Prepared.Observation_Reserve_Result;
         R_Result  : aliased Prepared.Release_Result :=
           Prepared.Admission_Cancelled;
         Completed : aliased Boolean := False;
         Reserved  : aliased Boolean := True;
      begin
         Prepared.Prepare_Start (Item'Access, 6, Claim, P_Result);
         Prepared.Commit_Start (Claim, Admission, C_Result);
         Prepared.Release_To_Run
           (Admission, R_Result'Access, Completed'Access);
         if P_Result /= Prepared.Start_Prepared
           or else C_Result /= Prepared.Start_Committed
           or else R_Result /= Prepared.Admission_Released
           or else not Completed
         then
            raise Program_Error with "closed-reserve admission setup failed";
         end if;
         Prepared.Reserve_Observation
           (Admission, Monitor, Reserved'Access, O_Result);
         if O_Result /= Prepared.Observation_Admission_Closed
           or else Reserved
           or else Prepared.Is_Active (Monitor)
         then
            raise Program_Error with "closed reserve published observation ownership";
         end if;
         Prepared.Cancel_And_Join (Admission);
      exception
         when others =>
            if Prepared.Is_Active (Admission) then
               Prepared.Cancel_And_Join (Admission);
            end if;
            if Prepared.Is_Active (Monitor) then
               Prepared.Release_Observation_Claim (Monitor);
            end if;
            raise;
      end;

      declare
         Admission : Prepared.Started_Admission :=
           Prepared.Vacant_Started_Admission (Item'Access);
         Monitor   : Prepared.Prepared_Observation_Claim :=
           Prepared.Vacant_Observation_Claim (Item'Access);
         Claim     : Prepared.Start_Claim :=
           Prepared.Vacant_Start_Claim (Item'Access);
         P_Result  : Prepared.Prepare_Result;
         C_Result  : Prepared.Commit_Result;
         O_Result  : Prepared.Observation_Reserve_Result;
         Reserved  : aliased Boolean := True;
      begin
         Prepared.Prepare_Start (Item'Access, 7, Claim, P_Result);
         Prepared.Commit_Start (Claim, Admission, C_Result);
         if P_Result /= Prepared.Start_Prepared
           or else C_Result /= Prepared.Start_Committed
         then
            raise Program_Error with "identity-reserve admission setup failed";
         end if;
         Flyology.Task_Lifecycle_Testing.Force_Next_Prepared_Monitor_Identity_Exhausted;
         Prepared.Reserve_Observation
           (Admission, Monitor, Reserved'Access, O_Result);
         if O_Result /= Prepared.Observation_Identity_Exhausted
           or else Reserved
           or else Prepared.Is_Active (Monitor)
         then
            raise Program_Error with "identity exhaustion published observation ownership";
         end if;
         Prepared.Reserve_Observation
           (Admission, Monitor, Reserved'Access, O_Result);
         if O_Result /= Prepared.Observation_Reserved
           or else not Reserved
           or else not Prepared.Is_Active (Monitor)
         then
            raise Program_Error with
              "normal reserve did not publish observation ownership";
         end if;
         Prepared.Cancel_And_Join (Admission);
         Prepared.Release_Observation_Claim (Monitor);
      exception
         when others =>
            Flyology.Task_Lifecycle_Testing.Reset;
            if Prepared.Is_Active (Admission) then
               Prepared.Cancel_And_Join (Admission);
            end if;
            if Prepared.Is_Active (Monitor) then
               Prepared.Release_Observation_Claim (Monitor);
            end if;
            raise;
      end;
   end Exercise_Reservation_Cut_Abort;

   procedure Observe_Retained_Terminal
     (Monitor : in out Prepared.Prepared_Observation_Claim;
      Observed : Child_Handle)
   is
      Set         : aliased Flyology.Operations.Completion_Set (1);
      Wait        : Prepared.Observation_Operation
        (Set'Access, Item'Access);
      Observation : Generation_Observation;
   begin
      Prepared.Activate_Exact (Monitor, Observed, 0.0, Wait);
      Flyology.Operations.Wait_All (Set);
      Prepared.Finish (Wait, Observation);
      if Observation.Status /= Generation_Terminated then
         raise Program_Error with "persistent claim did not retain termination";
      end if;
   end Observe_Retained_Terminal;

   procedure Exercise_Registration_Abort is
      Admission : Prepared.Started_Admission :=
        Prepared.Vacant_Started_Admission (Item'Access);
      Monitor   : Prepared.Prepared_Observation_Claim :=
        Prepared.Vacant_Observation_Claim (Item'Access);
      Observed  : Child_Handle;
      Local_Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);

      task Observer is
         entry Start;
      end Observer;

      task body Observer is
      begin
         accept Start;
         declare
            Set  : aliased Flyology.Operations.Completion_Set (1);
            Wait : Prepared.Observation_Operation
              (Set'Access, Item'Access);
         begin
            Prepared.Activate_Exact (Monitor, Observed, -1.0, Wait);
            Flyology.Operations.Wait_All (Set);
         end;
      end Observer;
   begin
      Prepare_Admission (1, Admission, Monitor, Observed);
      Flyology.Task_Lifecycle_Testing.Reset;
      Flyology.Task_Lifecycle_Testing.Arm
        (Flyology.Task_Lifecycle_Testing.Admission_Monitor_Registered);
      Observer.Start;
      Flyology.Task_Lifecycle_Testing.Wait_Reached
        (Flyology.Task_Lifecycle_Testing.Admission_Monitor_Registered);
      abort Observer;
      Flyology.Task_Lifecycle_Testing.Release
        (Flyology.Task_Lifecycle_Testing.Admission_Monitor_Registered);
      while not Observer'Terminated loop
         if Ada.Real_Time.Clock >= Local_Deadline then
            raise Program_Error with "registration-abort observer did not terminate";
         end if;
         delay 0.001;
      end loop;
      Flyology.Task_Lifecycle_Testing.Reset;
      Prepared.Cancel_And_Join (Admission);
      Observe_Retained_Terminal (Monitor, Observed);
      Prepared.Release_Observation_Claim (Monitor);
      if Prepared.Is_Active (Monitor) then
         raise Program_Error with "registration-abort claim did not release";
      end if;
   exception
      when others =>
         Flyology.Task_Lifecycle_Testing.Reset;
         abort Observer;
         if Prepared.Is_Active (Admission) then
            Prepared.Cancel_And_Join (Admission);
         end if;
         if Prepared.Is_Active (Monitor) then
            Prepared.Release_Observation_Claim (Monitor);
         end if;
         raise;
   end Exercise_Registration_Abort;

   procedure Exercise_Claimed_Cancellation is
      Admission : Prepared.Started_Admission :=
        Prepared.Vacant_Started_Admission (Item'Access);
      Monitor   : Prepared.Prepared_Observation_Claim :=
        Prepared.Vacant_Observation_Claim (Item'Access);
      Observed  : Child_Handle;
      Set       : aliased Flyology.Operations.Completion_Set (1);
      Wait      : Prepared.Observation_Operation
        (Set'Access, Item'Access);
      Observation : Generation_Observation;
      Local_Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);

      task Canceller is
         entry Start;
      end Canceller;

      task body Canceller is
      begin
         accept Start;
         Prepared.Cancel_And_Join (Admission);
      end Canceller;
   begin
      Prepare_Admission (2, Admission, Monitor, Observed);
      Prepared.Activate_Exact (Monitor, Observed, -1.0, Wait);
      Flyology.Task_Lifecycle_Testing.Reset;
      Flyology.Task_Lifecycle_Testing.Arm
        (Flyology.Task_Lifecycle_Testing.Admission_Signal_Claimed);
      Canceller.Start;
      Flyology.Task_Lifecycle_Testing.Wait_Reached
        (Flyology.Task_Lifecycle_Testing.Admission_Signal_Claimed);
      Flyology.Operations.Cancel (Wait);
      if not Flyology.Operations.Is_Active (Wait) then
         raise Program_Error with "claimed signal did not retain cancelled operation";
      end if;
      Flyology.Task_Lifecycle_Testing.Release
        (Flyology.Task_Lifecycle_Testing.Admission_Signal_Claimed);
      Flyology.Operations.Wait_All (Set);
      declare
         Cancelled : Boolean := False;
      begin
         begin
            Prepared.Finish (Wait, Observation);
         exception
            when Prepared.Operation_Cancelled =>
               Cancelled := True;
         end;
         if not Cancelled then
            raise Program_Error with "persistent cancellation did not finish cancelled";
         end if;
      end;
      while not Canceller'Terminated loop
         if Ada.Real_Time.Clock >= Local_Deadline then
            raise Program_Error with "claimed-signal cancellation did not terminate";
         end if;
         delay 0.001;
      end loop;
      Flyology.Task_Lifecycle_Testing.Reset;
      Prepared.Activate_Exact (Monitor, Observed, 0.0, Wait);
      Flyology.Operations.Wait_All (Set);
      Prepared.Finish (Wait, Observation);
      if Observation.Status /= Generation_Terminated
        or else Observation.Snapshot.State /= Joined
      then
         raise Program_Error with "claimed signal lost the deferred final boundary";
      end if;
      declare
         Reused           : Child_Handle;
         Stale            : Boolean := False;
         Reused_Terminal  : Generation_Observation;
      begin
         Families.Start (Item, 9, Reused);
         begin
            Prepared.Activate_Exact (Monitor, Reused, 0.0, Wait);
         exception
            when Families.Stale_Handle =>
               Stale := True;
         end;
         if not Stale then
            raise Program_Error with "claimed signal observation crossed slot reuse";
         end if;
         Prepared.Release_Observation_Claim (Monitor);
         Families.Stop (Item, Reused);
         Reused_Terminal := Families.Wait_Termination (Item, Reused);
         if Reused_Terminal.Status /= Generation_Terminated then
            raise Program_Error with "slot-reuse witness did not terminate";
         end if;
      end;
   exception
      when others =>
         Flyology.Task_Lifecycle_Testing.Reset;
         abort Canceller;
         if Prepared.Is_Active (Admission) then
            Prepared.Cancel_And_Join (Admission);
         end if;
         if Prepared.Is_Active (Monitor) then
            Prepared.Release_Observation_Claim (Monitor);
         end if;
         raise;
   end Exercise_Claimed_Cancellation;

   procedure Exercise_Claimed_Signal_Order is
      Admission : Prepared.Started_Admission :=
        Prepared.Vacant_Started_Admission (Item'Access);
      Monitor   : Prepared.Prepared_Observation_Claim :=
        Prepared.Vacant_Observation_Claim (Item'Access);
      Observed  : Child_Handle;
      Set       : aliased Flyology.Operations.Completion_Set (1);
      Wait      : Prepared.Observation_Operation
        (Set'Access, Item'Access);
      Observation : Generation_Observation;
      Local_Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);

      task Canceller is
         entry Start;
      end Canceller;

      task body Canceller is
      begin
         accept Start;
         Prepared.Cancel_And_Join (Admission);
      end Canceller;
   begin
      Prepare_Admission (5, Admission, Monitor, Observed);
      if Prepared.Admission_Join_Is_Immediate
           (Admission, Current_Generation (Observed))
      then
         raise Program_Error with "live admission was classified as immediately joinable";
      end if;
      while not Families.Current (Item, Observed).Live loop
         if Ada.Real_Time.Clock >= Local_Deadline then
            raise Program_Error with "claimed-signal generation did not become live";
         end if;
         delay 0.001;
      end loop;
      Prepared.Activate_Exact (Monitor, Observed, -1.0, Wait);
      Flyology.Task_Lifecycle_Testing.Reset;
      Flyology.Task_Lifecycle_Testing.Arm
        (Flyology.Task_Lifecycle_Testing.Admission_Before_Manager_Done);
      Families.Stop (Item, Observed);
      Flyology.Operations.Wait_All (Set);
      Prepared.Finish (Wait, Observation);
      if Observation.Status /= Generation_Terminated
        or else Observation.Snapshot.State /= Terminated
      then
         raise Program_Error with "claimed signal did not publish the first terminal boundary";
      end if;
      if Prepared.Admission_Join_Is_Immediate
           (Admission, Observation.Snapshot.Generation)
      then
         raise Program_Error with "generation termination preceded exact admission joinability";
      end if;
      Flyology.Task_Lifecycle_Testing.Wait_Reached
        (Flyology.Task_Lifecycle_Testing.Admission_Before_Manager_Done);
      Prepared.Activate_Exact (Monitor, Observed, -1.0, Wait);
      Flyology.Task_Lifecycle_Testing.Arm
        (Flyology.Task_Lifecycle_Testing.Admission_Signal_Claimed);
      Flyology.Task_Lifecycle_Testing.Release
        (Flyology.Task_Lifecycle_Testing.Admission_Before_Manager_Done);
      Flyology.Task_Lifecycle_Testing.Wait_Reached
        (Flyology.Task_Lifecycle_Testing.Admission_Signal_Claimed);
      Flyology.Task_Lifecycle_Testing.Release
        (Flyology.Task_Lifecycle_Testing.Admission_Signal_Claimed);
      Flyology.Operations.Wait_All (Set);
      Prepared.Finish (Wait, Observation);
      if Observation.Status /= Generation_Terminated
        or else Observation.Snapshot.State /= Joined
      then
         raise Program_Error with "claimed signal did not retain final join for rearm";
      end if;
      if not Prepared.Admission_Join_Is_Immediate
        (Admission, Observation.Snapshot.Generation)
      then
         raise Program_Error with "joined released admission was not immediately joinable";
      end if;
      Canceller.Start;
      while not Canceller'Terminated loop
         if Ada.Real_Time.Clock >= Local_Deadline then
            raise Program_Error with "claimed-signal ordered cancellation did not terminate";
         end if;
         delay 0.001;
      end loop;
      if Prepared.Admission_Join_Is_Immediate
           (Admission, Observation.Snapshot.Generation)
      then
         raise Program_Error with "vacant joined admission retained join authority";
      end if;
      Flyology.Task_Lifecycle_Testing.Reset;
      Prepared.Release_Observation_Claim (Monitor);
   exception
      when others =>
         Flyology.Task_Lifecycle_Testing.Release
           (Flyology.Task_Lifecycle_Testing.Admission_Signal_Claimed);
         Flyology.Task_Lifecycle_Testing.Release
           (Flyology.Task_Lifecycle_Testing.Admission_Before_Manager_Done);
         Flyology.Task_Lifecycle_Testing.Reset;
         abort Canceller;
         if Prepared.Is_Active (Admission) then
            Prepared.Cancel_And_Join (Admission);
         end if;
         if Prepared.Is_Active (Monitor) then
            Prepared.Release_Observation_Claim (Monitor);
         end if;
         raise;
   end Exercise_Claimed_Signal_Order;

   procedure Exercise_Interrupted_Finalization is
      Admission : Prepared.Started_Admission :=
        Prepared.Vacant_Started_Admission (Item'Access);
      Monitor   : Prepared.Prepared_Observation_Claim :=
        Prepared.Vacant_Observation_Claim (Item'Access);
      Observed  : Child_Handle;
      Local_Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);

      task Operation_Owner is
         entry Start;
         entry Ready;
         entry Leave_Scope;
      end Operation_Owner;

      task body Operation_Owner is
      begin
         accept Start;
         declare
            Set  : aliased Flyology.Operations.Completion_Set (1);
            Wait : Prepared.Observation_Operation
              (Set'Access, Item'Access);
         begin
            Prepared.Activate_Exact (Monitor, Observed, -1.0, Wait);
            accept Ready;
            accept Leave_Scope;
         end;
      end Operation_Owner;

      task Canceller is
         entry Start;
      end Canceller;

      task body Canceller is
      begin
         accept Start;
         Prepared.Cancel_And_Join (Admission);
      end Canceller;
   begin
      Prepare_Admission (3, Admission, Monitor, Observed);
      Operation_Owner.Start;
      Operation_Owner.Ready;
      Flyology.Task_Lifecycle_Testing.Reset;
      Flyology.Task_Lifecycle_Testing.Arm
        (Flyology.Task_Lifecycle_Testing.Admission_Signal_Interrupted);
      Flyology.Task_Lifecycle_Testing.Interrupt_Next_Admission_Signal;
      Canceller.Start;
      Flyology.Task_Lifecycle_Testing.Wait_Reached
        (Flyology.Task_Lifecycle_Testing.Admission_Signal_Interrupted);
      Operation_Owner.Leave_Scope;
      delay 0.01;
      if Operation_Owner'Terminated then
         raise Program_Error with "operation finalization escaped interrupted signal";
      end if;
      Flyology.Task_Lifecycle_Testing.Release
        (Flyology.Task_Lifecycle_Testing.Admission_Signal_Interrupted);
      while not Operation_Owner'Terminated or else not Canceller'Terminated loop
         if Ada.Real_Time.Clock >= Local_Deadline then
            raise Program_Error with "interrupted-signal owners did not terminate";
         end if;
         delay 0.001;
      end loop;
      Flyology.Task_Lifecycle_Testing.Reset;
      Observe_Retained_Terminal (Monitor, Observed);
      Prepared.Release_Observation_Claim (Monitor);
   exception
      when others =>
         Flyology.Task_Lifecycle_Testing.Reset;
         abort Operation_Owner;
         abort Canceller;
         if Prepared.Is_Active (Admission) then
            Prepared.Cancel_And_Join (Admission);
         end if;
         if Prepared.Is_Active (Monitor) then
            Prepared.Release_Observation_Claim (Monitor);
         end if;
         raise;
   end Exercise_Interrupted_Finalization;

   procedure Exercise_Claim_Finalizer is
      Admission : Prepared.Started_Admission :=
        Prepared.Vacant_Started_Admission (Item'Access);
      Claim     : Prepared.Start_Claim :=
        Prepared.Vacant_Start_Claim (Item'Access);
      P_Result  : Prepared.Prepare_Result;
      C_Result  : Prepared.Commit_Result;
      Observed  : Child_Handle;
   begin
      Prepared.Prepare_Start (Item'Access, 4, Claim, P_Result);
      Prepared.Commit_Start (Claim, Admission, C_Result);
      if P_Result /= Prepared.Start_Prepared
        or else C_Result /= Prepared.Start_Committed
      then
         raise Program_Error with "claim-finalizer admission setup failed";
      end if;
      Observed := Prepared.First_Handle (Admission);
      declare
         Monitor  : Prepared.Prepared_Observation_Claim :=
           Prepared.Vacant_Observation_Claim (Item'Access);
         O_Result : Prepared.Observation_Reserve_Result;
      begin
         Prepared.Reserve_Observation (Admission, Monitor, O_Result);
         if O_Result /= Prepared.Observation_Reserved then
            raise Program_Error with "claim-finalizer monitor did not reserve";
         end if;
      end;
      declare
         Monitor  : Prepared.Prepared_Observation_Claim :=
           Prepared.Vacant_Observation_Claim (Item'Access);
         O_Result : Prepared.Observation_Reserve_Result;
      begin
         Prepared.Reserve_Observation (Admission, Monitor, O_Result);
         if O_Result /= Prepared.Observation_Reserved then
            raise Program_Error with "claim finalizer did not restore exact capacity";
         end if;
         Prepared.Cancel_And_Join (Admission);
         Observe_Retained_Terminal (Monitor, Observed);
         Prepared.Release_Observation_Claim (Monitor);
      end;
   end Exercise_Claim_Finalizer;

   procedure Exercise_Join_Query is
      Admission : Prepared.Started_Admission :=
        Prepared.Vacant_Started_Admission (Item'Access);
      Monitor   : Prepared.Prepared_Observation_Claim :=
        Prepared.Vacant_Observation_Claim (Item'Access);
      Observed  : Child_Handle;
      Exact     : Flyology.Supervision.Generation;
   begin
      Prepare_Admission
        (6, Admission, Monitor, Observed, Release => False);
      Exact := Current_Generation (Observed);
      if Prepared.Admission_Join_Is_Immediate (Admission, Exact) then
         raise Program_Error with "blocked admission exposed lifecycle join authority";
      elsif Exact /= Flyology.Supervision.Generation'Last
        and then Prepared.Admission_Join_Is_Immediate (Admission, Exact + 1)
      then
         raise Program_Error with "join query accepted a foreign generation";
      end if;
      Prepared.Cancel_And_Join (Admission);
      if Prepared.Admission_Join_Is_Immediate (Admission, Exact) then
         raise Program_Error with "inactive admission retained join authority";
      end if;
      Prepared.Release_Observation_Claim (Monitor);
   end Exercise_Join_Query;

   Deadline : constant Ada.Real_Time.Time :=
     Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
begin
   Owner.Start;
   loop
      exit when Families.Accepting (Item);
      if Ada.Real_Time.Clock >= Deadline then
         raise Program_Error with "persistent-abort family did not open";
      end if;
      delay 0.001;
   end loop;

   Exercise_Reservation_Cut_Abort;
   Exercise_Registration_Abort;
   Exercise_Claimed_Cancellation;
   Exercise_Claimed_Signal_Order;
   Exercise_Join_Query;
   Exercise_Interrupted_Finalization;
   Exercise_Claim_Finalizer;
   Families.Request_Shutdown (Item);
   Owner.Join;
exception
   when others =>
      Flyology.Task_Lifecycle_Testing.Reset;
      Families.Request_Shutdown (Item);
      begin
         Owner.Join;
      exception
         when Tasking_Error =>
            null;
      end;
      raise;
end Prepared_Admission_Persistent_Abort_Smoke;
