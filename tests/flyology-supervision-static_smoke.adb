with Ada.Real_Time;
with Ada.Task_Identification;
with Flyology.Cancellation;
with Flyology.Supervision.Children;
with Flyology.Supervision.Static;
with Flyology.Supervision.Task_Generations;
with System.Multiprocessors;

procedure Flyology.Supervision.Static_Smoke is
   use type Ada.Real_Time.Time;
   use type Ada.Task_Identification.Task_Id;
   use type Flyology.Execution_Model;
   use type Flyology.Supervision.Generation;

   Test_Failure : exception;

   protected type Restart_State is
      procedure Begin_Generation
        (Attempt : out Positive;
         Identity : Ada.Task_Identification.Task_Id);
      procedure Request_Failure;
      procedure Take_Failure (Requested : out Boolean);
      function Attempts return Natural;
      function First_Task return Ada.Task_Identification.Task_Id;
      function Second_Task return Ada.Task_Identification.Task_Id;
   private
      Count  : Natural := 0;
      First  : Ada.Task_Identification.Task_Id :=
        Ada.Task_Identification.Null_Task_Id;
      Second : Ada.Task_Identification.Task_Id :=
        Ada.Task_Identification.Null_Task_Id;
      Failure_Pending : Boolean := False;
   end Restart_State;

   protected body Restart_State is
      procedure Begin_Generation
        (Attempt : out Positive;
         Identity : Ada.Task_Identification.Task_Id) is
      begin
         Count := Count + 1;
         Attempt := Count;
         if Count = 1 then
            First := Identity;
         elsif Count = 2 then
            Second := Identity;
         end if;
      end Begin_Generation;

      procedure Request_Failure is
      begin
         Failure_Pending := True;
      end Request_Failure;

      procedure Take_Failure (Requested : out Boolean) is
      begin
         Requested := Failure_Pending;
         Failure_Pending := False;
      end Take_Failure;

      function Attempts return Natural is (Count);
      function First_Task return Ada.Task_Identification.Task_Id is (First);
      function Second_Task return Ada.Task_Identification.Task_Id is (Second);
   end Restart_State;

   type Restart_Context is limited record
      State : Restart_State;
   end record;

   procedure Execute_Restartable
     (Context : in out Restart_Context;
      Control : not null access Flyology.Supervision.Generation_Control)
   is
      Attempt : Positive;
      Fail    : Boolean;
   begin
      Context.State.Begin_Generation
        (Attempt, Ada.Task_Identification.Current_Task);
      Flyology.Supervision.Mark_Ready (Control.all);
      if Attempt <= 2 then
         raise Test_Failure with "replacement generation fails";
      end if;
      loop
         Context.State.Take_Failure (Fail);
         if Fail then
            raise Test_Failure with "stable generation fails";
         end if;
         if Flyology.Supervision.Stopping (Control.all).Requested then
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
         delay 0.001;
      end loop;
   end Execute_Restartable;

   task type Restart_Task
     (State   : not null access Restart_Context;
      Control : not null access Flyology.Supervision.Generation_Control)
   with CPU => System.Multiprocessors.Not_A_Specific_CPU is
      pragma Task_Info (Flyology.Native_Task);
      entry Start;
   end Restart_Task;

   task body Restart_Task is
   begin
      accept Start;
      Execute_Restartable (State.all, Control);
   end Restart_Task;

   function Create_Restart
     (State   : not null access Restart_Context;
      Control : not null access Flyology.Supervision.Generation_Control)
      return Restart_Task
   is
   begin
      return Subject : Restart_Task (State, Control);
   end Create_Restart;

   procedure Initialize_Restart
     (Subject : in out Restart_Task;
      Control : aliased in out Flyology.Supervision.Generation_Control)
   is
      pragma Unreferenced (Control);
   begin
      Subject.Start;
   end Initialize_Restart;

   function Restart_Identity
     (Subject : in out Restart_Task)
      return Ada.Task_Identification.Task_Id is
     (Subject'Identity);

   procedure Abort_Restart (Subject : in out Restart_Task) is
   begin
      abort Subject;
   end Abort_Restart;

   package Restart_Child is new Flyology.Supervision.Task_Generations
     (Application_Context => Restart_Context,
      Generation_Task     => Restart_Task,
      Create              => Create_Restart,
      Initialize          => Initialize_Restart,
      Task_Identity       => Restart_Identity,
      Abort_Task          => Abort_Restart);

   type Restart_Kind is (Service);

   Restart_Recovery : constant Flyology.Supervision.Recovery_Limits :=
     (Burst_Attempts    => 3,
      Window            => Ada.Real_Time.Seconds (1),
      Total_Attempts    => 3,
      Initial_Backoff   => Ada.Real_Time.Milliseconds (1),
      Maximum_Backoff   => Ada.Real_Time.Milliseconds (2),
      Stability_Reset   => Ada.Real_Time.Milliseconds (50),
      Recovery_Deadline => Ada.Real_Time.Milliseconds (100));

   function Restart_Id
     (Child : Restart_Kind) return Flyology.Supervision.Child_Id is
     (case Child is when Service => 4_294_967_297);

   function Restart_Specification
     (Child : Restart_Kind)
      return Flyology.Supervision.Child_Specification
   is
      pragma Unreferenced (Child);
   begin
      return
        (Restart           => Flyology.Supervision.On_Failure,
         Impact            => Flyology.Supervision.Isolate_Child,
         Recovery          => Restart_Recovery,
         Stopping          =>
           (Grace             => Ada.Real_Time.Seconds (1),
            Request_Abort     => False,
            Abort_Observation => Ada.Real_Time.Seconds (1)),
         Readiness_Timeout => Ada.Real_Time.Seconds (1),
         Restart_Safe      => True,
         Task_Model        => Flyology.Native_Task,
         Has_Group         => False,
         Group             => 0);
   end Restart_Specification;

   function No_Restart_Dependency
     (Child        : Restart_Kind;
      Prerequisite : Restart_Kind) return Boolean is
   begin
      pragma Unreferenced (Child, Prerequisite);
      return False;
   end No_Restart_Dependency;

   procedure Run_Restart_Generation
     (Context : aliased in out Restart_Context;
      Child   : Restart_Kind;
      Control : aliased in out Flyology.Supervision.Generation_Control;
      Result  : out Flyology.Supervision.Generation_Result)
   is
      pragma Unreferenced (Child);
   begin
      Restart_Child.Run (Context, Control, Result);
   end Run_Restart_Generation;

   function Restart_Cohort
     (Trigger : Restart_Kind;
      Member  : Restart_Kind) return Boolean
   is
      pragma Unreferenced (Trigger, Member);
   begin
      return True;
   end Restart_Cohort;

   package Restart_Supervisors is new Flyology.Supervision.Static
     (Child_Kind         => Restart_Kind,
      Application_Context => Restart_Context,
      Logical_Id         => Restart_Id,
      Specification      => Restart_Specification,
      Depends_On         => No_Restart_Dependency,
      Cohort_Member      => Restart_Cohort,
      Run_One_Generation => Run_Restart_Generation,
      Subtree_Recovery   => Restart_Recovery);

   Exhausted_Recovery : constant Flyology.Supervision.Recovery_Limits :=
     (Burst_Attempts    => 1,
      Window            => Ada.Real_Time.Seconds (1),
      Total_Attempts    => 1,
      Initial_Backoff   => Ada.Real_Time.Milliseconds (1),
      Maximum_Backoff   => Ada.Real_Time.Milliseconds (1),
      Stability_Reset   => Ada.Real_Time.Seconds (1),
      Recovery_Deadline => Ada.Real_Time.Seconds (1));

   function Exhausted_Specification
     (Child : Restart_Kind)
      return Flyology.Supervision.Child_Specification
   is
      pragma Unreferenced (Child);
      Value : Flyology.Supervision.Child_Specification :=
        Restart_Specification (Service);
   begin
      Value.Recovery := Exhausted_Recovery;
      return Value;
   end Exhausted_Specification;

   package Exhausted_Supervisors is new Flyology.Supervision.Static
     (Child_Kind          => Restart_Kind,
      Application_Context => Restart_Context,
      Logical_Id          => Restart_Id,
      Specification       => Exhausted_Specification,
      Depends_On          => No_Restart_Dependency,
      Cohort_Member       => Restart_Cohort,
      Run_One_Generation  => Run_Restart_Generation,
      Subtree_Recovery    => Exhausted_Recovery);

   type Event_Array is array (Positive range 1 .. 16) of Positive;

   protected type Event_Log is
      procedure Append (Value : Positive);
      function Length return Natural;
      function Element (Index : Positive) return Positive;
   private
      Count  : Natural := 0;
      Events : Event_Array := (others => 1);
   end Event_Log;

   protected body Event_Log is
      procedure Append (Value : Positive) is
      begin
         Count := Count + 1;
         Events (Count) := Value;
      end Append;

      function Length return Natural is (Count);

      function Element (Index : Positive) return Positive is
        (Events (Index));
   end Event_Log;

   protected type Dependency_Fault is
      procedure Request;
      procedure Take (Requested : out Boolean);
   private
      Pending : Boolean := False;
   end Dependency_Fault;

   protected body Dependency_Fault is
      procedure Request is
      begin
         Pending := True;
      end Request;

      procedure Take (Requested : out Boolean) is
      begin
         Requested := Pending;
         Pending := False;
      end Take;
   end Dependency_Fault;

   type Dependency_Context is limited record
      Log : Event_Log;
      Fault : Dependency_Fault;
   end record;

   procedure Run_Service
     (Context : in out Dependency_Context;
      Control : not null access Flyology.Supervision.Generation_Control;
      Number  : Positive)
   is
      Fail : Boolean;
   begin
      Context.Log.Append (Number);
      Flyology.Supervision.Mark_Ready (Control.all);
      loop
         if Number = 1 then
            Context.Fault.Take (Fail);
            if Fail then
               raise Test_Failure with "prerequisite generation failed";
            end if;
         end if;
         if Flyology.Supervision.Stopping (Control.all).Requested then
            Context.Log.Append (Number + 2);
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
         delay 0.001;
      end loop;
   end Run_Service;

   procedure Execute_Prerequisite
     (Context : in out Dependency_Context;
      Control : not null access Flyology.Supervision.Generation_Control) is
   begin
      Run_Service (Context, Control, 1);
   end Execute_Prerequisite;

   procedure Execute_Dependent
     (Context : in out Dependency_Context;
      Control : not null access Flyology.Supervision.Generation_Control) is
   begin
      Run_Service (Context, Control, 2);
   end Execute_Dependent;

   package Prerequisite_Child is new Flyology.Supervision.Children
     (Application_Context => Dependency_Context,
      Execute             => Execute_Prerequisite,
      Task_Model          => Flyology.Native_Task);
   package Dependent_Child is new Flyology.Supervision.Children
     (Application_Context => Dependency_Context,
      Execute             => Execute_Dependent,
      Task_Model          => Flyology.Native_Task);

   type Dependency_Kind is (Prerequisite, Dependent);

   function Dependency_Id
     (Child : Dependency_Kind) return Flyology.Supervision.Child_Id is
     (Flyology.Supervision.Child_Id
        (Dependency_Kind'Pos (Child) + 9_000_000_000));

   function Dependency_Specification
     (Child : Dependency_Kind)
      return Flyology.Supervision.Child_Specification
   is
   begin
      return
        (Restart           =>
           (if Child = Prerequisite
            then Flyology.Supervision.On_Failure
            else Flyology.Supervision.Never),
         Impact            =>
           (if Child = Prerequisite
            then Flyology.Supervision.Restart_Dependents
            else Flyology.Supervision.Escalate),
         Recovery          => Flyology.Supervision.Default_Recovery_Limits,
         Stopping          => Flyology.Supervision.Default_Stop_Policy,
         Readiness_Timeout => Ada.Real_Time.Seconds (1),
         Restart_Safe      => True,
         Task_Model        => Flyology.Native_Task,
         Has_Group         => False,
         Group             => 0);
   end Dependency_Specification;

   function Dependency
     (Child        : Dependency_Kind;
      Prerequisite : Dependency_Kind) return Boolean is
     (Child = Dependent and then Prerequisite = Dependency_Kind'First);

   procedure Run_Dependency_Generation
     (Context : aliased in out Dependency_Context;
      Child   : Dependency_Kind;
      Control : aliased in out Flyology.Supervision.Generation_Control;
      Result  : out Flyology.Supervision.Generation_Result) is
   begin
      case Child is
         when Prerequisite =>
            Prerequisite_Child.Run (Context, Control, Result);
         when Dependent =>
            Dependent_Child.Run (Context, Control, Result);
      end case;
   end Run_Dependency_Generation;

   function Dependency_Cohort
     (Trigger : Dependency_Kind;
      Member  : Dependency_Kind) return Boolean is
     (Trigger = Member);

   package Dependency_Supervisors is new Flyology.Supervision.Static
     (Child_Kind         => Dependency_Kind,
      Application_Context => Dependency_Context,
      Logical_Id         => Dependency_Id,
      Specification      => Dependency_Specification,
      Depends_On         => Dependency,
      Cohort_Member      => Dependency_Cohort,
      Run_One_Generation => Run_Dependency_Generation,
      Event_Capacity     => 16);

   function Cohort_Specification
     (Child : Dependency_Kind)
      return Flyology.Supervision.Child_Specification
   is
      Value : Flyology.Supervision.Child_Specification :=
        Dependency_Specification (Child);
   begin
      if Child = Prerequisite then
         Value.Impact := Flyology.Supervision.Restart_Cohort;
      end if;
      return Value;
   end Cohort_Specification;

   function Whole_Cohort
     (Trigger : Dependency_Kind;
      Member  : Dependency_Kind) return Boolean
   is
      pragma Unreferenced (Trigger, Member);
   begin
      return True;
   end Whole_Cohort;

   package Cohort_Supervisors is new Flyology.Supervision.Static
     (Child_Kind         => Dependency_Kind,
      Application_Context => Dependency_Context,
      Logical_Id         => Dependency_Id,
      Specification      => Cohort_Specification,
      Depends_On         => Dependency,
      Cohort_Member      => Whole_Cohort,
      Run_One_Generation => Run_Dependency_Generation);

   type Edge_Mode is (Readiness_Case, Stuck_Case);
   type Edge_Context (Mode : Edge_Mode) is limited null record;

   procedure Execute_Edge
     (Context : in out Edge_Context;
      Control : not null access Flyology.Supervision.Generation_Control) is
   begin
      case Context.Mode is
         when Readiness_Case =>
            loop
               if Flyology.Supervision.Stopping (Control.all).Requested then
                  raise Flyology.Cancellation.Operation_Cancelled;
               end if;
               delay 0.001;
            end loop;
         when Stuck_Case =>
            Flyology.Supervision.Mark_Ready (Control.all);
            --  Deliberately ignore cancellation longer than both diagnostic
            --  stop intervals, then return so the structured scope can join.
            delay 0.05;
      end case;
   end Execute_Edge;

   package Edge_Child is new Flyology.Supervision.Children
     (Application_Context => Edge_Context,
      Execute             => Execute_Edge,
      Task_Model          => Flyology.Native_Task);

   type Edge_Kind is (Edge_Service);

   function Edge_Id
     (Child : Edge_Kind) return Flyology.Supervision.Child_Id is
     (case Child is when Edge_Service => 18_446_744_073_709_551_000);

   function Readiness_Specification
     (Child : Edge_Kind) return Flyology.Supervision.Child_Specification
   is
      pragma Unreferenced (Child);
   begin
      return
        (Restart           => Flyology.Supervision.Never,
         Impact            => Flyology.Supervision.Escalate,
         Recovery          => Flyology.Supervision.Default_Recovery_Limits,
         Stopping          => Flyology.Supervision.Default_Stop_Policy,
         Readiness_Timeout => Ada.Real_Time.Milliseconds (5),
         Restart_Safe      => False,
         Task_Model        => Flyology.Native_Task,
         Has_Group         => False,
         Group             => 0);
   end Readiness_Specification;

   function Stuck_Specification
     (Child : Edge_Kind) return Flyology.Supervision.Child_Specification
   is
      pragma Unreferenced (Child);
   begin
      return
        (Restart           => Flyology.Supervision.Never,
         Impact            => Flyology.Supervision.Escalate,
         Recovery          => Flyology.Supervision.Default_Recovery_Limits,
         Stopping          =>
           (Grace             => Ada.Real_Time.Milliseconds (1),
            Request_Abort     => False,
            Abort_Observation => Ada.Real_Time.Milliseconds (1)),
         Readiness_Timeout => Ada.Real_Time.Seconds (1),
         Restart_Safe      => False,
         Task_Model        => Flyology.Native_Task,
         Has_Group         => False,
         Group             => 0);
   end Stuck_Specification;

   function Default_Model_Specification
     (Child : Edge_Kind) return Flyology.Supervision.Child_Specification
   is
      Value : Flyology.Supervision.Child_Specification :=
        Readiness_Specification (Child);
   begin
      Value.Task_Model := Flyology.Project_Default;
      return Value;
   end Default_Model_Specification;

   function No_Edge_Dependency
     (Child        : Edge_Kind;
      Prerequisite : Edge_Kind) return Boolean is
   begin
      pragma Unreferenced (Child, Prerequisite);
      return False;
   end No_Edge_Dependency;

   procedure Run_Edge_Generation
     (Context : aliased in out Edge_Context;
      Child   : Edge_Kind;
      Control : aliased in out Flyology.Supervision.Generation_Control;
      Result  : out Flyology.Supervision.Generation_Result)
   is
      pragma Unreferenced (Child);
   begin
      Edge_Child.Run (Context, Control, Result);
   end Run_Edge_Generation;

   function Edge_Cohort
     (Trigger : Edge_Kind;
      Member  : Edge_Kind) return Boolean
   is
      pragma Unreferenced (Trigger, Member);
   begin
      return True;
   end Edge_Cohort;

   package Readiness_Supervisors is new Flyology.Supervision.Static
     (Child_Kind         => Edge_Kind,
      Application_Context => Edge_Context,
      Logical_Id         => Edge_Id,
      Specification      => Readiness_Specification,
      Depends_On         => No_Edge_Dependency,
      Cohort_Member      => Edge_Cohort,
      Run_One_Generation => Run_Edge_Generation);

   package Stuck_Supervisors is new Flyology.Supervision.Static
     (Child_Kind         => Edge_Kind,
      Application_Context => Edge_Context,
      Logical_Id         => Edge_Id,
      Specification      => Stuck_Specification,
      Depends_On         => No_Edge_Dependency,
      Cohort_Member      => Edge_Cohort,
      Run_One_Generation => Run_Edge_Generation);

   package Default_Model_Supervisors is new Flyology.Supervision.Static
     (Child_Kind         => Edge_Kind,
      Application_Context => Edge_Context,
      Logical_Id         => Edge_Id,
      Specification      => Default_Model_Specification,
      Depends_On         => No_Edge_Dependency,
      Cohort_Member      => Edge_Cohort,
      Run_One_Generation => Run_Edge_Generation);

   procedure Run_Activation_Failure
     (Context : aliased in out Edge_Context;
      Child   : Edge_Kind;
      Control : aliased in out Flyology.Supervision.Generation_Control;
      Result  : out Flyology.Supervision.Generation_Result)
   is
      pragma Unreferenced (Context, Child, Control, Result);
   begin
      raise Tasking_Error with "injected generation activation failure";
   end Run_Activation_Failure;

   package Activation_Supervisors is new Flyology.Supervision.Static
     (Child_Kind         => Edge_Kind,
      Application_Context => Edge_Context,
      Logical_Id         => Edge_Id,
      Specification      => Readiness_Specification,
      Depends_On         => No_Edge_Dependency,
      Cohort_Member      => Edge_Cohort,
      Run_One_Generation => Run_Activation_Failure);

   type Inner_Context is limited null record;
   type Nested_Context is limited record
      Inner : aliased Inner_Context;
   end record;
   type Nested_Kind is (Nested_Service);

   function Nested_Id
     (Child : Nested_Kind) return Flyology.Supervision.Child_Id is
     (case Child is when Nested_Service => 12_000_000_001);

   function Nested_Specification
     (Child : Nested_Kind) return Flyology.Supervision.Child_Specification
   is
      pragma Unreferenced (Child);
   begin
      return
        (Restart           => Flyology.Supervision.Never,
         Impact            => Flyology.Supervision.Escalate,
         Recovery          => Flyology.Supervision.Default_Recovery_Limits,
         Stopping          => Flyology.Supervision.Default_Stop_Policy,
         Readiness_Timeout => Ada.Real_Time.Seconds (1),
         Restart_Safe      => False,
         Task_Model        => Flyology.Native_Task,
         Has_Group         => False,
         Group             => 0);
   end Nested_Specification;

   function No_Nested_Dependency
     (Child        : Nested_Kind;
      Prerequisite : Nested_Kind) return Boolean
   is
      pragma Unreferenced (Child, Prerequisite);
   begin
      return False;
   end No_Nested_Dependency;

   function Nested_Cohort
     (Trigger : Nested_Kind;
      Member  : Nested_Kind) return Boolean
   is
      pragma Unreferenced (Trigger, Member);
   begin
      return True;
   end Nested_Cohort;

   procedure Execute_Inner_Failure
     (Context : in out Inner_Context;
      Control : not null access Flyology.Supervision.Generation_Control)
   is
      pragma Unreferenced (Context);
   begin
      Flyology.Supervision.Mark_Ready (Control.all);
      raise Test_Failure with "nested child failure";
   end Execute_Inner_Failure;

   package Inner_Child is new Flyology.Supervision.Children
     (Application_Context => Inner_Context,
      Execute             => Execute_Inner_Failure,
      Task_Model          => Flyology.Native_Task);

   procedure Run_Inner_Generation
     (Context : aliased in out Inner_Context;
      Child   : Nested_Kind;
      Control : aliased in out Flyology.Supervision.Generation_Control;
      Result  : out Flyology.Supervision.Generation_Result)
   is
      pragma Unreferenced (Child);
   begin
      Inner_Child.Run (Context, Control, Result);
   end Run_Inner_Generation;

   package Inner_Supervisors is new Flyology.Supervision.Static
     (Child_Kind         => Nested_Kind,
      Application_Context => Inner_Context,
      Logical_Id         => Nested_Id,
      Specification      => Nested_Specification,
      Depends_On         => No_Nested_Dependency,
      Cohort_Member      => Nested_Cohort,
      Run_One_Generation => Run_Inner_Generation);

   procedure Execute_Outer
     (Context : in out Nested_Context;
      Control : not null access Flyology.Supervision.Generation_Control)
   is
      Item   : aliased Inner_Supervisors.Supervisor;
      Result : Flyology.Supervision.Supervisor_Result;
   begin
      Flyology.Supervision.Mark_Ready (Control.all);
      Inner_Supervisors.Run_Nested
        (Item, Context.Inner, Control.all, Result);
      raise Test_Failure with "nested supervisor escalated";
   end Execute_Outer;

   package Outer_Child is new Flyology.Supervision.Children
     (Application_Context => Nested_Context,
      Execute             => Execute_Outer,
      Task_Model          => Flyology.Native_Task);

   procedure Run_Outer_Generation
     (Context : aliased in out Nested_Context;
      Child   : Nested_Kind;
      Control : aliased in out Flyology.Supervision.Generation_Control;
      Result  : out Flyology.Supervision.Generation_Result)
   is
      pragma Unreferenced (Child);
   begin
      Outer_Child.Run (Context, Control, Result);
   end Run_Outer_Generation;

   package Outer_Supervisors is new Flyology.Supervision.Static
     (Child_Kind         => Nested_Kind,
      Application_Context => Nested_Context,
      Logical_Id         => Nested_Id,
      Specification      => Nested_Specification,
      Depends_On         => No_Nested_Dependency,
      Cohort_Member      => Nested_Cohort,
      Run_One_Generation => Run_Outer_Generation);

begin
   declare
      Context : aliased Restart_Context;
      Item    : aliased Restart_Supervisors.Supervisor;
      Result  : Flyology.Supervision.Supervisor_Result;

      task Owner is
         entry Start;
         entry Join;
      end Owner;

      task body Owner is
      begin
         accept Start;
         Restart_Supervisors.Run (Item, Context, Result);
         accept Join;
      end Owner;

      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
      Events  : Flyology.Supervision.Supervisor_Event_Array (1 .. 32);
      Cursor  : Flyology.Supervision.Event_Sequence := 0;
      Count   : Natural;
      Dropped : Flyology.Supervision.Event_Sequence;
      Admitted : Natural := 0;
      Recovery_Incident : Flyology.Supervision.Incident_Id :=
        Flyology.Supervision.Incident_Id'First;
   begin
      Owner.Start;
      loop
         exit when Restart_Supervisors.Current (Item, Service).Ready
           and then
             Restart_Supervisors.Current (Item, Service).Generation = 3;
         if Ada.Real_Time.Clock >= Deadline then
            Restart_Supervisors.Request_Shutdown (Item);
            Owner.Join;
            raise Program_Error with
              "restart supervisor did not publish generation three; attempts="
              & Context.State.Attempts'Image
              & ", generation="
              & Restart_Supervisors.Current
                  (Item, Service).Generation'Image
              & ", state="
              & Restart_Supervisors.Current (Item, Service).State'Image
              & ", outcome=" & Result.Outcome'Image
              & ", termination=" & Result.Termination.Kind'Image
              & ", message="
              & Result.Termination.Message
                  (1 .. Result.Termination.Message_Length);
         end if;
         delay 0.001;
      end loop;
      delay 0.150;
      Context.State.Request_Failure;
      loop
         exit when Restart_Supervisors.Current (Item, Service).Ready
           and then
             Restart_Supervisors.Current (Item, Service).Generation = 4;
         if Ada.Real_Time.Clock >= Deadline then
            Restart_Supervisors.Request_Shutdown (Item);
            Owner.Join;
            raise Program_Error with
              "stable failure did not start a fresh incident";
         end if;
         delay 0.001;
      end loop;
      Restart_Supervisors.Read_Events
        (Item, Cursor, Events, Count, Dropped);
      pragma Assert (Dropped = 0);
      for Index in 1 .. Count loop
         pragma Assert
           (Events (Index).Task_Model = Flyology.Native_Task);
         if Events (Index).Kind = Flyology.Supervision.Restart_Admitted then
            Admitted := Admitted + 1;
            if Admitted = 1 then
               Recovery_Incident :=
                 Flyology.Supervision.Incident (Events (Index).Incident);
               pragma Assert
                 (Flyology.Supervision.Attempt (Events (Index).Incident) = 1);
            elsif Admitted = 2 then
               pragma Assert
                 (Flyology.Supervision.Incident (Events (Index).Incident) =
                    Recovery_Incident);
               pragma Assert
                 (Flyology.Supervision.Attempt (Events (Index).Incident) = 2);
            elsif Admitted = 3 then
               pragma Assert
                 (Flyology.Supervision.Incident (Events (Index).Incident) /=
                    Recovery_Incident);
               pragma Assert
                 (Flyology.Supervision.Attempt (Events (Index).Incident) = 1);
            end if;
         end if;
      end loop;
      pragma Assert (Admitted = 3);
      Restart_Supervisors.Request_Shutdown (Item);
      Owner.Join;
      pragma Assert
        (Result.Outcome = Flyology.Supervision.Shutdown_Completed);
      pragma Assert (Context.State.Attempts = 4);
      pragma Assert
        (Context.State.First_Task /= Ada.Task_Identification.Null_Task_Id);
      pragma Assert
        (Context.State.Second_Task /= Ada.Task_Identification.Null_Task_Id);
      pragma Assert
        (Restart_Supervisors.Current (Item, Service).State =
           Flyology.Supervision.Joined);
   end;

   declare
      Context : aliased Restart_Context;
      Item    : aliased Exhausted_Supervisors.Supervisor;
      Result  : Flyology.Supervision.Supervisor_Result;
      Current : Flyology.Supervision.Child_Snapshot;
   begin
      Exhausted_Supervisors.Run (Item, Context, Result);
      Current := Exhausted_Supervisors.Current (Item, Service);
      pragma Assert
        (Result.Outcome = Flyology.Supervision.Recovery_Exhausted);
      pragma Assert
        (Result.Termination.Kind = Flyology.Supervision.Policy_Exhaustion);
      pragma Assert (Flyology.Supervision.Active (Result.Incident));
      pragma Assert
        (Flyology.Supervision.Attempt (Result.Incident) = 2);
      pragma Assert (Context.State.Attempts = 2);
      pragma Assert
        (Current.State = Flyology.Supervision.Joined
         and then Current.Termination.Kind =
           Flyology.Supervision.Policy_Exhaustion);
   end;

   declare
      Context : aliased Dependency_Context;
      Item    : aliased Dependency_Supervisors.Supervisor;
      Result  : Flyology.Supervision.Supervisor_Result;

      task Owner is
         entry Start;
         entry Join;
      end Owner;

      task body Owner is
      begin
         accept Start;
         Dependency_Supervisors.Run (Item, Context, Result);
         accept Join;
      end Owner;

      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
      Events  : Flyology.Supervision.Supervisor_Event_Array (1 .. 16);
      Cursor  : Flyology.Supervision.Event_Sequence := 0;
      Count   : Natural;
      Dropped : Flyology.Supervision.Event_Sequence;
      Saw_Admitted  : Boolean := False;
      Saw_Completed : Boolean := False;
   begin
      Owner.Start;
      loop
         exit when
           Dependency_Supervisors.Current (Item, Prerequisite).Ready
           and then Dependency_Supervisors.Current (Item, Dependent).Ready;
         if Ada.Real_Time.Clock >= Deadline then
            Dependency_Supervisors.Request_Shutdown (Item);
            Owner.Join;
            raise Program_Error with
              "dependency supervisor did not complete startup";
         end if;
         delay 0.001;
      end loop;
      Context.Fault.Request;
      loop
         exit when
           Dependency_Supervisors.Current (Item, Prerequisite).Ready
           and then Dependency_Supervisors.Current (Item, Dependent).Ready
           and then
             Dependency_Supervisors.Current (Item, Prerequisite).Generation = 2
           and then
             Dependency_Supervisors.Current (Item, Dependent).Generation = 2;
         if Ada.Real_Time.Clock >= Deadline then
            Dependency_Supervisors.Request_Shutdown (Item);
            Owner.Join;
            raise Program_Error with
              "dependent recovery did not publish generation two";
         end if;
         delay 0.001;
      end loop;
      Dependency_Supervisors.Read_Events
        (Item, Cursor, Events, Count, Dropped);
      pragma Assert (Dropped = 0);
      for Index in 1 .. Count loop
         Saw_Admitted :=
           Saw_Admitted or else
             Events (Index).Kind = Flyology.Supervision.Restart_Admitted;
         Saw_Completed :=
           Saw_Completed or else
             Events (Index).Kind = Flyology.Supervision.Restart_Completed;
      end loop;
      pragma Assert (Saw_Admitted and then Saw_Completed);
      Dependency_Supervisors.Request_Shutdown (Item);
      Owner.Join;
      pragma Assert
        (Result.Outcome = Flyology.Supervision.Shutdown_Completed);
      pragma Assert (Context.Log.Length = 7);
      pragma Assert (Context.Log.Element (1) = 1);
      pragma Assert (Context.Log.Element (2) = 2);
      pragma Assert (Context.Log.Element (3) = 4);
      pragma Assert (Context.Log.Element (4) = 1);
      pragma Assert (Context.Log.Element (5) = 2);
      pragma Assert (Context.Log.Element (6) = 4);
      pragma Assert (Context.Log.Element (7) = 3);
   end;

   declare
      Context : aliased Dependency_Context;
      Item    : aliased Cohort_Supervisors.Supervisor;
      Result  : Flyology.Supervision.Supervisor_Result;

      task Owner is
         entry Start;
         entry Join;
      end Owner;

      task body Owner is
      begin
         accept Start;
         Cohort_Supervisors.Run (Item, Context, Result);
         accept Join;
      end Owner;

      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
   begin
      Owner.Start;
      loop
         exit when Cohort_Supervisors.Current (Item, Prerequisite).Ready
           and then Cohort_Supervisors.Current (Item, Dependent).Ready;
         if Ada.Real_Time.Clock >= Deadline then
            Cohort_Supervisors.Request_Shutdown (Item);
            Owner.Join;
            raise Program_Error with "cohort startup did not complete";
         end if;
         delay 0.001;
      end loop;
      Context.Fault.Request;
      loop
         exit when Cohort_Supervisors.Current (Item, Prerequisite).Ready
           and then Cohort_Supervisors.Current (Item, Dependent).Ready
           and then Cohort_Supervisors.Current
             (Item, Prerequisite).Generation = 2
           and then Cohort_Supervisors.Current
             (Item, Dependent).Generation = 2;
         if Ada.Real_Time.Clock >= Deadline then
            Cohort_Supervisors.Request_Shutdown (Item);
            Owner.Join;
            raise Program_Error with "cohort recovery did not complete";
         end if;
         delay 0.001;
      end loop;
      Cohort_Supervisors.Request_Shutdown (Item);
      Owner.Join;
      pragma Assert
        (Result.Outcome = Flyology.Supervision.Shutdown_Completed);
      pragma Assert (Context.Log.Length = 7);
      pragma Assert (Context.Log.Element (1) = 1);
      pragma Assert (Context.Log.Element (2) = 2);
      pragma Assert (Context.Log.Element (3) = 4);
      pragma Assert (Context.Log.Element (4) = 1);
      pragma Assert (Context.Log.Element (5) = 2);
      pragma Assert (Context.Log.Element (6) = 4);
      pragma Assert (Context.Log.Element (7) = 3);
   end;

   declare
      Context : aliased Nested_Context;
      Item    : aliased Outer_Supervisors.Supervisor;
      Result  : Flyology.Supervision.Supervisor_Result;
   begin
      Outer_Supervisors.Run (Item, Context, Result);
      pragma Assert
        (Result.Outcome = Flyology.Supervision.Failure_Escalated);
      pragma Assert (Flyology.Supervision.Active (Result.Incident));
      pragma Assert
        (Flyology.Supervision.Attempt (Result.Incident) = 1);
   end;

   declare
      Context : aliased Edge_Context (Readiness_Case);
      Item    : aliased Readiness_Supervisors.Supervisor;
      Result  : Flyology.Supervision.Supervisor_Result;
   begin
      Readiness_Supervisors.Run (Item, Context, Result);
      pragma Assert
        (Result.Outcome = Flyology.Supervision.Startup_Failed);
      pragma Assert
        (Result.Termination.Kind = Flyology.Supervision.Readiness_Timeout);
      pragma Assert
        (Readiness_Supervisors.Current (Item, Edge_Service).State =
           Flyology.Supervision.Joined);
      pragma Assert
        (Readiness_Supervisors.Current
           (Item, Edge_Service).Task_Model = Flyology.Native_Task);
   end;

   declare
      Context : aliased Edge_Context (Readiness_Case);
      Item    : aliased Default_Model_Supervisors.Supervisor;
      Result  : Flyology.Supervision.Supervisor_Result;
   begin
      begin
         Default_Model_Supervisors.Run (Item, Context, Result);
         raise Program_Error with "Project_Default task model was accepted";
      exception
         when Default_Model_Supervisors.Configuration_Error => null;
      end;
   end;

   declare
      Context : aliased Edge_Context (Stuck_Case);
      Item    : aliased Stuck_Supervisors.Supervisor;
      Result  : Flyology.Supervision.Supervisor_Result;

      task Owner is
         entry Start;
         entry Join;
      end Owner;

      task body Owner is
      begin
         accept Start;
         Stuck_Supervisors.Run (Item, Context, Result);
         accept Join;
      end Owner;

      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
   begin
      Owner.Start;
      loop
         exit when Stuck_Supervisors.Current (Item, Edge_Service).Ready;
         if Ada.Real_Time.Clock >= Deadline then
            Stuck_Supervisors.Request_Shutdown (Item);
            Owner.Join;
            raise Program_Error with "stuck test did not become ready";
         end if;
         delay 0.001;
      end loop;
      Stuck_Supervisors.Request_Shutdown (Item);
      Owner.Join;
      pragma Assert (Result.Outcome = Flyology.Supervision.Child_Stuck);
      pragma Assert
        (Stuck_Supervisors.Current (Item, Edge_Service).State =
           Flyology.Supervision.Joined);
   end;

   declare
      Context : aliased Edge_Context (Readiness_Case);
      Item    : aliased Activation_Supervisors.Supervisor;
      Result  : Flyology.Supervision.Supervisor_Result;
   begin
      Activation_Supervisors.Run (Item, Context, Result);
      pragma Assert
        (Result.Outcome = Flyology.Supervision.Startup_Failed);
      pragma Assert
        (Result.Termination.Kind = Flyology.Supervision.Activation_Failure);
   end;
end Flyology.Supervision.Static_Smoke;
