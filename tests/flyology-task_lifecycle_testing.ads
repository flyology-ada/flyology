--  Exposes deterministic task-lifecycle fault points to runtime tests.
--  Applications should not depend on this child package.
--  @exclude

package Flyology.Task_Lifecycle_Testing is

   type Barrier_Point is
     (Static_Monitor_Registered,
      Family_Monitor_Registered,
      Task_Result_Attached,
      Task_Result_Retained);

   procedure Reset;
   procedure Arm (Point : Barrier_Point);
   procedure Wait_Reached (Point : Barrier_Point);
   procedure Release (Point : Barrier_Point);
   function Outstanding_References return Natural;

end Flyology.Task_Lifecycle_Testing;
