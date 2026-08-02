with System.Task_Info;

package Flyology with Preelaborate is

   subtype Execution_Model is System.Task_Info.Task_Info_Type;

   Project_Default : constant Execution_Model :=
     null;

   Lightweight_Task : constant Execution_Model;

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
