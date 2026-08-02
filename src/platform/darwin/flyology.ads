with System.Task_Info;

package Flyology with Preelaborate is

   subtype Execution_Model is System.Task_Info.Task_Info_Type;

   Project_Default : constant Execution_Model :=
     System.Task_Info.Unspecified_Task_Info;

   Lightweight_Task : constant Execution_Model :=
     System.Task_Info.Process_Scope;

   Native_Task : constant Execution_Model :=
     System.Task_Info.System_Scope;

end Flyology;
