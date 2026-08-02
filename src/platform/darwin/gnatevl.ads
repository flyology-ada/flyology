with System.Task_Info;

package Gnatevl with Preelaborate is

   subtype Execution_Model is System.Task_Info.Task_Info_Type;

   Event_Loop_Task : constant Execution_Model :=
     System.Task_Info.Unspecified_Task_Info;

   Native_Thread : constant Execution_Model :=
     System.Task_Info.System_Scope;

end Gnatevl;
