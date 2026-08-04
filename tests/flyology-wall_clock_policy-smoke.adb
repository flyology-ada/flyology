procedure Flyology.Wall_Clock_Policy.Smoke is
   package Policy renames Flyology.Wall_Clock_Policy;
begin
   pragma Assert
     (Policy.Classify
        (Target_Reached => False,
         Wall_Elapsed   => 1.0,
         Steady_Elapsed => 1.0,
         Tolerance      => 0.001) = Policy.Keep_Waiting);

   pragma Assert
     (Policy.Classify
        (Target_Reached => True,
         Wall_Elapsed   => 1.0,
         Steady_Elapsed => 1.0,
         Tolerance      => 0.001) = Policy.Reached);

   --  The displayed wall clock still advanced, but by less than the steady
   --  clock, exposing a backward adjustment between the two samples.
   pragma Assert
     (Policy.Classify
        (Target_Reached => False,
         Wall_Elapsed   => 0.5,
         Steady_Elapsed => 1.0,
         Tolerance      => 0.001) = Policy.Backstep);

   pragma Assert
     (Policy.Classify
        (Target_Reached => False,
         Wall_Elapsed   => -0.5,
         Steady_Elapsed => 0.1,
         Tolerance      => 0.001) = Policy.Backstep);

   --  Equality with the tolerance is jitter rather than a reportable step.
   pragma Assert
     (Policy.Classify
        (Target_Reached => False,
         Wall_Elapsed   => 0.999,
         Steady_Elapsed => 1.0,
         Tolerance      => 0.001) = Policy.Keep_Waiting);

   --  A backward adjustment wins an ambiguous simultaneous target wake.
   pragma Assert
     (Policy.Classify
        (Target_Reached => True,
         Wall_Elapsed   => 0.5,
         Steady_Elapsed => 1.0,
         Tolerance      => 0.001) = Policy.Backstep);

   pragma Assert
     (Policy.Classify
        (Target_Reached => True,
         Wall_Elapsed   => 2.0,
         Steady_Elapsed => 1.0,
         Tolerance      => 0.001) = Policy.Reached);
end Flyology.Wall_Clock_Policy.Smoke;
