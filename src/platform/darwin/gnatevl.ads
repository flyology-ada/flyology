with System.Task_Info;

package Gnatevl with Preelaborate is

   subtype Execution_Model is System.Task_Info.Task_Info_Type;

   Project_Default : constant Execution_Model :=
     System.Task_Info.Unspecified_Task_Info;

   Event_Loop_Task : constant Execution_Model :=
     System.Task_Info.Process_Scope;

   Native_Thread : constant Execution_Model :=
     System.Task_Info.System_Scope;

end Gnatevl;
