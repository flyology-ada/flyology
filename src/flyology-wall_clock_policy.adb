package body Flyology.Wall_Clock_Policy
  with SPARK_Mode
is
   function Backstep_Detected
     (Wall_Elapsed   : Duration;
      Steady_Elapsed : Duration;
      Tolerance      : Duration) return Boolean
   is
     (if Wall_Elapsed < 0.0 then
         Steady_Elapsed > Tolerance + Wall_Elapsed
      elsif Wall_Elapsed < Steady_Elapsed then
         Steady_Elapsed - Wall_Elapsed > Tolerance
      else
         False);

   function Classify
     (Target_Reached : Boolean;
      Wall_Elapsed   : Duration;
      Steady_Elapsed : Duration;
      Tolerance      : Duration) return Wait_Action
   is
     (if Backstep_Detected (Wall_Elapsed, Steady_Elapsed, Tolerance) then
         Backstep
      elsif Target_Reached then
         Reached
      else
         Keep_Waiting);
end Flyology.Wall_Clock_Policy;
