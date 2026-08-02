with Ada.Real_Time;

package Flyology.IO.Timers is

   procedure Sleep_For (Interval : Duration);
   procedure Sleep_Until (Deadline : Ada.Real_Time.Time);

end Flyology.IO.Timers;
