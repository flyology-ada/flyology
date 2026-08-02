with System.Task_Info;

package Gnatevl with Preelaborate is

   subtype Execution_Model is System.Task_Info.Task_Info_Type;

   Project_Default : constant Execution_Model :=
     null;

   Event_Loop_Task : constant Execution_Model;

   Native_Thread : constant Execution_Model;

private
   Event_Loop_Attributes : aliased System.Task_Info.Thread_Attributes;
   pragma Import
     (C, Event_Loop_Attributes, "__gnatevl_event_loop_task_attributes");

   Native_Thread_Attributes : aliased System.Task_Info.Thread_Attributes;

   Event_Loop_Task : constant Execution_Model :=
     Event_Loop_Attributes'Access;

   Native_Thread : constant Execution_Model :=
     Native_Thread_Attributes'Access;

end Gnatevl;
