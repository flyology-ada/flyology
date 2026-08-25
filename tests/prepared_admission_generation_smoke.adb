with Ada.Real_Time;
with Flyology;
with Flyology.Cancellation;
with Flyology.Supervision;
with Flyology.Supervision.Children;
with Flyology.Supervision.Families;
with Flyology.Supervision.Families.Prepared_Admissions;
with Flyology.Task_Lifecycle_Testing;

procedure Prepared_Admission_Generation_Smoke is
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
        First_Child_Id      => 43_000_000_000,
        Maximum_Children    => 2,
        Event_Capacity      => 8,
        Monitor_Capacity    => 1);

   package Prepared is new
     Families.Prepared_Admissions
       (Request_Assignment_And_Cleanup_Are_Nonraising => True);

   use type Prepared.Commit_Result;
   use type Prepared.Prepare_Result;

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

   procedure Commit_Final
     (Claim     : in out Prepared.Start_Claim;
      Admission : in out Prepared.Started_Admission)
   is
      Result : Prepared.Commit_Result;
   begin
      Prepared.Commit_Start (Claim, Admission, Result);
      if Result /= Prepared.Start_Committed
        or else Current_Generation (Prepared.First_Handle (Admission))
                /= Generation'Last
      then
         raise Program_Error
           with "forced final prepared generation was not published";
      end if;
   end Commit_Final;

   Deadline : constant Ada.Real_Time.Time :=
     Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
begin
   Owner.Start;
   loop
      exit when Families.Accepting (Item);
      if Ada.Real_Time.Clock >= Deadline then
         raise Program_Error with "generation-test family did not open";
      end if;
      delay 0.001;
   end loop;

   declare
      First     : Prepared.Start_Claim :=
        Prepared.Vacant_Start_Claim (Item'Access);
      Second    : Prepared.Start_Claim :=
        Prepared.Vacant_Start_Claim (Item'Access);
      Probe     : Prepared.Start_Claim :=
        Prepared.Vacant_Start_Claim (Item'Access);
      Retired   : Prepared.Start_Claim :=
        Prepared.Vacant_Start_Claim (Item'Access);
      Admission : Prepared.Started_Admission :=
        Prepared.Vacant_Started_Admission (Item'Access);
      P_Result  : Prepared.Prepare_Result;
   begin
      Prepared.Prepare_Start (Item'Access, 1, First, P_Result);
      if P_Result /= Prepared.Start_Prepared then
         raise Program_Error with "first prepared slot was unavailable";
      end if;
      Prepared.Prepare_Start (Item'Access, 2, Second, P_Result);
      if P_Result /= Prepared.Start_Prepared then
         raise Program_Error with "second prepared slot was unavailable";
      end if;

      Flyology.Task_Lifecycle_Testing.Force_Next_Prepared_Generation_Final;
      Prepared.Prepare_Start (Item'Access, 3, Probe, P_Result);
      if P_Result /= Prepared.Start_Capacity_Exhausted then
         raise Program_Error
           with "occupied prepared slots did not report capacity";
      end if;

      Prepared.Rollback (First);
      Prepared.Prepare_Start (Item'Access, 4, Retired, P_Result);
      if P_Result /= Prepared.Start_Prepared then
         raise Program_Error
           with "failed reserve consumed the final-generation hook";
      end if;
      Commit_Final (Retired, Admission);
      Prepared.Cancel_And_Join (Admission);

      Prepared.Rollback (Second);
      declare
         Ordinary    : Child_Handle;
         Observation : Generation_Observation;
      begin
         Families.Start (Item, 5, Ordinary);
         loop
            exit when Families.Current (Item, Ordinary).Live;
            if Ada.Real_Time.Clock >= Deadline then
               raise Program_Error
                 with "ordinary Start did not publish its live generation";
            end if;
            delay 0.001;
         end loop;
         Families.Stop (Item, Ordinary);
         Observation :=
           Families.Wait_Termination (Item, Ordinary, Timeout => 2.0);
         if Observation.Status /= Generation_Terminated then
            raise Program_Error
              with "ordinary Start did not skip a retired prepared slot";
         end if;
      end;

      Flyology.Task_Lifecycle_Testing.Force_Next_Prepared_Generation_Final;
      Prepared.Prepare_Start (Item'Access, 6, Retired, P_Result);
      if P_Result /= Prepared.Start_Prepared then
         raise Program_Error
           with "scan did not skip the retired prepared slot";
      end if;
      Commit_Final (Retired, Admission);

      Prepared.Prepare_Start (Item'Access, 7, Probe, P_Result);
      if P_Result /= Prepared.Start_Capacity_Exhausted then
         raise Program_Error
           with "retired plus occupied slots did not report capacity";
      end if;
      Prepared.Cancel_And_Join (Admission);

      Prepared.Prepare_Start (Item'Access, 8, Probe, P_Result);
      if P_Result /= Prepared.Start_Generation_Exhausted then
         raise Program_Error
           with
             "all retired prepared slots did not report generation exhaustion";
      end if;
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
end Prepared_Admission_Generation_Smoke;
