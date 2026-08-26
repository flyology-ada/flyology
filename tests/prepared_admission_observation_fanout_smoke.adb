with Ada.Real_Time;
with Flyology;
with Flyology.Cancellation;
with Flyology.Operations;
with Flyology.Supervision;
with Flyology.Supervision.Children;
with Flyology.Supervision.Families;
with Flyology.Supervision.Families.Prepared_Admissions;

procedure Prepared_Admission_Observation_Fanout_Smoke is
   use Flyology;
   use Flyology.Supervision;
   use type Ada.Real_Time.Time;
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
        First_Child_Id      => 45_000_000_000,
        Maximum_Children    => 2,
        Event_Capacity      => 8,
        Monitor_Capacity    => 2);

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

   procedure Prepare_Blocked
     (Input     : Request;
      Claim     : in out Prepared.Start_Claim;
      Admission : in out Prepared.Started_Admission;
      Observed  : out Child_Handle)
   is
      P_Result : Prepared.Prepare_Result;
      C_Result : Prepared.Commit_Result;
   begin
      Prepared.Prepare_Start (Item'Access, Input, Claim, P_Result);
      Prepared.Commit_Start (Claim, Admission, C_Result);
      if P_Result /= Prepared.Start_Prepared
        or else C_Result /= Prepared.Start_Committed
      then
         raise Program_Error with "fan-out admission setup failed";
      end if;
      Observed := Prepared.First_Handle (Admission);
   end Prepare_Blocked;

   Deadline : constant Ada.Real_Time.Time :=
     Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
begin
   Owner.Start;
   loop
      exit when Families.Accepting (Item);
      if Ada.Real_Time.Clock >= Deadline then
         raise Program_Error with "fan-out family did not open";
      end if;
      delay 0.001;
   end loop;

   declare
      First_Claim  : Prepared.Start_Claim :=
        Prepared.Vacant_Start_Claim (Item'Access);
      Second_Claim : Prepared.Start_Claim :=
        Prepared.Vacant_Start_Claim (Item'Access);
      First        : Prepared.Started_Admission :=
        Prepared.Vacant_Started_Admission (Item'Access);
      Second       : Prepared.Started_Admission :=
        Prepared.Vacant_Started_Admission (Item'Access);
      First_Monitor  : Prepared.Prepared_Observation_Claim :=
        Prepared.Vacant_Observation_Claim (Item'Access);
      Second_Monitor : Prepared.Prepared_Observation_Claim :=
        Prepared.Vacant_Observation_Claim (Item'Access);
      First_Handle  : Child_Handle;
      Second_Handle : Child_Handle;
      O_Result      : Prepared.Observation_Reserve_Result;
      R_Result      : aliased Prepared.Release_Result :=
        Prepared.Admission_Cancelled;
      Completed     : aliased Boolean := False;
      Set           : aliased Flyology.Operations.Completion_Set (2);
      First_Wait    : Prepared.Observation_Operation
        (Set'Access, Item'Access);
      Second_Wait   : Prepared.Observation_Operation
        (Set'Access, Item'Access);
      Observation   : Generation_Observation;
      Batch         : Flyology.Operations.Completion_Batch (2);
   begin
      Prepare_Blocked (1, First_Claim, First, First_Handle);
      Prepare_Blocked (2, Second_Claim, Second, Second_Handle);
      Prepared.Reserve_Observation (First, First_Monitor, O_Result);
      if O_Result /= Prepared.Observation_Reserved then
         raise Program_Error with "first fan-out monitor did not reserve";
      end if;
      Prepared.Reserve_Observation (Second, Second_Monitor, O_Result);
      if O_Result /= Prepared.Observation_Reserved then
         raise Program_Error with "second fan-out monitor did not reserve";
      end if;

      Prepared.Release_To_Run
        (First, R_Result'Access, Completed'Access);
      if R_Result /= Prepared.Admission_Released or else not Completed then
         raise Program_Error with "first fan-out admission did not release";
      end if;
      R_Result := Prepared.Admission_Cancelled;
      Completed := False;
      Prepared.Release_To_Run
        (Second, R_Result'Access, Completed'Access);
      if R_Result /= Prepared.Admission_Released or else not Completed then
         raise Program_Error with "second fan-out admission did not release";
      end if;

      Prepared.Activate_Exact
        (First_Monitor, First_Handle, -1.0, First_Wait);
      Prepared.Activate_Exact
        (Second_Monitor, Second_Handle, -1.0, Second_Wait);
      Prepared.Cancel_And_Join (First);
      Flyology.Operations.Wait_Some (Set, Batch);
      if Batch.Count /= 1
        or else Batch.Ids (1) /= Flyology.Operations.Id (First_Wait)
        or else not Flyology.Operations.Is_Active (Second_Wait)
      then
         raise Program_Error
           with "shared wake did not isolate the first prepared observation";
      end if;
      Prepared.Finish (First_Wait, Observation);
      if Observation.Status /= Generation_Terminated then
         raise Program_Error with "first shared-wake fact was not terminal";
      end if;

      Prepared.Release_Observation_Claim (First_Monitor);
      Prepare_Blocked (3, First_Claim, First, First_Handle);
      Prepared.Reserve_Observation (First, First_Monitor, O_Result);
      if O_Result /= Prepared.Observation_Reserved
        or else not Prepared.Is_Active (Second_Monitor)
      then
         raise Program_Error
           with "one released monitor slot was not independently reusable";
      end if;
      Prepared.Cancel_And_Join (First);
      Prepared.Release_Observation_Claim (First_Monitor);

      Prepared.Cancel_And_Join (Second);
      Flyology.Operations.Wait_All (Set);
      Prepared.Finish (Second_Wait, Observation);
      if Observation.Status /= Generation_Terminated then
         raise Program_Error with "second shared-wake fact was not terminal";
      end if;
      Prepared.Release_Observation_Claim (Second_Monitor);
   end;

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
end Prepared_Admission_Observation_Fanout_Smoke;
