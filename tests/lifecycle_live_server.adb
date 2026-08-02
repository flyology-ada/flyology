with Gnatevl;

package body Lifecycle_Live_Server is
   task Server is
      pragma Task_Info (Gnatevl.Event_Loop_Task);
      entry Stop;
   end Server;

   task body Server is
   begin
      select
         accept Stop;
      or
         terminate;
      end select;
   end Server;
end Lifecycle_Live_Server;
