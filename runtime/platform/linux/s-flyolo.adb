with System.Flyology.Default_Execution;
with System.Flyology.Linux_Models;

package body System.Flyology is

   use type System.Task_Info.Task_Info_Type;

   Native_Task_Attributes : aliased System.Task_Info.Thread_Attributes;

   function Native_Designation return System.Task_Info.Task_Info_Type
   is (Native_Task_Attributes'Access);

   function Is_Lightweight_Designation (Task_Info : System.Task_Info.Task_Info_Type) return Boolean
   is ((Task_Info = System.Task_Info.Unspecified_Task_Info
        and then System.Flyology.Default_Execution.Lightweight)
       or else Task_Info = System.Flyology.Linux_Models.Event_Loop_Attributes'Access);

end System.Flyology;
