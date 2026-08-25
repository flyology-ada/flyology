--  Enabled task-lifecycle test control selected by the owning project.

private package Flyology.Task_Lifecycle_Test_Hooks is
   pragma Preelaborate;

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := True;

   type Barrier_Point is
     (Static_Monitor_Registered,
      Family_Monitor_Registered,
      Task_Result_Attached,
      Task_Result_Retained);

   --  Reset barriers and reference accounting while no test operation is active.
   procedure Reset;
   procedure Arm (Point : Barrier_Point);
   procedure Barrier (Point : Barrier_Point);
   function Reached (Point : Barrier_Point) return Boolean;
   procedure Release (Point : Barrier_Point);

   procedure Note_Reference_Acquired;
   procedure Note_Reference_Released;
   function Outstanding_References return Natural;

end Flyology.Task_Lifecycle_Test_Hooks;
