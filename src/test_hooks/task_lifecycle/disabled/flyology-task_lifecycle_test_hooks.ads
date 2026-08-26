--  Disabled task-lifecycle test seams selected by the owning project. The
--  imported-only declarations make a missed static guard visible to symbol
--  inspection without supplying any production implementation.

private package Flyology.Task_Lifecycle_Test_Hooks is
   pragma Preelaborate;

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := False;

   type Barrier_Point is
     (Static_Monitor_Registered,
      Family_Monitor_Registered,
      Prepared_Admission_Reserved,
      Prepared_Admission_Published,
      Prepared_Admission_Committed,
      Prepared_Admission_Released,
      Admission_Monitor_Registered,
      Admission_Immediate_Claimed,
      Admission_Before_Replacement,
      Admission_Before_Manager_Done,
      Admission_Signal_Claimed,
      Admission_Signal_Interrupted,
      Admission_Signal_Finalizing,
      Task_Result_Attached,
      Task_Result_Retained);

   procedure Reset
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_task_lifecycle_reset";
   procedure Arm (Point : Barrier_Point)
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_task_lifecycle_arm";
   procedure Barrier (Point : Barrier_Point)
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_task_lifecycle_barrier";
   function Reached (Point : Barrier_Point) return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_task_lifecycle_reached";
   procedure Release (Point : Barrier_Point)
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_task_lifecycle_release";
   procedure Note_Reference_Acquired
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_task_lifecycle_acquire";
   procedure Note_Reference_Released
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_task_lifecycle_release_reference";
   function Outstanding_References return Natural
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_task_lifecycle_outstanding";
   procedure Force_Next_Prepared_Generation_Final
   with
     Import,
     External_Name => "flyology_disabled_hook_must_be_elided_task_lifecycle_prepared_generation_arm";
   function Consume_Prepared_Generation_Final return Boolean
   with
     Import,
     External_Name => "flyology_disabled_hook_must_be_elided_task_lifecycle_prepared_generation_consume";
   procedure Interrupt_Next_Admission_Signal
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_task_lifecycle_signal_interrupt";
   function Consume_Admission_Signal_Interrupted return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_task_lifecycle_signal_consume";

end Flyology.Task_Lifecycle_Test_Hooks;
