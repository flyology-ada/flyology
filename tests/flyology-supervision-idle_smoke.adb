with Ada.Real_Time;
with Ada.Text_IO;
with Flyology.Cancellation;
with Flyology.Supervision.Children;
with Flyology.Supervision.Static;
with Interfaces.C;

procedure Flyology.Supervision.Idle_Smoke is
   use type Ada.Real_Time.Time;
   use type Interfaces.C.long;

   --  clock(3) reports process CPU ticks at 1,000,000 ticks per second on
   --  both supported Darwin and Linux hosts. The interval excludes startup
   --  and shutdown so it measures only an idle supervision tree.
   function Process_Clock return Interfaces.C.long;
   pragma Import (C, Process_Clock, "clock");

   type Context is limited null record;

   procedure Execute
     (State : in out Context; Control : not null access Generation_Control)
   is
      pragma Unreferenced (State);
   begin
      Mark_Ready (Control.all);
      Stopping (Control.all).Await_Request;
      raise Flyology.Cancellation.Operation_Cancelled;
   end Execute;

   package Native_Child is new
     Flyology.Supervision.Children
       (Application_Context => Context,
        Execute             => Execute,
        Task_Model          => Flyology.Native_Task);

   type Child_Kind is (First, Second);

   function Logical_Id (Child : Child_Kind) return Child_Id
   is (case Child is
         when First  => 17_200_001,
         when Second => 17_200_002);

   function Specification (Child : Child_Kind) return Child_Specification is
      pragma Unreferenced (Child);
   begin
      return
        (Restart           => Never,
         Impact            => Escalate,
         Recovery          => Default_Recovery_Limits,
         Stopping          => Default_Stop_Policy,
         Readiness_Timeout => Ada.Real_Time.Seconds (30),
         Restart_Safe      => False,
         Task_Model        => Flyology.Native_Task,
         Has_Group         => False,
         Group             => 0);
   end Specification;

   function Unrelated (Left, Right : Child_Kind) return Boolean is
      pragma Unreferenced (Left, Right);
   begin
      return False;
   end Unrelated;

   procedure Run_Generation
     (State   : aliased in out Context;
      Child   : Child_Kind;
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result)
   is
      pragma Unreferenced (Child);
   begin
      Native_Child.Run (State, Control, Result);
   end Run_Generation;

   package Supervisors is new
     Flyology.Supervision.Static
       (Child_Kind          => Child_Kind,
        Application_Context => Context,
        Logical_Id          => Logical_Id,
        Specification       => Specification,
        Depends_On          => Unrelated,
        Cohort_Member       => Unrelated,
        Run_One_Generation  => Run_Generation);

   State  : aliased Context;
   Item   : aliased Supervisors.Supervisor;
   Result : Supervisor_Result;

   task Owner is
      entry Start;
      entry Join;
   end Owner;

   task body Owner is
   begin
      accept Start;
      Supervisors.Run (Item, State, Result);
      accept Join;
   end Owner;

   Deadline  : constant Ada.Real_Time.Time :=
     Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
   Start_CPU : Interfaces.C.long;
   End_CPU   : Interfaces.C.long;
begin
   Owner.Start;
   loop
      exit when
        Supervisors.Current (Item, First).Ready
        and then Supervisors.Current (Item, Second).Ready;
      if Ada.Real_Time.Clock >= Deadline then
         Supervisors.Request_Shutdown (Item);
         Owner.Join;
         raise Program_Error with "idle supervision tree did not become ready";
      end if;
      delay 0.001;
   end loop;

   Start_CPU := Process_Clock;
   delay 3.0;
   End_CPU := Process_Clock;
   Supervisors.Request_Shutdown (Item);
   Owner.Join;
   if Result.Outcome /= Shutdown_Completed then
      raise Program_Error with "idle supervision tree did not shut down";
   elsif Start_CPU < 0 or else End_CPU < Start_CPU then
      raise Program_Error with "process CPU clock failed";
   elsif End_CPU - Start_CPU > 50_000 then
      raise Program_Error
        with "idle supervision consumed more than 50 ms of process CPU";
   end if;
   Ada.Text_IO.Put_Line
     ("idle supervision CPU ticks:"
      & Interfaces.C.long'Image (End_CPU - Start_CPU));
end Flyology.Supervision.Idle_Smoke;
