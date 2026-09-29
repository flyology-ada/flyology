with Ada.Real_Time;
with Flyology.Supervision.Static;

--  This program must not compile. CPU value zero requests automatic Ada task
--  placement, so it cannot name the supervisor's dedicated shared control
--  group. The generic formal subtype rejects it before any task can activate.

procedure Invalid_Supervision_Control_Group is
   type Child_Kind is (Service);
   type Context is limited null record;

   function Logical_Id (Child : Child_Kind) return Flyology.Supervision.Child_Id
   is (case Child is
         when Service => 1);

   function Specification (Child : Child_Kind) return Flyology.Supervision.Child_Specification is
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
   end Specification;

   function No_Relationship (Left, Right : Child_Kind) return Boolean is
      pragma Unreferenced (Left, Right);
   begin
      return False;
   end No_Relationship;

   procedure Run_Generation
     (State   : aliased in out Context;
      Child   : Child_Kind;
      Control : aliased in out Flyology.Supervision.Generation_Control;
      Result  : out Flyology.Supervision.Generation_Result)
   is
      pragma Unreferenced (State, Child, Control, Result);
   begin
      raise Program_Error;
   end Run_Generation;

   package Invalid_Supervisor is new
     Flyology.Supervision.Static
       (Child_Kind          => Child_Kind,
        Application_Context => Context,
        Logical_Id          => Logical_Id,
        Specification       => Specification,
        Depends_On          => No_Relationship,
        Cohort_Member       => No_Relationship,
        Run_One_Generation  => Run_Generation,
        Control_Group       => 0);
begin
   null;
end Invalid_Supervision_Control_Group;
