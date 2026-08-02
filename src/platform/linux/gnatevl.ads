with System.Task_Info;

package Gnatevl with Preelaborate is

   subtype Execution_Model is System.Task_Info.Task_Info_Type;

   Event_Loop_Task : constant Execution_Model :=
     null;

   Native_Thread : constant Execution_Model;

private
   Native_Thread_Attributes : aliased System.Task_Info.Thread_Attributes;

   Native_Thread : constant Execution_Model :=
     Native_Thread_Attributes'Access;

end Gnatevl;
