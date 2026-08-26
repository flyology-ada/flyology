with Ada.Real_Time;
with Flyology.Task_Lifecycle_Test_Hooks;

package body Flyology.Task_Lifecycle_Testing is

   use type Ada.Real_Time.Time;

   package Test_Hooks renames Flyology.Task_Lifecycle_Test_Hooks;

   function Convert (Point : Barrier_Point) return Test_Hooks.Barrier_Point
   is (Test_Hooks.Barrier_Point'Val (Barrier_Point'Pos (Point)));

   procedure Reset is
   begin
      Test_Hooks.Reset;
   end Reset;

   procedure Arm (Point : Barrier_Point) is
   begin
      Test_Hooks.Arm (Convert (Point));
   end Arm;

   procedure Wait_Reached (Point : Barrier_Point) is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
   begin
      while not Test_Hooks.Reached (Convert (Point)) loop
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "task-lifecycle barrier was not reached";
         end if;
         delay 0.001;
      end loop;
   end Wait_Reached;

   procedure Release (Point : Barrier_Point) is
   begin
      Test_Hooks.Release (Convert (Point));
   end Release;

   function Outstanding_References return Natural
   is (Test_Hooks.Outstanding_References);

   procedure Force_Next_Prepared_Generation_Final is
   begin
      Test_Hooks.Force_Next_Prepared_Generation_Final;
   end Force_Next_Prepared_Generation_Final;

   procedure Force_Next_Prepared_Monitor_Identity_Exhausted is
   begin
      Test_Hooks.Force_Next_Prepared_Monitor_Identity_Exhausted;
   end Force_Next_Prepared_Monitor_Identity_Exhausted;

   procedure Interrupt_Next_Admission_Signal is
   begin
      Test_Hooks.Interrupt_Next_Admission_Signal;
   end Interrupt_Next_Admission_Signal;

end Flyology.Task_Lifecycle_Testing;
