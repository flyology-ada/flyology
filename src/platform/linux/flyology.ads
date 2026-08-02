with System.Task_Info;

--  Selects the execution model used when an Ada task is activated.
--
--  Example:
--
--     task Worker with CPU => 1 is
--        pragma Task_Info (Flyology.Lightweight_Task);
--     end Worker;
package Flyology with Preelaborate is

   --  Execution designation accepted by pragma Task_Info. The designation is
   --  fixed when a task is activated and cannot be changed afterwards.
   subtype Execution_Model is System.Task_Info.Task_Info_Type;

   --  Use the project-wide default selected while preparing the runtime. The
   --  compatibility default is Native_Task unless FLYOLOGY_DEFAULT changes it.
   Project_Default : constant Execution_Model :=
     null;

   --  Run the task cooperatively on an event loop. A CPU aspect in 0 .. 127
   --  selects that shared execution group; no CPU selects the configured pool.
   Lightweight_Task : constant Execution_Model;

   --  Run the task on its own GNARL-managed native thread. A CPU aspect keeps
   --  its normal Ada processor-affinity meaning.
   Native_Task : constant Execution_Model;

private
   Event_Loop_Attributes : aliased System.Task_Info.Thread_Attributes;
   pragma Import
     (C, Event_Loop_Attributes, "__flyology_event_loop_task_attributes");

   Native_Task_Attributes : aliased System.Task_Info.Thread_Attributes;

   Lightweight_Task : constant Execution_Model :=
     Event_Loop_Attributes'Access;

   Native_Task : constant Execution_Model :=
     Native_Task_Attributes'Access;

end Flyology;
