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
      Prove_Retained_Chain : Boolean;
      Prove_Current_Boundary : Boolean;
      Prove_Newer_Terminal : Boolean;
   procedure Run_Case;

   procedure Run_Case is
      type Request is new Positive;

      protected type Progress is
         procedure Begin_Generation (Attempt : out Positive);
         entry Wait_For_First_Failure;
         entry Wait_For_Second_Failure;
         procedure Permit_First_Failure;
         procedure Permit_Second_Failure;
         function Attempts return Natural;
      private
         Count           : Natural := 0;
         May_Fail_First  : Boolean := False;
         May_Fail_Second : Boolean := False;
      end Progress;

      protected body Progress is
         procedure Begin_Generation (Attempt : out Positive) is
         begin
            Count := Count + 1;
            Attempt := Count;
         end Begin_Generation;

         entry Wait_For_First_Failure when May_Fail_First is
         begin
            null;
         end Wait_For_First_Failure;

         entry Wait_For_Second_Failure when May_Fail_Second is
         begin
            null;
         end Wait_For_Second_Failure;

         procedure Permit_First_Failure is
         begin
            May_Fail_First := True;
         end Permit_First_Failure;

         procedure Permit_Second_Failure is
         begin
            May_Fail_Second := True;
         end Permit_Second_Failure;

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
            State.State.Wait_For_First_Failure;
            raise Constraint_Error with "requested first-generation failure";
         elsif Prove_Newer_Terminal and then Attempt = 2 then
            State.State.Wait_For_Second_Failure;
            raise Constraint_Error with "requested second-generation failure";
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
           Monitor_Capacity    => 2);

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

      Deadline : constant Ada.Real_Time.Time := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
   begin
      Flyology.Task_Lifecycle_Testing.Reset;
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
         Claim             : Prepared.Start_Claim := Prepared.Vacant_Start_Claim (Item'Access);
         Admission         : Prepared.Started_Admission := Prepared.Vacant_Started_Admission (Item'Access);
         Observation_Claim : Prepared.Prepared_Observation_Claim :=
           Prepared.Vacant_Observation_Claim (Item'Access);
         P_Result          : Prepared.Prepare_Result;
         C_Result          : Prepared.Commit_Result;
         O_Result          : Prepared.Observation_Reserve_Result;
         R_Result          : aliased Prepared.Release_Result := Prepared.Admission_Cancelled;
      begin
         Prepared.Prepare_Start (Item'Access, 1, Claim, P_Result);
         Prepared.Commit_Start (Claim, Admission, C_Result);
         Prepared.Reserve_Observation (Admission, Observation_Claim, O_Result);
         Prepared.Release_To_Run (Admission, R_Result'Access);
         if P_Result /= Prepared.Start_Prepared
           or else C_Result /= Prepared.Start_Committed
           or else O_Result /= Prepared.Observation_Reserved
           or else R_Result /= Prepared.Admission_Released
         then
            raise Program_Error with "observation admission setup failed";
         end if;
         loop
            exit when State.State.Attempts = 1;
            if Ada.Real_Time.Clock >= Deadline then
               raise Program_Error with "first observation generation did not start";
            end if;
            delay 0.001;
         end loop;

         declare
            First       : constant Child_Handle := Prepared.First_Handle (Admission);
            Observation : Generation_Observation;
         begin
            declare
               Zero_Set : aliased Flyology.Operations.Completion_Set (1);
               Zero     : Prepared.Observation_Operation :=
                 Prepared.Observe_Exact (Zero_Set'Access, Item'Access, Admission, First, Timeout => 0.0);
            begin
               Flyology.Operations.Wait_All (Zero_Set);
               Prepared.Finish (Zero, Observation);
               if Observation.Status /= Observation_Timed_Out then
                  raise Program_Error with "zero-time exact observation did not time out";
               end if;
            end;
            declare
               Timed_Set : aliased Flyology.Operations.Completion_Set (1);
               Timed     : Prepared.Observation_Operation :=
                 Prepared.Observe_Exact (Timed_Set'Access, Item'Access, Admission, First, Timeout => 0.01);
            begin
               Flyology.Operations.Wait_All (Timed_Set);
               Prepared.Finish (Timed, Observation);
               if Observation.Status /= Observation_Timed_Out then
                  raise Program_Error with "positive exact-observation deadline did not expire";
               end if;
            end;
            declare
               Cancel_Set : aliased Flyology.Operations.Completion_Set (1);
               Cancelled  : Prepared.Observation_Operation :=
                 Prepared.Observe_Exact (Cancel_Set'Access, Item'Access, Admission, First, Timeout => -1.0);
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
                  raise Program_Error with "cancelled exact observation did not raise";
               end if;
            end;
            declare
               Set                      : aliased Flyology.Operations.Completion_Set (1);
               Wait                     : Prepared.Observation_Operation (Set'Access, Item'Access);
               Retained_Current         : Child_Handle := First;
               Retained_Latest          : Child_Handle := First;
               Early_Reused             : Child_Handle := First;
               Early_Reused_Started     : Boolean := False;
               Ended_Before_Consumption : Boolean := False;
               Final_Already_Observed   : Boolean := False;
            begin
               declare
                  Stale : Boolean := False;
               begin
                  begin
                     Prepared.Activate_Exact
                       (Observation_Claim,
                        Flyology.Supervision.Generation'Last,
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
                     raise Program_Error
                       with "generation overload accepted a fact above its retained boundary";
                  end if;
               end;
               Prepared.Activate_Exact (Observation_Claim, First, Timeout => -1.0, Operation => Wait);
               declare
                  Duplicate_Set : aliased Flyology.Operations.Completion_Set (1);
                  Duplicate     : Prepared.Observation_Operation :=
                    Prepared.Observe_Exact
                      (Duplicate_Set'Access, Item'Access, Admission, First, Timeout => -1.0);
                  Overflow_Set  : aliased Flyology.Operations.Completion_Set (1);
                  Rejected      : Boolean := False;
                  Cancelled     : Boolean := False;
               begin
                  begin
                     declare
                        Overflow : Prepared.Observation_Operation :=
                          Prepared.Observe_Exact
                            (Overflow_Set'Access, Item'Access, Admission, First, Timeout => 0.0);
                        pragma Unreferenced (Overflow);
                     begin
                        null;
                     end;
                  exception
                     when Constraint_Error =>
                        Rejected := True;
                  end;
                  if not Rejected then
                     raise Program_Error with "exact observer exceeded monitor capacity";
                  end if;
                  Flyology.Operations.Cancel (Duplicate);
                  Flyology.Operations.Wait_All (Duplicate_Set);
                  begin
                     Prepared.Finish (Duplicate, Observation);
                  exception
                     when Prepared.Operation_Cancelled =>
                        Cancelled := True;
                  end;
                  if not Cancelled then
                     raise Program_Error with "capacity witness observation did not cancel";
                  end if;
               end;
               if Prove_Pending then
                  Flyology.Task_Lifecycle_Testing.Reset;
                  Flyology.Task_Lifecycle_Testing.Arm
                    (Flyology.Task_Lifecycle_Testing.Admission_Before_Replacement);
               end if;
               State.State.Permit_First_Failure;
               Flyology.Operations.Wait_All (Set);
               Prepared.Finish (Wait, Observation);
               Final_Already_Observed :=
                 Observation.Status = Generation_Terminated
                 and then Observation.Snapshot.State in Failed_Escalated | Joined;
               if Observation.Status /= Generation_Terminated
                 or else Observation.Snapshot.Generation /= Current_Generation (First)
               then
                  raise Program_Error with "first exact termination was not retained";
               end if;

               if Prove_Pending then
                  Flyology.Task_Lifecycle_Testing.Wait_Reached
                    (Flyology.Task_Lifecycle_Testing.Admission_Before_Replacement);
                  Prepared.Activate_Exact (Observation_Claim, First, Timeout => -1.0, Operation => Wait);
                  if not Flyology.Operations.Is_Active (Wait) then
                     raise Program_Error with "replacement rearm did not remain pending";
                  end if;
                  Flyology.Task_Lifecycle_Testing.Release
                    (Flyology.Task_Lifecycle_Testing.Admission_Before_Replacement);
                  Flyology.Operations.Wait_All (Set);
                  Prepared.Finish (Wait, Observation);
               else
                  if Expect_Replacement then
                     --  Make the zero-backoff case exercise a replacement
                     --  published while the persistent claim is dormant. The
                     --  first activation below must return that retained fact
                     --  and advance the claim before the current-generation
                     --  rearm.
                     loop
                        exit when State.State.Attempts >= 2;
                        if Ada.Real_Time.Clock >= Deadline then
                           raise Program_Error with "replacement did not publish before dormant rearm";
                        end if;
                        delay 0.001;
                     end loop;
                     Retained_Current := Families.Latest (Item, Child (First));
                     if Prove_Current_Boundary then
                        Prepared.Activate_Exact
                          (Observation_Claim, Retained_Current, Timeout => 0.0, Operation => Wait);
                        Flyology.Operations.Wait_All (Set);
                        Prepared.Finish (Wait, Observation);
                        if Observation.Status /= Observation_Timed_Out then
                           raise Program_Error with "current replacement boundary inherited an older fact";
                        end if;
                        Prepared.Activate_Exact
                          (Observation_Claim, Retained_Current, Timeout => -1.0, Operation => Wait);
                        Flyology.Operations.Cancel (Wait);
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
                              raise Program_Error with "cancelled current probe did not report cancellation";
                           end if;
                        end;
                        declare
                           task Canceller is
                              entry Start;
                           end Canceller;

                           task body Canceller is
                           begin
                              select
                                 accept Start;
                                 Prepared.Cancel_And_Join (Admission);
                              or
                                 terminate;
                              end select;
                           end Canceller;
                        begin
                           Prepared.Activate_Exact
                             (Observation_Claim, Retained_Current, Timeout => -1.0, Operation => Wait);
                           Canceller.Start;
                           Flyology.Operations.Wait_All (Set);
                           Prepared.Finish (Wait, Observation);
                           if Observation.Status /= Generation_Terminated
                             or else Observation.Snapshot.Generation /= Current_Generation (Retained_Current)
                           then
                              raise Program_Error with "current probe did not receive its terminal boundary";
                           end if;
                        end;
                     elsif Prove_Newer_Terminal then
                        Prepared.Activate_Exact
                          (Observation_Claim, Retained_Current, Timeout => -1.0, Operation => Wait);
                        State.State.Permit_Second_Failure;
                        loop
                           exit when State.State.Attempts >= 3;
                           if Ada.Real_Time.Clock >= Deadline then
                              raise Program_Error with "newer replacement did not start before join";
                           end if;
                           delay 0.001;
                        end loop;
                        Prepared.Cancel_And_Join (Admission);
                        Flyology.Operations.Wait_All (Set);
                        Prepared.Finish (Wait, Observation);
                        if Observation.Status /= Generation_Terminated
                          or else Observation.Snapshot.Generation /= Current_Generation (Retained_Current)
                          or else Observation.Snapshot.State /= Terminated
                        then
                           raise Program_Error
                             with
                               "newer terminal probe returned "
                               & Observation.Status'Image
                               & "/"
                               & Observation.Snapshot.State'Image
                               & " generation"
                               & Observation.Snapshot.Generation'Image
                               & " after"
                               & Current_Generation (Retained_Current)'Image;
                        end if;
                        Retained_Latest := Families.Latest (Item, Child (First));
                        Families.Start (Item, 2, Early_Reused);
                        Early_Reused_Started := True;
                        loop
                           exit when Families.Current (Item, Early_Reused).Live;
                           if Ada.Real_Time.Clock >= Deadline then
                              raise Program_Error with "early reused generation did not become live";
                           end if;
                           delay 0.001;
                        end loop;
                        Prepared.Activate_Exact
                          (Observation_Claim, Retained_Current, Timeout => 0.0, Operation => Wait);
                        Flyology.Operations.Wait_All (Set);
                        Prepared.Finish (Wait, Observation);
                        if Observation.Status /= Generation_Replaced
                          or else Observation.Snapshot.Generation /= Current_Generation (Retained_Latest)
                          or else Observation.Snapshot.State /= Joined
                        then
                           raise Program_Error with "reused slot replaced retained newer terminal evidence";
                        end if;
                     elsif Prove_Retained_Chain then
                        --  Let the dormant replacement fact be followed by
                        --  the terminal fact before either is consumed.
                        Prepared.Cancel_And_Join (Admission);
                        Ended_Before_Consumption := True;
                     end if;
                  end if;
                  if Expect_Replacement or else not Final_Already_Observed then
                     Prepared.Activate_Exact
                       (Observation_Claim, Current_Generation (First), Timeout => -1.0, Operation => Wait);
                     Flyology.Operations.Wait_All (Set);
                     Prepared.Finish (Wait, Observation);
                  end if;
               end if;

               if Expect_Replacement then
                  if Observation.Status /= Generation_Replaced then
                     raise Program_Error with "replacement rearm did not report replacement";
                  elsif Observation.Snapshot.Generation <= Current_Generation (First) then
                     raise Program_Error with "replacement rearm did not advance generation";
                  elsif not Ended_Before_Consumption and then Observation.Snapshot.State /= Starting then
                     raise Program_Error with "replacement rearm did not retain starting state";
                  elsif not Ended_Before_Consumption and then not Observation.Snapshot.Live then
                     raise Program_Error with "replacement rearm did not retain live state";
                  elsif Ended_Before_Consumption
                    and then (Observation.Snapshot.State /= Joined or else Observation.Snapshot.Live)
                  then
                     raise Program_Error with "retained replacement did not carry the terminal boundary";
                  end if;
                  declare
                     Current        : constant Child_Handle :=
                       (if Ended_Before_Consumption
                          or else Prove_Current_Boundary
                          or else Prove_Newer_Terminal
                        then Retained_Current
                        else Families.Latest (Item, Child (First)));
                     Reused         : Child_Handle;
                     Reused_Started : Boolean := False;

                     task Canceller is
                        entry Start;
                     end Canceller;

                     task body Canceller is
                     begin
                        select
                           accept Start;
                           Prepared.Cancel_And_Join (Admission);
                        or
                           terminate;
                        end select;
                     end Canceller;
                  begin
                     if Prove_Current_Boundary then
                        Families.Start (Item, 2, Reused);
                        Reused_Started := True;
                        loop
                           exit when Families.Current (Item, Reused).Live;
                           if Ada.Real_Time.Clock >= Deadline then
                              raise Program_Error
                                with "reused current-boundary generation did not become live";
                           end if;
                           delay 0.001;
                        end loop;
                     end if;
                     Prepared.Activate_Exact (Observation_Claim, Current, Timeout => -1.0, Operation => Wait);
                     if not Ended_Before_Consumption
                       and then not Prove_Current_Boundary
                       and then not Prove_Newer_Terminal
                     then
                        Canceller.Start;
                     end if;
                     Flyology.Operations.Wait_All (Set);
                     Prepared.Finish (Wait, Observation);
                     if Prove_Newer_Terminal then
                        if Observation.Status /= Generation_Replaced
                          or else Observation.Snapshot.Generation <= Current_Generation (Current)
                          or else Observation.Snapshot.State /= Joined
                        then
                           raise Program_Error
                             with "newer terminal marker did not preserve replacement order";
                        end if;
                     elsif Observation.Status /= Generation_Terminated
                       or else Observation.Snapshot.Generation /= Current_Generation (Current)
                     then
                        raise Program_Error
                          with "replacement generation was not observed to final completion";
                     end if;
                     if Prove_Newer_Terminal then
                        declare
                           Terminal_Current : constant Child_Handle := Retained_Latest;
                        begin
                           Reused := Early_Reused;
                           Reused_Started := Early_Reused_Started;
                           Prepared.Activate_Exact
                             (Observation_Claim, Terminal_Current, Timeout => -1.0, Operation => Wait);
                           Flyology.Operations.Wait_All (Set);
                           Prepared.Finish (Wait, Observation);
                           if Observation.Status /= Generation_Terminated
                             or else Observation.Snapshot.Generation /= Current_Generation (Terminal_Current)
                           then
                              raise Program_Error with "newer terminal marker was lost before slot reuse";
                           end if;
                        end;
                     end if;
                     if Prove_Current_Boundary or else Prove_Newer_Terminal then
                        declare
                           Ended_Handle : constant Child_Handle :=
                             (if Prove_Newer_Terminal then Retained_Latest else Current);
                           Ended        : Boolean := False;
                        begin
                           begin
                              Prepared.Activate_Exact
                                (Observation_Claim, Ended_Handle, Timeout => 0.0, Operation => Wait);
                           exception
                              when Families.Stale_Handle =>
                                 Ended := True;
                           end;
                           if not Ended then
                              raise Program_Error with "terminal claim did not enter ended state";
                           end if;
                        end;
                        declare
                           Stale : Boolean := False;
                        begin
                           begin
                              Prepared.Activate_Exact
                                (Observation_Claim,
                                 Current_Generation (Reused),
                                 Timeout   => 0.0,
                                 Operation => Wait);
                           exception
                              when Families.Stale_Handle =>
                                 Stale := True;
                           end;
                           if not Stale then
                              raise Program_Error with "ended observation claim crossed slot reuse";
                           end if;
                        end;
                     end if;
                     if Ended_Before_Consumption then
                        declare
                           Reused : Child_Handle;
                           Stale  : Boolean := False;
                        begin
                           Families.Start (Item, 2, Reused);
                           begin
                              Prepared.Activate_Exact
                                (Observation_Claim, Reused, Timeout => 0.0, Operation => Wait);
                           exception
                              when Families.Stale_Handle =>
                                 Stale := True;
                           end;
                           if not Stale then
                              raise Program_Error with "ended observation claim crossed admission slot reuse";
                           end if;
                        end;
                     end if;
                     if Reused_Started then
                        Families.Stop (Item, Reused);
                        Observation := Families.Wait_Termination (Item, Reused);
                        if Observation.Status /= Generation_Terminated then
                           raise Program_Error with "reused current-boundary witness did not terminate";
                        end if;
                     end if;
                  end;
               elsif Observation.Status /= Generation_Terminated then
                  raise Program_Error with "no-restart admission did not remain terminal";
               end if;
            end;
         end;

         if Prepared.Is_Active (Admission) then
            Prepared.Cancel_And_Join (Admission);
         end if;
         Prepared.Release_Observation_Claim (Observation_Claim);
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
   end Run_Case;

   procedure Positive_Backoff is new
     Run_Case
       (Restart                => On_Failure,
        Backoff                => Ada.Real_Time.Milliseconds (100),
        Expect_Replacement     => True,
        Prove_Pending          => True,
        Prove_Retained_Chain   => False,
        Prove_Current_Boundary => False,
        Prove_Newer_Terminal   => False);

   procedure Zero_Backoff is new
     Run_Case
       (Restart                => On_Failure,
        Backoff                => Ada.Real_Time.Time_Span_Zero,
        Expect_Replacement     => True,
        Prove_Pending          => False,
        Prove_Retained_Chain   => True,
        Prove_Current_Boundary => False,
        Prove_Newer_Terminal   => False);

   procedure Current_Boundary is new
     Run_Case
       (Restart                => On_Failure,
        Backoff                => Ada.Real_Time.Time_Span_Zero,
        Expect_Replacement     => True,
        Prove_Pending          => False,
        Prove_Retained_Chain   => False,
        Prove_Current_Boundary => True,
        Prove_Newer_Terminal   => False);

   procedure Newer_Terminal is new
     Run_Case
       (Restart                => On_Failure,
        Backoff                => Ada.Real_Time.Time_Span_Zero,
        Expect_Replacement     => True,
        Prove_Pending          => False,
        Prove_Retained_Chain   => False,
        Prove_Current_Boundary => False,
        Prove_Newer_Terminal   => True);

   procedure No_Restart is new
     Run_Case
       (Restart                => Never,
        Backoff                => Ada.Real_Time.Time_Span_Zero,
        Expect_Replacement     => False,
        Prove_Pending          => False,
        Prove_Retained_Chain   => False,
        Prove_Current_Boundary => False,
        Prove_Newer_Terminal   => False);
begin
   Positive_Backoff;
   Flyology.Task_Lifecycle_Testing.Reset;
   Zero_Backoff;
   Current_Boundary;
   Newer_Terminal;
   No_Restart;
end Prepared_Admission_Observation_Smoke;
