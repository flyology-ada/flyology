with System.Flyology.Default_Execution;
with System.Flyology.Linux_Models;

package body System.Flyology is

   use type System.Task_Info.Task_Info_Type;

   function Is_Lightweight_Designation
     (Task_Info : System.Task_Info.Task_Info_Type) return Boolean
   is
     ((Task_Info = System.Task_Info.Unspecified_Task_Info
       and then System.Flyology.Default_Execution.Lightweight)
      or else
        Task_Info =
          System.Flyology.Linux_Models.Event_Loop_Attributes'Access);

end System.Flyology;
