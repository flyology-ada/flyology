with Ada.Real_Time;

--  Exposes lane-neutral timer waits through standard Ada delay semantics.
--
--  Example:
--
--     Flyology.IO.Timers.Sleep_For (0.010);
package Flyology.IO.Timers is

   --  Wait for Interval seconds. A nonpositive interval is one `delay 0.0`
   --  yield. A lightweight task suspends on its event loop; a native task uses
   --  the runtime's native delay wait and blocks that task's thread.
   --  @param Interval Relative delay in seconds
   procedure Sleep_For (Interval : Duration);
   --  Wait until the monotonic real-time Deadline. A past deadline returns at
   --  the next scheduling point. Lane blocking behavior matches Sleep_For.
   --  @param Deadline Absolute Ada.Real_Time deadline
   procedure Sleep_Until (Deadline : Ada.Real_Time.Time);

end Flyology.IO.Timers;
