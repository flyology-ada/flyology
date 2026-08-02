with System.Task_Info;

package System.Flyology.Linux_Models is
   pragma Preelaborate;

   Event_Loop_Attributes : aliased System.Task_Info.Thread_Attributes;
   pragma Export
     (C, Event_Loop_Attributes, "__flyology_event_loop_task_attributes");
end System.Flyology.Linux_Models;
