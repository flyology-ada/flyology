with System.Flyology.Default_Execution;

package body System.Flyology is

   function Is_Lightweight_Designation
     (Task_Info : System.Task_Info.Task_Info_Type) return Boolean
   is
     (Task_Info in System.Task_Info.Process_Scope
      or else
        (System.Flyology.Default_Execution.Lightweight
         and then Task_Info in System.Task_Info.Unspecified_Task_Info));

end System.Flyology;
