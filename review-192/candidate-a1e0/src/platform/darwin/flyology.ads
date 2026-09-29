with System.Task_Info;

--  Selects the execution model used when an Ada task is activated.
--
--  Example:
--
--     task Worker with CPU => 1 is
--        pragma Task_Info (Flyology.Lightweight_Task);
--     end Worker;

package Flyology
  with Preelaborate
is

   --  Execution designation accepted by pragma Task_Info. The designation is
   --  fixed when a task is activated and cannot be changed afterwards.
   subtype Execution_Model is System.Task_Info.Task_Info_Type;

   --  Use the project-wide default selected while preparing the runtime. The
   --  compatibility default is Native_Task unless FLYOLOGY_DEFAULT changes it.
   Project_Default : constant Execution_Model := System.Task_Info.Unspecified_Task_Info;

   --  Run the task cooperatively on an event loop. A CPU aspect in 1 .. 127
   --  selects that shared execution group. Ada reserves CPU 0 as
   --  Not_A_Specific_CPU, so it selects the configured pool exactly as an
   --  absent aspect does.
   Lightweight_Task : constant Execution_Model := System.Task_Info.Process_Scope;

   --  Run the task on its own GNARL-managed native thread. A CPU aspect keeps
   --  its normal Ada processor-affinity meaning.
   Native_Task : constant Execution_Model := System.Task_Info.System_Scope;

end Flyology;
