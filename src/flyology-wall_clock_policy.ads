--  Internal, proved classification of wall-clock wait observations. Clock
--  sampling, kernel notification, and task suspension stay in IO.Timers.
private package Flyology.Wall_Clock_Policy
  with Preelaborate,
       SPARK_Mode
is
   --  Decision after a wall-clock or timer notification.
   type Wait_Action is (Keep_Waiting, Reached, Backstep);

   --  Report whether wall-clock progress lost more than Tolerance relative to
   --  monotonic progress. The split expression avoids overflowing while
   --  subtracting a negative wall-clock interval.
   function Backstep_Detected
     (Wall_Elapsed   : Duration;
      Steady_Elapsed : Duration;
      Tolerance      : Duration) return Boolean
   with
     Pre  => Steady_Elapsed >= 0.0 and then Tolerance >= 0.0,
     Post => Backstep_Detected'Result =
       (if Wall_Elapsed < 0.0 then
           Steady_Elapsed > Tolerance + Wall_Elapsed
        elsif Wall_Elapsed < Steady_Elapsed then
           Steady_Elapsed - Wall_Elapsed > Tolerance
        else
           False);

   --  Give a significant backward adjustment precedence over reaching the
   --  target because ordering is ambiguous when both are observed together.
   function Classify
     (Target_Reached : Boolean;
      Wall_Elapsed   : Duration;
      Steady_Elapsed : Duration;
      Tolerance      : Duration) return Wait_Action
   with
     Pre  => Steady_Elapsed >= 0.0 and then Tolerance >= 0.0,
     Post => Classify'Result =
       (if Backstep_Detected
             (Wall_Elapsed, Steady_Elapsed, Tolerance)
        then Backstep
        elsif Target_Reached then Reached
        else Keep_Waiting);
end Flyology.Wall_Clock_Policy;
