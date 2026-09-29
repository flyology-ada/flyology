with Ada.Real_Time;
with Flyology;
with Flyology.Cancellation;
with Flyology.Operations;
with Flyology.Supervision;
with Flyology.Supervision.Children;
with Flyology.Supervision.Families;
with Flyology.Supervision.Families.Prepared_Admissions;
with Flyology.Task_Lifecycle_Testing;

procedure Prepared_Admission_Immediate_Abort_Smoke is
   use Flyology;
   use Flyology.Supervision;
   use type Ada.Real_Time.Time;
   use type Flyology.Supervision.Generation;
   use type Flyology.Supervision.Generation_Observation_Status;

   type Request is new Positive;

   protected type Progress is
      procedure Begin_Generation;
      entry Wait_For_First_Failure;
      procedure Permit_First_Failure;
      function Attempts return Natural;
   private
      Count    : Natural := 0;
      May_Fail : Boolean := False;
   end Progress;

   protected body Progress is
      procedure Begin_Generation is
      begin
         Count := Count + 1;
      end Begin_Generation;

      entry Wait_For_First_Failure when May_Fail is
      begin
         null;
      end Wait_For_First_Failure;

      procedure Permit_First_Failure is
      begin
         May_Fail := True;
      end Permit_First_Failure;

      function Attempts return Natural
      is (Count);
   end Progress;

   type Context is limited record
      State : Progress;
   end record;

   procedure Execute (State : in out Context; Control : not null access Generation_Control) is
      Attempt : Natural;
   begin
      State.State.Begin_Generation;
      Attempt := State.State.Attempts;
      Mark_Ready (Control.all);
      if Attempt = 1 then
         State.State.Wait_For_First_Failure;
         raise Constraint_Error with "requested first-generation failure";
      end if;
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
     (Restart           => On_Failure,
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
        First_Child_Id      => 47_000_000_000,
        Maximum_Children    => 1,
        Event_Capacity      => 8,
        Monitor_Capacity    => 1);

   package Prepared is new
     Families.Prepared_Admissions (Request_Assignment_And_Cleanup_Are_Nonraising => True);

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

   Deadline : constant Ada.Real_Time.Time := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
begin
   Flyology.Task_Lifecycle_Testing.Reset;
   Owner.Start;
   while not Families.Accepting (Item) loop
      if Ada.Real_Time.Clock >= Deadline then
         raise Program_Error with "immediate-claim family did not open";
      end if;
      delay 0.001;
   end loop;

   declare
      Claim       : Prepared.Start_Claim := Prepared.Vacant_Start_Claim (Item'Access);
      Admission   : Prepared.Started_Admission := Prepared.Vacant_Started_Admission (Item'Access);
      Monitor     : Prepared.Prepared_Observation_Claim := Prepared.Vacant_Observation_Claim (Item'Access);
      P_Result    : Prepared.Prepare_Result;
      C_Result    : Prepared.Commit_Result;
      O_Result    : Prepared.Observation_Reserve_Result;
      R_Result    : aliased Prepared.Release_Result := Prepared.Admission_Cancelled;
      Completed   : aliased Boolean := False;
      First       : Child_Handle;
      Current     : Child_Handle;
      Set         : aliased Flyology.Operations.Completion_Set (1);
      Wait        : Prepared.Observation_Operation (Set'Access, Item'Access);
      Observation : Generation_Observation;

      task Activator is
         entry Start;
      end Activator;

      task body Activator is
      begin
         accept Start;
         declare
            Local_Set  : aliased Flyology.Operations.Completion_Set (1);
            Local_Wait : Prepared.Observation_Operation (Local_Set'Access, Item'Access);
         begin
            Prepared.Activate_Exact (Monitor, First, -1.0, Local_Wait);
            Flyology.Operations.Wait_All (Local_Set);
         end;
      end Activator;

      task Canceller is
         entry Start;
      end Canceller;

      task body Canceller is
      begin
         accept Start;
         Prepared.Cancel_And_Join (Admission);
      end Canceller;

      task Replacement_Activator is
         entry Start;
      end Replacement_Activator;

      task body Replacement_Activator is
      begin
         accept Start;
         declare
            Local_Set  : aliased Flyology.Operations.Completion_Set (1);
            Local_Wait : Prepared.Observation_Operation (Local_Set'Access, Item'Access);
         begin
            Prepared.Activate_Exact (Monitor, First, -1.0, Local_Wait);
            Flyology.Operations.Wait_All (Local_Set);
         end;
      end Replacement_Activator;
   begin
      Prepared.Prepare_Start (Item'Access, 1, Claim, P_Result);
      Prepared.Commit_Start (Claim, Admission, C_Result);
      Prepared.Reserve_Observation (Admission, Monitor, O_Result);
      Prepared.Release_To_Run (Admission, R_Result'Access, Completed'Access);
      if P_Result /= Prepared.Start_Prepared
        or else C_Result /= Prepared.Start_Committed
        or else O_Result /= Prepared.Observation_Reserved
        or else R_Result /= Prepared.Admission_Released
        or else not Completed
      then
         raise Program_Error with "immediate-claim admission setup failed";
      end if;
      First := Prepared.First_Handle (Admission);
      while State.State.Attempts /= 1 loop
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "first immediate-claim generation did not start";
         end if;
         delay 0.001;
      end loop;

      Flyology.Task_Lifecycle_Testing.Arm (Flyology.Task_Lifecycle_Testing.Admission_Before_Replacement);
      Flyology.Task_Lifecycle_Testing.Arm (Flyology.Task_Lifecycle_Testing.Admission_Immediate_Claimed);
      State.State.Permit_First_Failure;
      Flyology.Task_Lifecycle_Testing.Wait_Reached
        (Flyology.Task_Lifecycle_Testing.Admission_Before_Replacement);
      Activator.Start;
      Flyology.Task_Lifecycle_Testing.Wait_Reached
        (Flyology.Task_Lifecycle_Testing.Admission_Immediate_Claimed);

      Flyology.Task_Lifecycle_Testing.Release (Flyology.Task_Lifecycle_Testing.Admission_Before_Replacement);
      while State.State.Attempts /= 2 loop
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "replacement immediate-claim generation did not start";
         end if;
         delay 0.001;
      end loop;
      Current := Families.Latest (Item, Child (First));
      Canceller.Start;
      while not Canceller'Terminated loop
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "immediate-claim cancellation did not join";
         end if;
         delay 0.001;
      end loop;

      abort Activator;
      Flyology.Task_Lifecycle_Testing.Release (Flyology.Task_Lifecycle_Testing.Admission_Immediate_Claimed);
      while not Activator'Terminated loop
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "terminal immediate-claim activator did not abort";
         end if;
         delay 0.001;
      end loop;
      Flyology.Task_Lifecycle_Testing.Reset;

      Prepared.Activate_Exact (Monitor, First, 0.0, Wait);
      Flyology.Operations.Wait_All (Set);
      Prepared.Finish (Wait, Observation);
      if Observation.Status /= Generation_Terminated
        or else Observation.Snapshot.Generation /= Current_Generation (First)
        or else Observation.Snapshot.State /= Terminated
      then
         raise Program_Error with "aborted immediate terminal fact was not restored";
      end if;

      Flyology.Task_Lifecycle_Testing.Arm (Flyology.Task_Lifecycle_Testing.Admission_Immediate_Claimed);
      Replacement_Activator.Start;
      Flyology.Task_Lifecycle_Testing.Wait_Reached
        (Flyology.Task_Lifecycle_Testing.Admission_Immediate_Claimed);
      abort Replacement_Activator;
      Flyology.Task_Lifecycle_Testing.Release (Flyology.Task_Lifecycle_Testing.Admission_Immediate_Claimed);
      while not Replacement_Activator'Terminated loop
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "replacement immediate-claim activator did not abort";
         end if;
         delay 0.001;
      end loop;
      Flyology.Task_Lifecycle_Testing.Reset;
      Prepared.Activate_Exact (Monitor, First, 0.0, Wait);
      Flyology.Operations.Wait_All (Set);
      Prepared.Finish (Wait, Observation);
      if Observation.Status /= Generation_Replaced
        or else Observation.Snapshot.Generation /= Current_Generation (Current)
      then
         raise Program_Error with "deferred replacement was not promoted";
      end if;

      Prepared.Activate_Exact (Monitor, Current, 0.0, Wait);
      Flyology.Operations.Wait_All (Set);
      Prepared.Finish (Wait, Observation);
      if Observation.Status /= Generation_Terminated
        or else Observation.Snapshot.Generation /= Current_Generation (Current)
        or else Observation.Snapshot.State /= Joined
      then
         raise Program_Error with "deferred terminal fact was not retained";
      end if;

      declare
         Reused : Child_Handle;
         Stale  : Boolean := False;
      begin
         Families.Start (Item, 2, Reused);
         begin
            Prepared.Activate_Exact (Monitor, Reused, 0.0, Wait);
         exception
            when Families.Stale_Handle =>
               Stale := True;
         end;
         if not Stale then
            raise Program_Error with "immediate claim crossed admission reuse";
         end if;
      end;
      Prepared.Release_Observation_Claim (Monitor);
   end;

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
end Prepared_Admission_Immediate_Abort_Smoke;
