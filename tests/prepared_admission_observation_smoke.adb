with Ada.Real_Time;
with Flyology;
with Flyology.Cancellation;
with Flyology.Operations;
with Flyology.Supervision;
with Flyology.Supervision.Children;
with Flyology.Supervision.Families;
with Flyology.Supervision.Families.Prepared_Admissions;
with Flyology.Task_Lifecycle_Testing;

procedure Prepared_Admission_Observation_Smoke is
   use Flyology;
   use Flyology.Supervision;
   use type Ada.Real_Time.Time;
   use type Flyology.Supervision.Generation;

   generic
      Restart : Restart_Kind;
      Backoff : Ada.Real_Time.Time_Span;
      Expect_Replacement : Boolean;
      Prove_Pending : Boolean;
   procedure Run_Case;

   procedure Run_Case is
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

      procedure Execute
        (State : in out Context; Control : not null access Generation_Control)
      is
         Attempt : Positive;
      begin
         State.State.Begin_Generation (Attempt);
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
        (Restart           => Restart,
         Impact            => Isolate_Child,
         Recovery          =>
           (Burst_Attempts    => 3,
            Window            => Ada.Real_Time.Seconds (1),
            Total_Attempts    => 3,
            Initial_Backoff   => Backoff,
            Maximum_Backoff   => Backoff,
            Stability_Reset   => Ada.Real_Time.Seconds (1),
            Recovery_Deadline => Ada.Real_Time.Seconds (2)),
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
           First_Child_Id      => 41_000_000_000,
           Maximum_Children    => 1,
           Event_Capacity      => 12,
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
            raise Program_Error with "observation family did not open";
         end if;
         delay 0.001;
      end loop;
      pragma Warnings (On, "possible infinite loop");
      pragma Warnings (On, "variable ""Item"" is not modified in loop body");

      declare
         Claim     : Prepared.Start_Claim :=
           Prepared.Vacant_Start_Claim (Item'Access);
         Admission : Prepared.Started_Admission :=
           Prepared.Vacant_Started_Admission (Item'Access);
         P_Result  : Prepared.Prepare_Result;
         C_Result  : Prepared.Commit_Result;
         R_Result  : aliased Prepared.Release_Result :=
           Prepared.Admission_Cancelled;
      begin
         Prepared.Prepare_Start (Item'Access, 1, Claim, P_Result);
         Prepared.Commit_Start (Claim, Admission, C_Result);
         Prepared.Release_To_Run (Admission, R_Result'Access);
         if P_Result /= Prepared.Start_Prepared
           or else C_Result /= Prepared.Start_Committed
           or else R_Result /= Prepared.Admission_Released
         then
            raise Program_Error with "observation admission setup failed";
         end if;
         loop
            exit when State.State.Attempts = 1;
            if Ada.Real_Time.Clock >= Deadline then
               raise Program_Error
                 with "first observation generation did not start";
            end if;
            delay 0.001;
         end loop;

         declare
            First       : constant Child_Handle :=
              Prepared.First_Handle (Admission);
            Observation : Generation_Observation;
         begin
            declare
               Zero_Set : aliased Flyology.Operations.Completion_Set (1);
               Zero     : Prepared.Observation_Operation :=
                 Prepared.Observe_Exact
                   (Zero_Set'Access,
                    Item'Access,
                    Admission,
                    First,
                    Timeout => 0.0);
            begin
               Flyology.Operations.Wait_All (Zero_Set);
               Prepared.Finish (Zero, Observation);
               if Observation.Status /= Observation_Timed_Out then
                  raise Program_Error
                    with "zero-time exact observation did not time out";
               end if;
            end;
            declare
               Timed_Set : aliased Flyology.Operations.Completion_Set (1);
               Timed     : Prepared.Observation_Operation :=
                 Prepared.Observe_Exact
                   (Timed_Set'Access,
                    Item'Access,
                    Admission,
                    First,
                    Timeout => 0.01);
            begin
               Flyology.Operations.Wait_All (Timed_Set);
               Prepared.Finish (Timed, Observation);
               if Observation.Status /= Observation_Timed_Out then
                  raise Program_Error
                    with "positive exact-observation deadline did not expire";
               end if;
            end;
            declare
               Cancel_Set : aliased Flyology.Operations.Completion_Set (1);
               Cancelled  : Prepared.Observation_Operation :=
                 Prepared.Observe_Exact
                   (Cancel_Set'Access,
                    Item'Access,
                    Admission,
                    First,
                    Timeout => -1.0);
               Raised     : Boolean := False;
            begin
               Flyology.Operations.Cancel (Cancelled);
               Flyology.Operations.Wait_All (Cancel_Set);
               begin
                  Prepared.Finish (Cancelled, Observation);
               exception
                  when Prepared.Operation_Cancelled =>
                     Raised := True;
               end;
               if not Raised then
                  raise Program_Error
                    with "cancelled exact observation did not raise";
               end if;
            end;
            declare
               Set  : aliased Flyology.Operations.Completion_Set (1);
               Wait : Prepared.Observation_Operation :=
                 Prepared.Observe_Exact
                   (Set'Access,
                    Item'Access,
                    Admission,
                    First,
                    Timeout => -1.0);
            begin
               declare
                  Duplicate_Set :
                    aliased Flyology.Operations.Completion_Set (1);
                  Rejected      : Boolean := False;
               begin
                  begin
                     declare
                        Duplicate : Prepared.Observation_Operation :=
                          Prepared.Observe_Exact
                            (Duplicate_Set'Access,
                             Item'Access,
                             Admission,
                             First,
                             Timeout => 0.0);
                        pragma Unreferenced (Duplicate);
                     begin
                        null;
                     end;
                  exception
                     when Constraint_Error =>
                        Rejected := True;
                  end;
                  if not Rejected then
                     raise Program_Error
                       with "exact observer exceeded monitor capacity";
                  end if;
               end;
               State.State.Permit_First_Failure;
               Flyology.Operations.Wait_All (Set);
               Prepared.Finish (Wait, Observation);
               if Observation.Status /= Generation_Terminated
                 or else Observation.Snapshot.Generation
                         /= Current_Generation (First)
               then
                  raise Program_Error
                    with "first exact termination was not retained";
               end if;

               if Prove_Pending then
                  Flyology.Task_Lifecycle_Testing.Reset;
                  Flyology.Task_Lifecycle_Testing.Arm
                    (Flyology
                       .Task_Lifecycle_Testing
                       .Admission_Monitor_Registered);
                  declare
                     task Registration_Controller is
                        entry Start;
                     end Registration_Controller;

                     task body Registration_Controller is
                     begin
                        accept Start;
                        Flyology.Task_Lifecycle_Testing.Wait_Reached
                          (Flyology
                             .Task_Lifecycle_Testing
                             .Admission_Monitor_Registered);
                        Flyology.Task_Lifecycle_Testing.Release
                          (Flyology
                             .Task_Lifecycle_Testing
                             .Admission_Monitor_Registered);
                     end Registration_Controller;
                  begin
                     Registration_Controller.Start;
                     declare
                        Next_Set :
                          aliased Flyology.Operations.Completion_Set (1);
                        Next     :
                          Prepared.Observation_Operation
                            (Next_Set'Access, Item'Access);
                     begin
                        Prepared.Observe_Exact
                          (Admission,
                           First,
                           Timeout   => -1.0,
                           Operation => Next);
                        Flyology.Operations.Wait_All (Next_Set);
                        Prepared.Finish (Next, Observation);
                     end;
                  end;
               else
                  declare
                     Next_Set : aliased Flyology.Operations.Completion_Set (1);
                     Next     : Prepared.Observation_Operation :=
                       Prepared.Observe_Exact
                         (Next_Set'Access,
                          Item'Access,
                          Admission,
                          First,
                          Timeout => -1.0);
                  begin
                     Flyology.Operations.Wait_All (Next_Set);
                     Prepared.Finish (Next, Observation);
                  end;
               end if;

               if Expect_Replacement then
                  if Observation.Status /= Generation_Replaced
                    or else Observation.Snapshot.Generation
                            <= Current_Generation (First)
                    or else Observation.Snapshot.State /= Starting
                    or else not Observation.Snapshot.Live
                  then
                     raise Program_Error
                       with "replacement publication was incoherent";
                  end if;
               elsif Observation.Status /= Generation_Terminated then
                  raise Program_Error
                    with "no-restart admission did not remain terminal";
               end if;
            end;
         end;

         Prepared.Cancel_And_Join (Admission);
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
   end Run_Case;

   procedure Positive_Backoff is new
     Run_Case
       (Restart            => On_Failure,
        Backoff            => Ada.Real_Time.Milliseconds (100),
        Expect_Replacement => True,
        Prove_Pending      => True);

   procedure Zero_Backoff is new
     Run_Case
       (Restart            => On_Failure,
        Backoff            => Ada.Real_Time.Time_Span_Zero,
        Expect_Replacement => True,
        Prove_Pending      => False);

   procedure No_Restart is new
     Run_Case
       (Restart            => Never,
        Backoff            => Ada.Real_Time.Time_Span_Zero,
        Expect_Replacement => False,
        Prove_Pending      => False);
begin
   Positive_Backoff;
   Flyology.Task_Lifecycle_Testing.Reset;
   Zero_Backoff;
   No_Restart;
end Prepared_Admission_Observation_Smoke;
