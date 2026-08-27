with Ada.Real_Time;
with Flyology;
with Flyology.Cancellation;
with Flyology.Operations;
with Flyology.Supervision;
with Flyology.Supervision.Children;
with Flyology.Supervision.Families;
with Flyology.Supervision.Families.Prepared_Admissions;

procedure Prepared_Admissions_Smoke is
   use Flyology;
   use Flyology.Supervision;
   use type Ada.Real_Time.Time;
   use type Flyology.Supervision.Child_Handle;
   use type Flyology.Supervision.Generation_Observation_Status;

   type Request is new Positive;

   protected type Progress is
      procedure Mark_Started;
      function Started return Boolean;
   private
      Has_Started : Boolean := False;
   end Progress;

   protected body Progress is
      procedure Mark_Started is
      begin
         Has_Started := True;
      end Mark_Started;

      function Started return Boolean
      is (Has_Started);
   end Progress;

   type Context is limited record
      State : Progress;
   end record;

   procedure Execute (State : in out Context; Control : not null access Generation_Control) is
   begin
      State.State.Mark_Started;
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
        First_Child_Id      => 40_000_000_000,
        Maximum_Children    => 2,
        Event_Capacity      => 8,
        Monitor_Capacity    => 1);

   package Prepared is new
     Families.Prepared_Admissions (Request_Assignment_And_Cleanup_Are_Nonraising => True);

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
   declare
      Rejected : Boolean := False;
   begin
      begin
         declare
            package Invalid_Prepared is new
              Families.Prepared_Admissions (Request_Assignment_And_Cleanup_Are_Nonraising => False);
            pragma Unreferenced (Invalid_Prepared);
         begin
            null;
         end;
      exception
         when Program_Error =>
            Rejected := True;
      end;
      if not Rejected then
         raise Program_Error with "false request-assignment contract was accepted";
      end if;
   end;

   Owner.Start;
   --  Owner changes Item concurrently while this task waits for admission.
   pragma Warnings (Off, "variable ""Item"" is not modified in loop body");
   pragma Warnings (Off, "possible infinite loop");
   loop
      exit when Families.Accepting (Item);
      if Ada.Real_Time.Clock >= Deadline then
         raise Program_Error with "prepared family did not open";
      end if;
      delay 0.001;
   end loop;
   pragma Warnings (On, "possible infinite loop");
   pragma Warnings (On, "variable ""Item"" is not modified in loop body");

   declare
      Claim              : Prepared.Start_Claim := Prepared.Vacant_Start_Claim (Item'Access);
      Other              : Prepared.Start_Claim := Prepared.Vacant_Start_Claim (Item'Access);
      Exhausted          : Prepared.Start_Claim := Prepared.Vacant_Start_Claim (Item'Access);
      Admission          : Prepared.Started_Admission := Prepared.Vacant_Started_Admission (Item'Access);
      Occupied           : Prepared.Started_Admission := Prepared.Vacant_Started_Admission (Item'Access);
      Foreign_Item       : aliased Families.Family;
      Foreign_Claim      : Prepared.Start_Claim := Prepared.Vacant_Start_Claim (Foreign_Item'Access);
      Foreign_Admission  : Prepared.Started_Admission :=
        Prepared.Vacant_Started_Admission (Foreign_Item'Access);
      P_Result           : Prepared.Prepare_Result;
      C_Result           : Prepared.Commit_Result;
      R_Result           : aliased Prepared.Release_Result := Prepared.Admission_Cancelled;
      Rolled_Back_Handle : Child_Handle;
      Prepared_Handle    : Child_Handle;
      Release_Completed  : aliased Boolean := False;
   begin
      Prepared.Prepare_Start (Item'Access, 1, Claim, P_Result);
      if P_Result /= Prepared.Start_Prepared or else not Prepared.Is_Active (Claim) then
         raise Program_Error with "prepared reservation did not publish its owner";
      end if;
      Rolled_Back_Handle := Prepared.First_Handle (Claim);
      if Rolled_Back_Handle /= Families.Latest (Item, 40_000_000_000)
        or else not Is_Current (Rolled_Back_Handle, 40_000_000_000, 1)
      then
         raise Program_Error with "prepared claim did not expose its exact first handle";
      end if;
      Prepared.Rollback (Claim);
      if Prepared.Is_Active (Claim) then
         raise Program_Error with "prepared rollback retained claim ownership";
      end if;
      Prepared.Prepare_Start (Item'Access, 1, Claim, P_Result);
      if P_Result /= Prepared.Start_Prepared or else not Prepared.Is_Active (Claim) then
         raise Program_Error with "prepared slot could not be reserved again";
      end if;
      Prepared_Handle := Prepared.First_Handle (Claim);
      if Prepared_Handle /= Families.Latest (Item, 40_000_000_000)
        or else Prepared_Handle = Rolled_Back_Handle
        or else not Is_Current (Prepared_Handle, 40_000_000_000, 2)
      then
         raise Program_Error with "reprepared claim did not advance its exact first handle";
      end if;
      declare
         Rejected : Boolean := False;
      begin
         begin
            Prepared.Prepare_Start (Item'Access, 2, Claim, P_Result);
         exception
            when Program_Error =>
               Rejected := True;
         end;
         if not Rejected then
            raise Program_Error with "occupied prepared target was accepted";
         end if;
      end;
      declare
         Rejected : Boolean := False;
      begin
         begin
            Prepared.Prepare_Start (Item'Access, 2, Foreign_Claim, P_Result);
         exception
            when Program_Error =>
               Rejected := True;
         end;
         if not Rejected then
            raise Program_Error with "foreign prepared target was accepted";
         end if;
      end;
      Prepared.Prepare_Start (Item'Access, 2, Other, P_Result);
      if P_Result /= Prepared.Start_Prepared then
         raise Program_Error with "second prepared reservation did not use remaining capacity";
      end if;
      Prepared.Prepare_Start (Item'Access, 3, Exhausted, P_Result);
      if P_Result /= Prepared.Start_Capacity_Exhausted or else Prepared.Is_Active (Exhausted) then
         raise Program_Error with "prepared reservation did not retain fixed capacity";
      end if;
      Prepared.Commit_Start (Other, Occupied, C_Result);
      if C_Result /= Prepared.Start_Committed
        or else Prepared.Is_Active (Other)
        or else not Prepared.Is_Active (Occupied)
      then
         raise Program_Error with "occupied-target fixture did not commit";
      end if;
      declare
         Rejected : Boolean := False;
      begin
         begin
            Prepared.Commit_Start (Claim, Occupied, C_Result);
         exception
            when Program_Error =>
               Rejected := True;
         end;
         if not Rejected or else not Prepared.Is_Active (Claim) or else not Prepared.Is_Active (Occupied) then
            raise Program_Error with "occupied commit target changed ownership";
         end if;
      end;
      Prepared.Cancel_And_Join (Occupied);
      declare
         Rejected : Boolean := False;
      begin
         begin
            Prepared.Commit_Start (Claim, Foreign_Admission, C_Result);
         exception
            when Program_Error =>
               Rejected := True;
         end;
         if not Rejected or else not Prepared.Is_Active (Claim) or else Prepared.Is_Active (Foreign_Admission)
         then
            raise Program_Error with "foreign commit target changed ownership";
         end if;
      end;
      delay 0.01;
      if State.State.Started then
         raise Program_Error with "prepared request executed before release";
      end if;

      Prepared.Commit_Start (Claim, Admission, C_Result);
      if C_Result /= Prepared.Start_Committed
        or else Prepared.Is_Active (Claim)
        or else not Prepared.Is_Active (Admission)
        or else Prepared.First_Handle (Admission) /= Prepared_Handle
      then
         raise Program_Error with "prepared commit did not preserve exact handle identity";
      end if;
      delay 0.01;
      if State.State.Started then
         raise Program_Error with "committed blocked request executed before release";
      end if;

      Prepared.Release_To_Run (Admission, R_Result'Access, Release_Completed'Access);
      if R_Result /= Prepared.Admission_Released
        or else not Release_Completed
        or else not Prepared.Is_Released (Admission)
      then
         raise Program_Error with "release did not publish execution ownership";
      end if;
      R_Result := Prepared.Admission_Cancelled;
      Release_Completed := False;
      Prepared.Release_To_Run (Admission, R_Result'Access, Release_Completed'Access);
      if R_Result /= Prepared.Admission_Released or else not Release_Completed then
         raise Program_Error with "repeated release was not idempotent";
      end if;
      loop
         exit when State.State.Started;
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "released admission did not execute";
         end if;
         delay 0.001;
      end loop;

      declare
         Set         : aliased Flyology.Operations.Completion_Set (1);
         Operation   : Prepared.Observation_Operation :=
           Prepared.Observe_Exact
             (Set'Access, Item'Access, Admission, Prepared.First_Handle (Admission), Timeout => -1.0);
         Observation : Generation_Observation;
      begin
         Prepared.Cancel_And_Join (Admission);
         Flyology.Operations.Wait_All (Set);
         Prepared.Finish (Operation, Observation);
         if Observation.Status /= Generation_Terminated then
            raise Program_Error with "scoped admission observation lost exact termination";
         end if;
      end;
   end;

   declare
      Claim     : Prepared.Start_Claim := Prepared.Vacant_Start_Claim (Item'Access);
      Closed    : Prepared.Start_Claim := Prepared.Vacant_Start_Claim (Item'Access);
      Admission : Prepared.Started_Admission := Prepared.Vacant_Started_Admission (Item'Access);
      P_Result  : Prepared.Prepare_Result;
      C_Result  : Prepared.Commit_Result;
   begin
      Prepared.Prepare_Start (Item'Access, 3, Claim, P_Result);
      if P_Result /= Prepared.Start_Prepared then
         raise Program_Error with "pre-shutdown prepared reservation failed";
      end if;
      Families.Request_Shutdown (Item);
      Prepared.Commit_Start (Claim, Admission, C_Result);
      if C_Result /= Prepared.Start_Admission_Closed
        or else not Prepared.Is_Active (Claim)
        or else Prepared.Is_Active (Admission)
      then
         raise Program_Error with "closed commit did not retain prepared ownership";
      end if;
      Prepared.Rollback (Claim);
      Prepared.Prepare_Start (Item'Access, 4, Closed, P_Result);
      if P_Result /= Prepared.Start_Admission_Closed or else Prepared.Is_Active (Closed) then
         raise Program_Error with "closed prepare changed ownership";
      end if;
   end;

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
end Prepared_Admissions_Smoke;
