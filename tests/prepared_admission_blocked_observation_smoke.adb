with Ada.Real_Time;
with Flyology;
with Flyology.Cancellation;
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
        First_Child_Id      => 44_000_000_000,
        Maximum_Children    => 1,
        Event_Capacity      => 8,
        Monitor_Capacity    => 1);

   package Prepared is new
     Families.Prepared_Admissions
       (Request_Assignment_And_Cleanup_Are_Nonraising => True);

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

   procedure Exercise (Shutdown_First : Boolean) is
      Claim     : Prepared.Start_Claim :=
        Prepared.Vacant_Start_Claim (Item'Access);
      Admission : Prepared.Started_Admission :=
        Prepared.Vacant_Started_Admission (Item'Access);
      P_Result  : Prepared.Prepare_Result;
      C_Result  : Prepared.Commit_Result;
      R_Result  : aliased Prepared.Release_Result :=
        Prepared.Admission_Cancelled;
      Handle    : Child_Handle;

      task Waiter is
         entry Start (Observed : Child_Handle);
         entry Join (Observation : out Generation_Observation);
      end Waiter;

      task body Waiter is
         Target : Child_Handle;
         Value  : Generation_Observation;
      begin
         accept Start (Observed : Child_Handle) do
            Target := Observed;
         end Start;
         Value := Families.Wait_Termination (Item, Target, Timeout => -1.0);
         accept Join (Observation : out Generation_Observation) do
            Observation := Value;
         end Join;
      end Waiter;

      Observation    : Generation_Observation;
      Registered     : Boolean := False;
      Waiter_Started : Boolean := False;
      Deadline       : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
   begin
      Prepared.Prepare_Start (Item'Access, 1, Claim, P_Result);
      Prepared.Commit_Start (Claim, Admission, C_Result);
      if P_Result /= Prepared.Start_Prepared
        or else C_Result /= Prepared.Start_Committed
      then
         raise Program_Error with "committed-blocked admission setup failed";
      end if;
      Handle := Prepared.First_Handle (Admission);
      Waiter.Start (Handle);
      Waiter_Started := True;

      while not Registered loop
         begin
            Observation :=
              Families.Wait_Termination (Item, Handle, Timeout => 0.0);
            if Observation.Status /= Observation_Timed_Out then
               raise Program_Error
                 with "committed-blocked handle became terminal too early";
            end if;
         exception
            when Constraint_Error =>
               Registered := True;
         end;
         if not Registered and then Ada.Real_Time.Clock >= Deadline then
            raise Program_Error
              with "committed-blocked waiter did not retain monitor capacity";
         end if;
         delay 0.001;
      end loop;

      if Shutdown_First then
         Families.Request_Shutdown (Item);
         Prepared.Release_To_Run (Admission, R_Result'Access);
         if R_Result /= Prepared.Admission_Cancelled then
            raise Program_Error
              with "shutdown admitted a committed-blocked request";
         end if;
      end if;

      Prepared.Cancel_And_Join (Admission);
      Waiter.Join (Observation);
      if Observation.Status /= Generation_Terminated
        or else Observation.Snapshot.Generation /= Current_Generation (Handle)
        or else Observation.Snapshot.Termination.Kind
                /= (if Shutdown_First then Supervisor_Shutdown else Cancelled)
      then
         raise Program_Error
           with "committed-blocked cancellation stranded exact observation";
      end if;
   exception
      when others =>
         if Prepared.Is_Active (Admission) then
            Prepared.Cancel_And_Join (Admission);
         end if;
         if Waiter_Started then
            begin
               Waiter.Join (Observation);
            exception
               when Tasking_Error =>
                  null;
            end;
         else
            abort Waiter;
         end if;
         raise;
   end Exercise;

   Deadline : constant Ada.Real_Time.Time :=
     Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
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
