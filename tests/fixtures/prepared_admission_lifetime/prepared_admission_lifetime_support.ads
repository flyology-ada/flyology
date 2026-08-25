with Ada.Real_Time;
with Flyology.Operations;
with Flyology.Supervision;
with Flyology.Supervision.Families;
with Flyology.Supervision.Families.Prepared_Admissions;

package Prepared_Admission_Lifetime_Support is
   use Flyology.Supervision;

   type Request is new Positive;
   type Context is limited null record;

   procedure Run_Generation
     (State   : aliased in out Context;
      Input   : Request;
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result);

   Policy : constant Child_Specification :=
     (Restart           => Never,
      Impact            => Isolate_Child,
      Recovery          => Default_Recovery_Limits,
      Stopping          => Default_Stop_Policy,
      Readiness_Timeout => Ada.Real_Time.Seconds (1),
      Restart_Safe      => True,
      Task_Model        => Flyology.Native_Task,
      Has_Group         => False,
      Group             => 0);

   package Families is new
     Flyology.Supervision.Families
       (Request             => Request,
        Application_Context => Context,
        Run_One_Generation  => Run_Generation,
        Policy              => Policy,
        First_Child_Id      => 45_000_000_000,
        Maximum_Children    => 1,
        Event_Capacity      => 4,
        Monitor_Capacity    => 1);

   package Prepared is new
     Families.Prepared_Admissions
       (Request_Assignment_And_Cleanup_Are_Nonraising => True);

   Global_Family : aliased Families.Family;
   Global_Set    : aliased Flyology.Operations.Completion_Set (1);
end Prepared_Admission_Lifetime_Support;
