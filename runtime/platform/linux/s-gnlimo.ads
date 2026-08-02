with System.Task_Info;

package System.Gnatevl.Linux_Models is
   pragma Preelaborate;

   Event_Loop_Attributes : aliased System.Task_Info.Thread_Attributes;
   pragma Export
     (C, Event_Loop_Attributes, "__gnatevl_event_loop_task_attributes");
end System.Gnatevl.Linux_Models;
