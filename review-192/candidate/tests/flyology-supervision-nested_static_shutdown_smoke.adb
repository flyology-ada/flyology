with Ada.Real_Time;
with Flyology.Cancellation;
with Flyology.Supervision.Children;
with Flyology.Supervision.Static;

procedure Flyology.Supervision.Nested_Static_Shutdown_Smoke is
   use type Ada.Real_Time.Time;

   protected type Counts is
      procedure Begin_Inner;
      procedure End_Inner;
      function Starts return Natural;
      function Stops return Natural;
   private
      Started : Natural := 0;
      Stopped : Natural := 0;
   end Counts;

   protected body Counts is
      procedure Begin_Inner is
      begin
         Started := Started + 1;
      end Begin_Inner;

      procedure End_Inner is
      begin
         Stopped := Stopped + 1;
      end End_Inner;

      function Starts return Natural
      is (Started);
      function Stops return Natural
      is (Stopped);
   end Counts;

   type Inner_Context is limited record
      Observed : Counts;
   end record;

   type Context is limited record
      Inner : aliased Inner_Context;
   end record;

   procedure Execute_Inner (State : in out Inner_Context; Control : not null access Generation_Control) is
   begin
      State.Observed.Begin_Inner;
      Mark_Ready (Control.all);
      loop
         if Stop_Requested (Control.all) then
            State.Observed.End_Inner;
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
         delay 0.001;
      end loop;
   end Execute_Inner;

   package Inner_Child is new
     Flyology.Supervision.Children
       (Application_Context => Inner_Context,
        Execute             => Execute_Inner,
        Task_Model          => Flyology.Native_Task);

   type Inner_Kind is (Only_Inner);

   function Inner_Id (Child : Inner_Kind) return Child_Id
   is (case Child is
         when Only_Inner => 14_000_000_000);

   function Inner_Specification (Child : Inner_Kind) return Child_Specification is
      pragma Unreferenced (Child);
   begin
      return
        (Restart           => Never,
         Impact            => Escalate,
         Recovery          => Default_Recovery_Limits,
         Stopping          => Default_Stop_Policy,
         Readiness_Timeout => Ada.Real_Time.Seconds (1),
         Restart_Safe      => False,
         Task_Model        => Flyology.Native_Task,
         Has_Group         => False,
         Group             => 0);
   end Inner_Specification;

   function No_Relationship (Left, Right : Inner_Kind) return Boolean is
      pragma Unreferenced (Left, Right);
   begin
      return False;
   end No_Relationship;

   procedure Run_Inner_Generation
     (State   : aliased in out Inner_Context;
      Child   : Inner_Kind;
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result)
   is
      pragma Unreferenced (Child);
   begin
      Inner_Child.Run (State, Control, Result);
   end Run_Inner_Generation;

   package Inner_Supervisors is new
     Flyology.Supervision.Static
       (Child_Kind          => Inner_Kind,
        Application_Context => Inner_Context,
        Logical_Id          => Inner_Id,
        Specification       => Inner_Specification,
        Depends_On          => No_Relationship,
        Cohort_Member       => No_Relationship,
        Run_One_Generation  => Run_Inner_Generation);

   procedure Execute_Outer (State : in out Context; Control : not null access Generation_Control) is
      Item   : aliased Inner_Supervisors.Supervisor;
      Result : Supervisor_Result;
   begin
      Mark_Ready (Control.all);
      Inner_Supervisors.Run_Nested (Item, State.Inner, Control.all, Result);
      if Result.Outcome /= Shutdown_Completed then
         raise Program_Error with "nested static shutdown failed";
      end if;
   end Execute_Outer;

   package Outer_Child is new
     Flyology.Supervision.Children
       (Application_Context => Context,
        Execute             => Execute_Outer,
        Task_Model          => Flyology.Native_Task);

   type Outer_Kind is (Only_Outer);

   function Outer_Id (Child : Outer_Kind) return Child_Id
   is (case Child is
         when Only_Outer => 15_000_000_000);

   function Outer_Specification (Child : Outer_Kind) return Child_Specification is
      pragma Unreferenced (Child);
   begin
      return
        (Restart           => Never,
         Impact            => Escalate,
         Recovery          => Default_Recovery_Limits,
         Stopping          =>
           (Grace             => Ada.Real_Time.Seconds (1),
            Request_Abort     => False,
            Abort_Observation => Ada.Real_Time.Seconds (1)),
         Readiness_Timeout => Ada.Real_Time.Seconds (1),
         Restart_Safe      => False,
         Task_Model        => Flyology.Native_Task,
         Has_Group         => False,
         Group             => 0);
   end Outer_Specification;

   procedure Run_Outer_Generation
     (State   : aliased in out Context;
      Child   : Outer_Kind;
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result)
   is
      pragma Unreferenced (Child);
   begin
      Outer_Child.Run (State, Control, Result);
   end Run_Outer_Generation;

   function No_Outer_Relationship (Left, Right : Outer_Kind) return Boolean is
      pragma Unreferenced (Left, Right);
   begin
      return False;
   end No_Outer_Relationship;

   package Outer_Supervisors is new
     Flyology.Supervision.Static
       (Child_Kind          => Outer_Kind,
        Application_Context => Context,
        Logical_Id          => Outer_Id,
        Specification       => Outer_Specification,
        Depends_On          => No_Outer_Relationship,
        Cohort_Member       => No_Outer_Relationship,
        Run_One_Generation  => Run_Outer_Generation);

   State  : aliased Context;
   Item   : aliased Outer_Supervisors.Supervisor;
   Result : Supervisor_Result;

   task Owner is
      entry Start;
      entry Join;
   end Owner;

   task body Owner is
   begin
      accept Start;
      Outer_Supervisors.Run (Item, State, Result);
      accept Join;
   end Owner;

   Deadline : constant Ada.Real_Time.Time := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (3);
begin
   Owner.Start;
   loop
      exit when Outer_Supervisors.Current (Item, Only_Outer).Ready and then State.Inner.Observed.Starts = 1;
      if Ada.Real_Time.Clock >= Deadline then
         raise Program_Error with "nested static child did not start";
      end if;
      delay 0.001;
   end loop;

   Outer_Supervisors.Request_Shutdown (Item);
   Owner.Join;
   pragma Assert (Result.Outcome = Shutdown_Completed);
   pragma Assert (State.Inner.Observed.Starts = 1);
   pragma Assert (State.Inner.Observed.Stops = 1);
exception
   when others =>
      Outer_Supervisors.Request_Shutdown (Item);
      select
         Owner.Join;
      or
         delay 3.0;
      end select;
      raise;
end Flyology.Supervision.Nested_Static_Shutdown_Smoke;
