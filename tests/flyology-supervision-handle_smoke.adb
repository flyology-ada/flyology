with Ada.Real_Time;
with Flyology.Cancellation;
with Flyology.Supervision.Children;
with Flyology.Supervision.Static;

procedure Flyology.Supervision.Handle_Smoke is
   use type Ada.Real_Time.Time;

   type Service_Kind is (Only_Service);
   type Context is limited null record;

   function Logical_Id (Child : Service_Kind) return Child_Id is
     (case Child is when Only_Service => Child_Id'First);

   function Specification
     (Child : Service_Kind) return Child_Specification
   is
      pragma Unreferenced (Child);
   begin
      return
        (Restart           => On_Failure,
         Impact            => Isolate_Child,
         Recovery          => Default_Recovery_Limits,
         Stopping          => Default_Stop_Policy,
         Readiness_Timeout => Ada.Real_Time.Seconds (1),
         Restart_Safe      => True,
         Task_Model        => Native_Task,
         Has_Group         => False,
         Group             => 0);
   end Specification;

   function No_Relationship
     (Left, Right : Service_Kind) return Boolean
   is
      pragma Unreferenced (Left, Right);
   begin
      return False;
   end No_Relationship;

   procedure Execute
     (State   : in out Context;
      Control : not null access Generation_Control)
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

   package Generation is new Flyology.Supervision.Children
     (Application_Context => Context,
      Execute             => Execute,
      Task_Model          => Native_Task);

   procedure Run_Generation
     (State   : aliased in out Context;
      Child   : Service_Kind;
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result)
   is
      pragma Unreferenced (Child);
   begin
      Generation.Run (State, Control, Result);
   end Run_Generation;

   package Supervisors is new Flyology.Supervision.Static
     (Child_Kind          => Service_Kind,
      Application_Context => Context,
      Logical_Id          => Logical_Id,
      Specification       => Specification,
      Depends_On          => No_Relationship,
      Cohort_Member       => No_Relationship,
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

   Deadline : constant Ada.Real_Time.Time :=
     Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
   Default_Handle : Child_Handle;
begin
   Owner.Start;
   loop
      exit when Supervisors.Current (Item, Only_Service).Ready;
      if Ada.Real_Time.Clock >= Deadline then
         Supervisors.Request_Shutdown (Item);
         Owner.Join;
         raise Program_Error with "handle test child did not become ready";
      end if;
      delay 0.001;
   end loop;

   begin
      Supervisors.Restart (Item, Only_Service, Default_Handle);
      Supervisors.Request_Shutdown (Item);
      Owner.Join;
      raise Program_Error with
        "default child handle authorized the first live controller";
   exception
      when Supervisors.Stale_Handle => null;
   end;

   Supervisors.Request_Shutdown (Item);
   Owner.Join;
   pragma Assert (Result.Outcome = Shutdown_Completed);
end Flyology.Supervision.Handle_Smoke;
