with Flyology;

package body Lifecycle_Live_Server is
   task Server is
      pragma Task_Info (Flyology.Lightweight_Task);
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
