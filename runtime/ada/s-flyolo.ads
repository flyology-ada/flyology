with System.Task_Info;

package System.Flyology is
   pragma Preelaborate;

   --  Return the platform's explicit native-thread Task_Info designation.
   function Native_Designation return System.Task_Info.Task_Info_Type;

   function Is_Lightweight_Designation (Task_Info : System.Task_Info.Task_Info_Type) return Boolean;
end System.Flyology;
