with Ada.Text_IO;
with Flyology;
with Flyology.Observability;

--  Compile and run the utilization example printed in the website guide, so
--  that page cannot drift from the public API.
procedure Guide_Utilization_Example is
   task Probe is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Probe;

   task body Probe is
   begin
      delay 0.05;
   end Probe;
begin
   delay 0.02;
   declare
      use type Flyology.Observability.Counter;
      Sample : Flyology.Observability.Group_Snapshot;
   begin
      if Flyology.Observability.Snapshot (0, Sample) then
         Ada.Text_IO.Put_Line
           ("uptime ns=" & Sample.Uptime_Nanoseconds'Image
            & " idle ns=" & Sample.Idle_Nanoseconds'Image
            & " busy ns="
            & Flyology.Observability.Counter'Image
                (Sample.Uptime_Nanoseconds - Sample.Idle_Nanoseconds)
            & " poller waits=" & Sample.Idle_Waits'Image);
      else
         raise Program_Error with "guide example found no group snapshot";
      end if;
   end;
end Guide_Utilization_Example;
