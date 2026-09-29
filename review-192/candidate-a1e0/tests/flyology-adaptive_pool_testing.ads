package Flyology.Adaptive_Pool_Testing is

   --  Reset the adaptive-pool contention injection.
   procedure Reset;

   --  Make a chunk-allocation release report arena contention after the given
   --  number of successful release attempts.
   procedure Arm_Release_Contention (After_Releases : Natural := 0);

end Flyology.Adaptive_Pool_Testing;
