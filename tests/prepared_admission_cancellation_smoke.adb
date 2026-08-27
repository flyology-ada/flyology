with Ada.Real_Time;
with Flyology;
with Flyology.Cancellation;
with Flyology.Operations;
with Flyology.Supervision;
with Flyology.Supervision.Children;
with Flyology.Supervision.Families;
with Flyology.Supervision.Families.Prepared_Admissions;
with Flyology.Task_Lifecycle_Testing;

procedure Prepared_Admission_Cancellation_Smoke is
   use Flyology;
   use Flyology.Supervision;
   use type Ada.Real_Time.Time;
   use type Flyology.Supervision.Generation;
   use type Flyology.Supervision.Generation_Observation_Status;
   use type Flyology.Supervision.Termination_Kind;

   type Request is new Positive;

   protected type Progress is
      procedure Begin_Generation (Attempt : out Positive);
      entry Wait_For_First_Failure;
      procedure Permit_First_Failure;
      function Attempts return Natural;
   private
      Count    : Natural := 0;
      May_Fail : Boolean := False;
   end Progress;

   protected body Progress is
      procedure Begin_Generation (Attempt : out Positive) is
      begin
         Count := Count + 1;
         Attempt := Count;
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
      Attempt : Positive;
   begin
      State.State.Begin_Generation (Attempt);
      Mark_Ready (Control.all);
      if Attempt = 1 then
         loop
            select
               State.State.Wait_For_First_Failure;
               exit;
            or
               delay 0.001;
            end select;
            if Stop_Requested (Control.all) then
               raise Flyology.Cancellation.Operation_Cancelled;
            end if;
         end loop;
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
        First_Child_Id      => 45_000_000_000,
        Maximum_Children    => 1,
        Event_Capacity      => 8,
        Monitor_Capacity    => 1);

   package Prepared is new
     Families.Prepared_Admissions (Request_Assignment_And_Cleanup_Are_Nonraising => True);

   use type Prepared.Observation_Reserve_Result;

   use type Prepared.Commit_Result;
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
   Owner.Start;
   pragma Warnings (Off, "variable ""Item"" is not modified in loop body");
   pragma Warnings (Off, "possible infinite loop");
   loop
      exit when Families.Accepting (Item);
      if Ada.Real_Time.Clock >= Deadline then
         raise Program_Error with "cancellation-test family did not open";
      end if;
      delay 0.001;
   end loop;
   pragma Warnings (On, "possible infinite loop");
   pragma Warnings (On, "variable ""Item"" is not modified in loop body");

   declare
      Claim                    : Prepared.Start_Claim := Prepared.Vacant_Start_Claim (Item'Access);
      Admission                : Prepared.Started_Admission :=
        Prepared.Vacant_Started_Admission (Item'Access);
      Monitor                  : Prepared.Prepared_Observation_Claim :=
        Prepared.Vacant_Observation_Claim (Item'Access);
      Set                      : aliased Flyology.Operations.Completion_Set (1);
      Wait                     : Prepared.Observation_Operation (Set'Access, Item'Access);
      P_Result                 : Prepared.Prepare_Result;
      C_Result                 : Prepared.Commit_Result;
      R_Result                 : aliased Prepared.Release_Result := Prepared.Admission_Cancelled;
      Applied                  : aliased Boolean := True;
      First                    : Child_Handle;
      Replacement              : Child_Handle;
      Observation              : Generation_Observation;
      Reused                   : Child_Handle;
      Reused_Claim             : Prepared.Start_Claim := Prepared.Vacant_Start_Claim (Item'Access);
      Reused_Admission         : Prepared.Started_Admission :=
        Prepared.Vacant_Started_Admission (Item'Access);
      Reused_Monitor           : Prepared.Prepared_Observation_Claim :=
        Prepared.Vacant_Observation_Claim (Item'Access);
      Reused_Set               : aliased Flyology.Operations.Completion_Set (1);
      Reused_Wait              : Prepared.Observation_Operation (Reused_Set'Access, Item'Access);
      O_Result                 : Prepared.Observation_Reserve_Result;
      Attempts_Before_Reused   : Natural;
      Shutdown_Claim           : Prepared.Start_Claim := Prepared.Vacant_Start_Claim (Item'Access);
      Shutdown_Admission       : Prepared.Started_Admission :=
        Prepared.Vacant_Started_Admission (Item'Access);
      Shutdown_Monitor         : Prepared.Prepared_Observation_Claim :=
        Prepared.Vacant_Observation_Claim (Item'Access);
      Shutdown_Set             : aliased Flyology.Operations.Completion_Set (1);
      Shutdown_Wait            : Prepared.Observation_Operation (Shutdown_Set'Access, Item'Access);
      Shutdown_Handle          : Child_Handle;
      Attempts_Before_Shutdown : Natural;
   begin
      Prepared.Prepare_Start (Item'Access, 1, Claim, P_Result);
      Prepared.Commit_Start (Claim, Admission, C_Result);
      Prepared.Reserve_Observation (Admission, Monitor, O_Result);
      if P_Result /= Prepared.Start_Prepared
        or else C_Result /= Prepared.Start_Committed
        or else O_Result /= Prepared.Observation_Reserved
      then
         raise Program_Error with "cancellation-test admission setup failed";
      end if;
      First := Prepared.First_Handle (Admission);
      Prepared.Request_Cancellation (Admission, Current_Generation (First), Applied'Access);
      if Applied then
         raise Program_Error with "blocked admission accepted cancellation";
      end if;

      Prepared.Release_To_Run (Admission, R_Result'Access);
      if R_Result /= Prepared.Admission_Released then
         raise Program_Error with "cancellation-test admission did not release";
      end if;
      loop
         exit when State.State.Attempts = 1;
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "first cancellation-test generation did not start";
         end if;
         delay 0.001;
      end loop;

      Prepared.Request_Cancellation (Admission, Generation'Last, Applied'Access);
      if Applied then
         raise Program_Error with "noncurrent generation cancellation was applied";
      end if;

      State.State.Permit_First_Failure;
      loop
         exit when State.State.Attempts >= 2;
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "replacement cancellation target did not start";
         end if;
         delay 0.001;
      end loop;
      Replacement := Families.Latest (Item, Child (First));
      if Current_Generation (Replacement) <= Current_Generation (First) then
         raise Program_Error with "replacement cancellation target did not advance";
      end if;

      Prepared.Activate_Exact (Monitor, Current_Generation (First), 0.0, Wait);
      Flyology.Operations.Wait_All (Set);
      Prepared.Finish (Wait, Observation);
      if Observation.Status /= Generation_Terminated
        or else Observation.Snapshot.Generation /= Current_Generation (First)
      then
         raise Program_Error with "first-generation fact was not retained";
      end if;
      Prepared.Activate_Exact (Monitor, Current_Generation (First), 0.0, Wait);
      Flyology.Operations.Wait_All (Set);
      Prepared.Finish (Wait, Observation);
      if Observation.Status /= Generation_Replaced
        or else Observation.Snapshot.Generation /= Current_Generation (Replacement)
      then
         raise Program_Error with "exact first-generation rearm did not reveal replacement";
      end if;

      Prepared.Request_Cancellation (Admission, Current_Generation (First), Applied'Access);
      if Applied then
         raise Program_Error with "stale first-generation cancellation was applied";
      end if;
      Flyology.Task_Lifecycle_Testing.Reset;
      Flyology.Task_Lifecycle_Testing.Arm
        (Flyology.Task_Lifecycle_Testing.Prepared_Admission_Cancellation_Requested);
      Applied := False;
      declare
         task Canceller is
            entry Start;
         end Canceller;

         task body Canceller is
         begin
            accept Start;
            Prepared.Request_Cancellation (Admission, Current_Generation (Replacement), Applied'Access);
         end Canceller;
      begin
         Canceller.Start;
         Flyology.Task_Lifecycle_Testing.Wait_Reached
           (Flyology.Task_Lifecycle_Testing.Prepared_Admission_Cancellation_Requested);
         abort Canceller;
         Flyology.Task_Lifecycle_Testing.Release
           (Flyology.Task_Lifecycle_Testing.Prepared_Admission_Cancellation_Requested);
         while not Canceller'Terminated loop
            delay 0.001;
         end loop;
      end;
      if not Applied then
         raise Program_Error with "aborted exact cancellation lost its applied cut";
      end if;
      Flyology.Task_Lifecycle_Testing.Reset;
      Prepared.Activate_Exact (Monitor, Replacement, -1.0, Wait);
      Flyology.Operations.Wait_All (Set);
      Prepared.Finish (Wait, Observation);
      while Observation.Status = Generation_Terminated and then Observation.Snapshot.State /= Joined loop
         Prepared.Activate_Exact (Monitor, Replacement, -1.0, Wait);
         Flyology.Operations.Wait_All (Set);
         Prepared.Finish (Wait, Observation);
      end loop;
      if Observation.Status /= Generation_Terminated
        or else Observation.Snapshot.State /= Joined
        or else Observation.Snapshot.Termination.Kind /= Cancelled
      then
         raise Program_Error with "replacement cancellation did not terminate exactly";
      elsif Prepared.Admission_Join_Is_Immediate (Admission, Current_Generation (First)) then
         raise Program_Error with "replaced generation gained final join authority";
      elsif not Prepared.Admission_Join_Is_Immediate (Admission, Current_Generation (Replacement)) then
         raise Program_Error with "final replacement lacked exact join authority";
      end if;
      Prepared.Request_Cancellation (Admission, Current_Generation (Replacement), Applied'Access);
      if Applied then
         raise Program_Error with "terminal generation cancellation was reapplied";
      end if;
      Prepared.Cancel_And_Join (Admission);
      Prepared.Release_Observation_Claim (Monitor);

      Flyology.Task_Lifecycle_Testing.Reset;
      begin
         Flyology.Task_Lifecycle_Testing.Arm (Flyology.Task_Lifecycle_Testing.Family_Before_Take_Start);
         Flyology.Task_Lifecycle_Testing.Wait_Reached
           (Flyology.Task_Lifecycle_Testing.Family_Before_Take_Start);
         Prepared.Prepare_Start (Item'Access, 2, Reused_Claim, P_Result);
         Prepared.Commit_Start (Reused_Claim, Reused_Admission, C_Result);
         Prepared.Reserve_Observation (Reused_Admission, Reused_Monitor, O_Result);
         if P_Result /= Prepared.Start_Prepared
           or else C_Result /= Prepared.Start_Committed
           or else O_Result /= Prepared.Observation_Reserved
         then
            raise Program_Error with "queued cancellation reuse did not prepare";
         end if;
         Reused := Prepared.First_Handle (Reused_Admission);
         R_Result := Prepared.Admission_Cancelled;
         Prepared.Release_To_Run (Reused_Admission, R_Result'Access);
         if R_Result /= Prepared.Admission_Released then
            raise Program_Error with "queued cancellation reuse did not release";
         end if;
         Prepared.Request_Cancellation (Admission, Current_Generation (Reused), Applied'Access);
         if Applied then
            raise Program_Error with "inactive admission crossed slot reuse";
         end if;
         Prepared.Request_Cancellation (Reused_Admission, Current_Generation (Reused), Applied'Access);
         if not Applied then
            raise Program_Error with "released queued cancellation was not applied";
         end if;
         Attempts_Before_Reused := State.State.Attempts;
         Prepared.Activate_Exact (Reused_Monitor, Current_Generation (Reused), -1.0, Reused_Wait);
         Flyology.Task_Lifecycle_Testing.Release (Flyology.Task_Lifecycle_Testing.Family_Before_Take_Start);
         Flyology.Operations.Wait_All (Reused_Set);
         Prepared.Finish (Reused_Wait, Observation);
         if Observation.Status /= Generation_Terminated
           or else Observation.Snapshot.Generation /= Current_Generation (Reused)
           or else Observation.Snapshot.State /= Joined
           or else Observation.Snapshot.Termination.Kind /= Cancelled
           or else State.State.Attempts /= Attempts_Before_Reused
         then
            raise Program_Error with "queued cancellation did not publish exact no-run completion";
         elsif not Prepared.Admission_Join_Is_Immediate (Reused_Admission, Current_Generation (Reused)) then
            raise Program_Error with "queued cancellation did not publish immediate join authority";
         end if;
         Observation := Families.Wait_Termination (Item, Reused, Timeout => 2.0);
         if Observation.Status /= Generation_Terminated
           or else Observation.Snapshot.State /= Joined
           or else Observation.Snapshot.Termination.Kind /= Cancelled
         then
            raise Program_Error with "reused cancellation witness did not terminate";
         elsif Prepared.Admission_Join_Is_Immediate (Admission, Current_Generation (Replacement)) then
            raise Program_Error with "inactive admission crossed completed slot reuse";
         end if;
         Prepared.Cancel_And_Join (Reused_Admission);
         Prepared.Release_Observation_Claim (Reused_Monitor);
         Flyology.Task_Lifecycle_Testing.Reset;
      exception
         when others =>
            Flyology.Task_Lifecycle_Testing.Release
              (Flyology.Task_Lifecycle_Testing.Family_Before_Take_Start);
            Flyology.Task_Lifecycle_Testing.Reset;
            raise;
      end;

      begin
         Flyology.Task_Lifecycle_Testing.Arm (Flyology.Task_Lifecycle_Testing.Family_Before_Take_Start);
         Flyology.Task_Lifecycle_Testing.Wait_Reached
           (Flyology.Task_Lifecycle_Testing.Family_Before_Take_Start);
         Prepared.Prepare_Start (Item'Access, 3, Shutdown_Claim, P_Result);
         Prepared.Commit_Start (Shutdown_Claim, Shutdown_Admission, C_Result);
         Prepared.Reserve_Observation (Shutdown_Admission, Shutdown_Monitor, O_Result);
         if P_Result /= Prepared.Start_Prepared
           or else C_Result /= Prepared.Start_Committed
           or else O_Result /= Prepared.Observation_Reserved
         then
            raise Program_Error with "queued shutdown admission did not prepare";
         end if;
         Shutdown_Handle := Prepared.First_Handle (Shutdown_Admission);
         R_Result := Prepared.Admission_Cancelled;
         Prepared.Release_To_Run (Shutdown_Admission, R_Result'Access);
         if R_Result /= Prepared.Admission_Released then
            raise Program_Error with "queued shutdown admission did not release";
         end if;
         Attempts_Before_Shutdown := State.State.Attempts;
         Prepared.Activate_Exact
           (Shutdown_Monitor, Current_Generation (Shutdown_Handle), -1.0, Shutdown_Wait);
         Families.Request_Shutdown (Item);
         Flyology.Task_Lifecycle_Testing.Release (Flyology.Task_Lifecycle_Testing.Family_Before_Take_Start);
         Flyology.Operations.Wait_All (Shutdown_Set);
         Prepared.Finish (Shutdown_Wait, Observation);
         if Observation.Status /= Generation_Terminated
           or else Observation.Snapshot.Generation /= Current_Generation (Shutdown_Handle)
           or else Observation.Snapshot.State /= Joined
           or else Observation.Snapshot.Termination.Kind /= Supervisor_Shutdown
           or else State.State.Attempts /= Attempts_Before_Shutdown
         then
            raise Program_Error with "queued shutdown did not publish exact no-run completion";
         elsif not Prepared.Admission_Join_Is_Immediate
                     (Shutdown_Admission, Current_Generation (Shutdown_Handle))
         then
            raise Program_Error with "queued shutdown lacked immediate join authority";
         end if;
         Prepared.Cancel_And_Join (Shutdown_Admission);
         Prepared.Release_Observation_Claim (Shutdown_Monitor);
         Flyology.Task_Lifecycle_Testing.Reset;
      exception
         when others =>
            Flyology.Task_Lifecycle_Testing.Release
              (Flyology.Task_Lifecycle_Testing.Family_Before_Take_Start);
            Flyology.Task_Lifecycle_Testing.Reset;
            raise;
      end;
   end;

   Owner.Join;
   declare
      Second_State  : aliased Context;
      Second_Item   : aliased Families.Family;
      Second_Result : Supervisor_Result;

      task Second_Owner is
         entry Start;
         entry Join;
      end Second_Owner;

      task body Second_Owner is
      begin
         accept Start;
         Families.Run (Second_Item, Second_State, Second_Result);
         accept Join;
      end Second_Owner;

      Claim           : Prepared.Start_Claim := Prepared.Vacant_Start_Claim (Second_Item'Access);
      Admission       : Prepared.Started_Admission := Prepared.Vacant_Started_Admission (Second_Item'Access);
      Monitor         : Prepared.Prepared_Observation_Claim :=
        Prepared.Vacant_Observation_Claim (Second_Item'Access);
      Set             : aliased Flyology.Operations.Completion_Set (1);
      Wait            : Prepared.Observation_Operation (Set'Access, Second_Item'Access);
      P_Result        : Prepared.Prepare_Result;
      C_Result        : Prepared.Commit_Result;
      O_Result        : Prepared.Observation_Reserve_Result;
      R_Result        : aliased Prepared.Release_Result := Prepared.Admission_Cancelled;
      First           : Child_Handle;
      Observation     : Generation_Observation;
      Prior_Cause     : Termination_Kind := No_Termination;
      Second_Deadline : constant Ada.Real_Time.Time := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
   begin
      Second_Owner.Start;
      loop
         exit when Families.Accepting (Second_Item);
         if Ada.Real_Time.Clock >= Second_Deadline then
            raise Program_Error with "replacement-rejection family did not open";
         end if;
         delay 0.001;
      end loop;
      Prepared.Prepare_Start (Second_Item'Access, 1, Claim, P_Result);
      Prepared.Commit_Start (Claim, Admission, C_Result);
      Prepared.Reserve_Observation (Admission, Monitor, O_Result);
      Prepared.Release_To_Run (Admission, R_Result'Access);
      if P_Result /= Prepared.Start_Prepared
        or else C_Result /= Prepared.Start_Committed
        or else O_Result /= Prepared.Observation_Reserved
        or else R_Result /= Prepared.Admission_Released
      then
         raise Program_Error with "replacement-rejection admission did not start";
      end if;
      First := Prepared.First_Handle (Admission);
      loop
         exit when Second_State.State.Attempts = 1;
         if Ada.Real_Time.Clock >= Second_Deadline then
            raise Program_Error with "replacement-rejection first generation did not start";
         end if;
         delay 0.001;
      end loop;

      Flyology.Task_Lifecycle_Testing.Reset;
      begin
         Flyology.Task_Lifecycle_Testing.Arm (Flyology.Task_Lifecycle_Testing.Admission_Before_Replacement);
         Second_State.State.Permit_First_Failure;
         Flyology.Task_Lifecycle_Testing.Wait_Reached
           (Flyology.Task_Lifecycle_Testing.Admission_Before_Replacement);
         Prepared.Activate_Exact (Monitor, Current_Generation (First), 0.0, Wait);
         Flyology.Operations.Wait_All (Set);
         Prepared.Finish (Wait, Observation);
         if Observation.Status /= Generation_Terminated
           or else Observation.Snapshot.Generation /= Current_Generation (First)
         then
            raise Program_Error with "replacement-rejection lost first terminal fact";
         end if;
         Prior_Cause := Observation.Snapshot.Termination.Kind;
         if Prior_Cause /= Unhandled_Exception then
            raise Program_Error with "replacement-rejection retained an unexpected first cause";
         end if;
         Families.Request_Shutdown (Second_Item);
         Flyology.Task_Lifecycle_Testing.Release
           (Flyology.Task_Lifecycle_Testing.Admission_Before_Replacement);
         Prepared.Activate_Exact (Monitor, Current_Generation (First), -1.0, Wait);
         Flyology.Operations.Wait_All (Set);
         Prepared.Finish (Wait, Observation);
         if Observation.Status /= Generation_Terminated
           or else Observation.Snapshot.Generation /= Current_Generation (First)
           or else Observation.Snapshot.State /= Joined
           or else Observation.Snapshot.Termination.Kind /= Prior_Cause
           or else Second_State.State.Attempts /= 1
         then
            raise Program_Error with "rejected replacement changed the retained generation";
         elsif not Prepared.Admission_Join_Is_Immediate (Admission, Current_Generation (First)) then
            raise Program_Error with "rejected replacement lacked exact join authority";
         elsif Current_Generation (First) /= Generation'Last
           and then Prepared.Admission_Join_Is_Immediate (Admission, Current_Generation (First) + 1)
         then
            raise Program_Error with "rejected replacement invented successor join authority";
         end if;
         Prepared.Cancel_And_Join (Admission);
         Prepared.Release_Observation_Claim (Monitor);
         Flyology.Task_Lifecycle_Testing.Reset;
      exception
         when others =>
            Flyology.Task_Lifecycle_Testing.Release
              (Flyology.Task_Lifecycle_Testing.Admission_Before_Replacement);
            Flyology.Task_Lifecycle_Testing.Reset;
            raise;
      end;
      Second_Owner.Join;
   exception
      when others =>
         Flyology.Task_Lifecycle_Testing.Release
           (Flyology.Task_Lifecycle_Testing.Admission_Before_Replacement);
         Flyology.Task_Lifecycle_Testing.Reset;
         if Flyology.Operations.Is_Active (Wait) then
            Flyology.Operations.Cancel (Wait);
            Flyology.Operations.Wait_All (Set);
         end if;
         if Flyology.Operations.Is_Terminal (Wait) then
            begin
               Prepared.Finish (Wait, Observation);
            exception
               when others =>
                  null;
            end;
         end if;
         if Prepared.Is_Active (Admission) then
            Prepared.Cancel_And_Join (Admission);
         end if;
         if Prepared.Is_Active (Monitor) then
            Prepared.Release_Observation_Claim (Monitor);
         end if;
         Families.Request_Shutdown (Second_Item);
         begin
            Second_Owner.Join;
         exception
            when Tasking_Error =>
               null;
         end;
         raise;
   end;
exception
   when others =>
      State.State.Permit_First_Failure;
      Flyology.Task_Lifecycle_Testing.Reset;
      Families.Request_Shutdown (Item);
      begin
         Owner.Join;
      exception
         when Tasking_Error =>
            null;
      end;
      raise;
end Prepared_Admission_Cancellation_Smoke;
