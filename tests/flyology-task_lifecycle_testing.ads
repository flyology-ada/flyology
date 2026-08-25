--  Exposes deterministic task-lifecycle fault points to runtime tests.
--  Applications should not depend on this child package.
--  @exclude
package Flyology.Task_Lifecycle_Testing is

   type Barrier_Point is
     (Static_Monitor_Registered,
      Family_Monitor_Registered,
      Prepared_Admission_Reserved,
      Prepared_Admission_Published,
      Prepared_Admission_Committed,
      Prepared_Admission_Released,
      Admission_Monitor_Registered,
      Admission_Before_Manager_Done,
      Admission_Signal_Claimed,
      Admission_Signal_Interrupted,
      Admission_Signal_Finalizing,
      Task_Result_Attached,
      Task_Result_Retained);

   procedure Reset;
   procedure Arm (Point : Barrier_Point);
   procedure Wait_Reached (Point : Barrier_Point);
   procedure Release (Point : Barrier_Point);
   function Outstanding_References return Natural;
   procedure Force_Next_Prepared_Generation_Final;
   procedure Interrupt_Next_Admission_Signal;

end Flyology.Task_Lifecycle_Testing;
