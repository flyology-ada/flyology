package body Flyology.IO.Timers is

   procedure Sleep_For (Interval : Duration) is
   begin
      if Interval > 0.0 then
         delay Interval;
      else
         delay 0.0;
      end if;
   end Sleep_For;

   procedure Sleep_Until (Deadline : Ada.Real_Time.Time) is
   begin
      delay until Deadline;
   end Sleep_Until;

end Flyology.IO.Timers;
