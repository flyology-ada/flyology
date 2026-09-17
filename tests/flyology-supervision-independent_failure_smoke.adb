with Ada.Real_Time;
with Flyology.Cancellation;
with Flyology.Supervision.Children;
with Flyology.Supervision.Static;

procedure Flyology.Supervision.Independent_Failure_Smoke is
   use type Ada.Real_Time.Time;
   use type Flyology.Supervision.Generation;

   type Recovery_Window is (Stop_Window, Backoff_Window, Start_Window);

   generic
      Model : Flyology.Execution_Model;
      Independent_Restart : Restart_Kind := On_Failure;
      Independent_Impact : Restart_Impact := Isolate_Child;
      Blocks_Recovery : Boolean := False;
   package Scenario is
      procedure Run (Window : Recovery_Window);
   end Scenario;

   package body Scenario is
      type Child_Kind is (First, Independent, Cohort);
      type Counts is array (Child_Kind) of Natural;
      type Flags is array (Child_Kind) of Boolean;

      protected type State is
         procedure Started (Child : Child_Kind; Number : out Natural);
         procedure Fail (Child : Child_Kind);
         procedure Take_Failure (Child : Child_Kind; Requested : out Boolean);
         procedure Hold (Stop : Boolean);
         procedure Release;
         procedure Observe_Stop;
         function Stop_Observed return Boolean;
         function Can_Stop return Boolean;
         function Can_Ready return Boolean;
         function Starts (Child : Child_Kind) return Natural;
      private
         Started_Count : Counts := (others => 0);
         Failure       : Flags := (others => False);
         Stop_Held     : Boolean := False;
         Ready_Held    : Boolean := False;
         Saw_Stop      : Boolean := False;
      end State;

      protected body State is
         procedure Started (Child : Child_Kind; Number : out Natural) is
         begin
            Started_Count (Child) := Started_Count (Child) + 1;
            Number := Started_Count (Child);
         end Started;

         procedure Fail (Child : Child_Kind) is
         begin
            Failure (Child) := True;
         end Fail;

         procedure Take_Failure (Child : Child_Kind; Requested : out Boolean)
         is
         begin
            Requested := Failure (Child);
            Failure (Child) := False;
         end Take_Failure;

         procedure Hold (Stop : Boolean) is
         begin
            Stop_Held := Stop;
            Ready_Held := not Stop;
         end Hold;

         procedure Release is
         begin
            Stop_Held := False;
            Ready_Held := False;
         end Release;

         procedure Observe_Stop is
         begin
            Saw_Stop := True;
         end Observe_Stop;

         function Stop_Observed return Boolean
         is (Saw_Stop);
         function Can_Stop return Boolean
         is (not Stop_Held);
         function Can_Ready return Boolean
         is (not Ready_Held);
         function Starts (Child : Child_Kind) return Natural
         is (Started_Count (Child));
      end State;

      type Context is limited record
         Current : State;
      end record;

      procedure Execute
        (Context : in out Scenario.Context;
         Control : not null access Generation_Control;
         Child   : Child_Kind)
      is
         Number : Natural;
         Failed : Boolean;
      begin
         Context.Current.Started (Child, Number);
         if Child = Cohort and then Number = 2 then
            while not Context.Current.Can_Ready loop
               delay 0.001;
            end loop;
         end if;
         Mark_Ready (Control.all);
         loop
            Context.Current.Take_Failure (Child, Failed);
            if Failed then
               raise Program_Error with "injected independent failure";
            end if;
            if Stop_Requested (Control.all) then
               if Child = Cohort then
                  Context.Current.Observe_Stop;
                  while not Context.Current.Can_Stop loop
                     delay 0.001;
                  end loop;
               end if;
               raise Flyology.Cancellation.Operation_Cancelled;
            end if;
            delay 0.001;
         end loop;
      end Execute;

      procedure Execute_First
        (Context : in out Scenario.Context;
         Control : not null access Generation_Control) is
      begin
         Execute (Context, Control, First);
      end Execute_First;

      procedure Execute_Independent
        (Context : in out Scenario.Context;
         Control : not null access Generation_Control) is
      begin
         Execute (Context, Control, Independent);
      end Execute_Independent;

      procedure Execute_Cohort
        (Context : in out Scenario.Context;
         Control : not null access Generation_Control) is
      begin
         Execute (Context, Control, Cohort);
      end Execute_Cohort;

      package First_Child is new
        Flyology.Supervision.Children
          (Application_Context => Context,
           Execute             => Execute_First,
           Task_Model          => Model);
      package Independent_Child is new
        Flyology.Supervision.Children
          (Application_Context => Context,
           Execute             => Execute_Independent,
           Task_Model          => Model);
      package Cohort_Child is new
        Flyology.Supervision.Children
          (Application_Context => Context,
           Execute             => Execute_Cohort,
           Task_Model          => Model);

      function Id (Child : Child_Kind) return Child_Id
      is (Child_Id (20_000_000_000 + Child_Kind'Pos (Child)));

      Limits : constant Recovery_Limits :=
        (Burst_Attempts    => 4,
         Window            => Ada.Real_Time.Seconds (10),
         Total_Attempts    => 4,
         Initial_Backoff   => Ada.Real_Time.Milliseconds (10),
         Maximum_Backoff   => Ada.Real_Time.Milliseconds (10),
         Stability_Reset   => Ada.Real_Time.Seconds (1),
         Recovery_Deadline => Ada.Real_Time.Seconds (5));

      function Child_Recovery (Child : Child_Kind) return Recovery_Limits is
         Result : Recovery_Limits := Limits;
      begin
         if Child = First then
            Result.Initial_Backoff := Ada.Real_Time.Seconds (1);
            Result.Maximum_Backoff := Ada.Real_Time.Seconds (1);
         end if;
         return Result;
      end Child_Recovery;

      function Specification (Child : Child_Kind) return Child_Specification is
      begin
         return
           (Restart           =>
              (if Child = Independent
               then Independent_Restart
               else On_Failure),
            Impact            =>
              (if Child = First
               then
                 (if Blocks_Recovery
                  then Restart_Dependents
                  else Restart_Cohort)
               elsif Child = Independent
               then Independent_Impact
               else Isolate_Child),
            Recovery          => Child_Recovery (Child),
            Stopping          =>
              (Grace             => Ada.Real_Time.Seconds (2),
               Request_Abort     => False,
               Abort_Observation => Ada.Real_Time.Seconds (2)),
            Readiness_Timeout => Ada.Real_Time.Seconds (2),
            Restart_Safe      => True,
            Task_Model        => Model,
            Has_Group         => False,
            Group             => 0);
      end Specification;

      function Dependency (Left, Right : Child_Kind) return Boolean
      is (Blocks_Recovery
          and then Left = Cohort
          and then Right in First | Independent);

      function Cohort_Member (Trigger, Member : Child_Kind) return Boolean
      is (Trigger in First | Cohort and then Member in First | Cohort);

      procedure Run_Generation
        (Context : aliased in out Scenario.Context;
         Child   : Child_Kind;
         Control : aliased in out Generation_Control;
         Result  : out Generation_Result) is
      begin
         case Child is
            when First       =>
               First_Child.Run (Context, Control, Result);

            when Independent =>
               Independent_Child.Run (Context, Control, Result);

            when Cohort      =>
               Cohort_Child.Run (Context, Control, Result);
         end case;
      end Run_Generation;

      package Supervisors is new
        Flyology.Supervision.Static
          (Child_Kind          => Child_Kind,
           Application_Context => Context,
           Logical_Id          => Id,
           Specification       => Specification,
           Depends_On          => Dependency,
           Cohort_Member       => Cohort_Member,
           Run_One_Generation  => Run_Generation,
           Subtree_Recovery    => Limits);

      procedure Run (Window : Recovery_Window) is
         Data   : aliased Context;
         Item   : aliased Supervisors.Supervisor;
         Result : Supervisor_Result;

         task Owner is
            entry Start;
            entry Join;
         end Owner;

         task body Owner is
         begin
            accept Start;
            Supervisors.Run (Item, Data, Result);
            accept Join;
         end Owner;

         Deadline : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.Seconds (8);

         procedure Stop_And_Raise (Message : String) is
         begin
            Data.Current.Release;
            Supervisors.Request_Shutdown (Item);
            begin
               Owner.Join;
            exception
               when Tasking_Error =>
                  null;
            end;
            raise Program_Error with Message;
         end Stop_And_Raise;
      begin
         Owner.Start;
         loop
            exit when
              Supervisors.Current (Item, First).Ready
              and then Supervisors.Current (Item, Independent).Ready
              and then Supervisors.Current (Item, Cohort).Ready;
            if Ada.Real_Time.Clock >= Deadline then
               Stop_And_Raise ("independent failure startup timed out");
            end if;
            delay 0.001;
         end loop;
         Data.Current.Hold (Window = Stop_Window);
         Data.Current.Fail (First);
         loop
            exit when
              (case Window is
                 when Stop_Window    => Data.Current.Stop_Observed,
                 when Backoff_Window =>
                   Supervisors.Current (Item, First).State = Backing_Off
                   and then not Supervisors.Current (Item, Cohort).Live,
                 when Start_Window   =>
                   Data.Current.Starts (Cohort) = 2
                   and then not Supervisors.Current (Item, Cohort).Ready);
            if Ada.Real_Time.Clock >= Deadline then
               Stop_And_Raise ("recovery phase was not reached");
            end if;
            delay 0.001;
         end loop;
         Data.Current.Fail (Independent);
         loop
            exit when not Supervisors.Current (Item, Independent).Live;
            if Ada.Real_Time.Clock >= Deadline then
               Stop_And_Raise ("independent failure was not published");
            end if;
            delay 0.001;
         end loop;
         if Data.Current.Starts (Independent) /= 1 then
            Stop_And_Raise
              ("independent child restarted before active recovery finished");
         end if;
         if Blocks_Recovery then
            if not Supervisors.Current (Item, Independent).Escalated then
               Stop_And_Raise
                 ("failed prerequisite did not stop dependent recovery");
            end if;
            Data.Current.Release;
            Owner.Join;
            if Result.Outcome /= Failure_Escalated then
               raise Program_Error with "failed prerequisite did not escalate";
            end if;
            return;
         end if;
         if Supervisors.Current (Item, Independent).Escalated then
            Stop_And_Raise
              ("independent failure escalated during active recovery");
         end if;
         Data.Current.Release;
         if Independent_Restart = Never or else Independent_Impact = Escalate
         then
            Owner.Join;
            if Result.Outcome /= Failure_Escalated
              or else Result.Child /= Id (Independent)
            then
               raise Program_Error
                 with "pending failure ignored its own terminal policy";
            end if;
            return;
         end if;
         loop
            exit when
              Supervisors.Current (Item, First).Ready
              and then Supervisors.Current (Item, Independent).Ready
              and then Supervisors.Current (Item, Cohort).Ready
              and then Supervisors.Current (Item, First).Generation = 2
              and then Supervisors.Current (Item, Independent).Generation = 2
              and then Supervisors.Current (Item, Cohort).Generation = 2;
            if Ada.Real_Time.Clock >= Deadline then
               Stop_And_Raise ("queued independent child did not recover");
            end if;
            delay 0.001;
         end loop;
         Supervisors.Request_Shutdown (Item);
         Owner.Join;
         if Result.Outcome /= Shutdown_Completed then
            raise Program_Error with "independent failure escalated";
         end if;
      end Run;
   end Scenario;

   package Native is new Scenario (Flyology.Native_Task);
   package Lightweight is new Scenario (Flyology.Lightweight_Task);
   package Never_Restart is new
     Scenario (Flyology.Native_Task, Never, Escalate);
   package Escalating is new
     Scenario (Flyology.Native_Task, On_Failure, Escalate);
   package Related is new
     Scenario (Flyology.Native_Task, On_Failure, Restart_Dependents, True);
begin
   Native.Run (Stop_Window);
   Native.Run (Backoff_Window);
   Native.Run (Start_Window);
   Lightweight.Run (Stop_Window);
   Lightweight.Run (Backoff_Window);
   Lightweight.Run (Start_Window);
   Never_Restart.Run (Stop_Window);
   Escalating.Run (Start_Window);
   Related.Run (Start_Window);
end Flyology.Supervision.Independent_Failure_Smoke;
