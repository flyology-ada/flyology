with Ada.Real_Time;
with Flyology;
with Flyology.Cancellation;
with Flyology.Operations;
with Flyology.Supervision;
with Flyology.Supervision.Children;
with Flyology.Supervision.Families;
with Flyology.Supervision.Families.Prepared_Admissions;

procedure Prepared_Admission_Blocked_Observation_Smoke is
   use Flyology;
   use Flyology.Supervision;
   use type Ada.Real_Time.Time;
   use type Flyology.Supervision.Generation;
   use type Flyology.Supervision.Generation_Observation_Status;
   use type Flyology.Supervision.Termination_Kind;

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
        First_Child_Id      => 44_000_000_000,
        Maximum_Children    => 1,
        Event_Capacity      => 8,
        Monitor_Capacity    => 1);

   package Prepared is new
     Families.Prepared_Admissions (Request_Assignment_And_Cleanup_Are_Nonraising => True);

   use type Prepared.Commit_Result;
   use type Prepared.Prepare_Result;
   use type Prepared.Release_Result;
   use type Prepared.Observation_Reserve_Result;

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

   procedure Exercise (Shutdown_First : Boolean) is
      Claim             : Prepared.Start_Claim := Prepared.Vacant_Start_Claim (Item'Access);
      Admission         : Prepared.Started_Admission := Prepared.Vacant_Started_Admission (Item'Access);
      Observation_Claim : Prepared.Prepared_Observation_Claim :=
        Prepared.Vacant_Observation_Claim (Item'Access);
      P_Result          : Prepared.Prepare_Result;
      C_Result          : Prepared.Commit_Result;
      O_Result          : Prepared.Observation_Reserve_Result;
      R_Result          : aliased Prepared.Release_Result := Prepared.Admission_Cancelled;
      Release_Completed : aliased Boolean := False;
      Handle            : Child_Handle;
      Set               : aliased Flyology.Operations.Completion_Set (1);
      Wait              : Prepared.Observation_Operation (Set'Access, Item'Access);
      Observation       : Generation_Observation;
      Capacity_Reserved : Boolean := False;
   begin
      Prepared.Prepare_Start (Item'Access, 1, Claim, P_Result);
      Prepared.Commit_Start (Claim, Admission, C_Result);
      if P_Result /= Prepared.Start_Prepared or else C_Result /= Prepared.Start_Committed then
         raise Program_Error with "committed-blocked admission setup failed";
      end if;
      Handle := Prepared.First_Handle (Admission);
      Prepared.Reserve_Observation (Admission, Observation_Claim, O_Result);
      if O_Result /= Prepared.Observation_Reserved or else not Prepared.Is_Active (Observation_Claim) then
         raise Program_Error with "blocked observation capacity was not reserved";
      end if;
      begin
         Observation := Families.Wait_Termination (Item, Handle, Timeout => 0.0);
      exception
         when Constraint_Error =>
            Capacity_Reserved := True;
      end;
      if not Capacity_Reserved then
         raise Program_Error with "prepared observation did not retain monitor capacity";
      end if;

      if Shutdown_First then
         Families.Request_Shutdown (Item);
         Prepared.Release_To_Run (Admission, R_Result'Access, Release_Completed'Access);
         if R_Result /= Prepared.Admission_Cancelled or else not Release_Completed then
            raise Program_Error with "shutdown release did not publish completed cancellation";
         end if;
      end if;

      Prepared.Cancel_And_Join (Admission);
      if Shutdown_First and then Current_Generation (Handle) = Generation'First then
         raise Program_Error with "second same-slot admission did not advance its first generation";
      end if;
      if Shutdown_First then
         declare
            Stale : Boolean := False;
         begin
            begin
               Prepared.Activate_Exact
                 (Observation_Claim,
                  Generation'Pred (Current_Generation (Handle)),
                  Timeout   => 0.0,
                  Operation => Wait);
            exception
               when Families.Stale_Handle =>
                  Stale := True;
            end;
            if not Stale
              or else Flyology.Operations.Is_Active (Wait)
              or else Flyology.Operations.Is_Terminal (Wait)
              or else not Prepared.Is_Active (Observation_Claim)
            then
               raise Program_Error with "generation overload accepted a fact below the admission epoch";
            end if;
         end;
      end if;
      Prepared.Activate_Exact (Observation_Claim, Handle, 0.0, Wait);
      Flyology.Operations.Wait_All (Set);
      Prepared.Finish (Wait, Observation);
      if Observation.Status /= Generation_Terminated
        or else Observation.Snapshot.Generation /= Current_Generation (Handle)
        or else Observation.Snapshot.Termination.Kind
                /= (if Shutdown_First then Supervisor_Shutdown else Cancelled)
      then
         raise Program_Error with "committed-blocked cancellation stranded exact observation";
      end if;
      Prepared.Release_Observation_Claim (Observation_Claim);
      if Prepared.Is_Active (Observation_Claim) then
         raise Program_Error with "prepared observation claim did not release";
      end if;
   exception
      when others =>
         if Prepared.Is_Active (Admission) then
            Prepared.Cancel_And_Join (Admission);
         end if;
         if Prepared.Is_Active (Observation_Claim) then
            Prepared.Release_Observation_Claim (Observation_Claim);
         end if;
         raise;
   end Exercise;

   Deadline : constant Ada.Real_Time.Time := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
begin
   Owner.Start;
   --  Owner changes Item concurrently while this task waits for admission.
   pragma Warnings (Off, "variable ""Item"" is not modified in loop body");
   pragma Warnings (Off, "possible infinite loop");
   loop
      exit when Families.Accepting (Item);
      if Ada.Real_Time.Clock >= Deadline then
         raise Program_Error with "blocked-observation family did not open";
      end if;
      delay 0.001;
   end loop;
   pragma Warnings (On, "possible infinite loop");
   pragma Warnings (On, "variable ""Item"" is not modified in loop body");

   Exercise (Shutdown_First => False);
   Exercise (Shutdown_First => True);
   Families.Request_Shutdown (Item);
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
      raise;
end Prepared_Admission_Blocked_Observation_Smoke;
