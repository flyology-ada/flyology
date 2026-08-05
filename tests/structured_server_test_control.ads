package Structured_Server_Test_Control is

   type Barrier_Point is
     (Before_Acquisition,
      During_Acquisition,
      After_Acquisition,
      Serving,
      Listener_Close);

   procedure Reset;

   procedure Arm (Point : Barrier_Point);

   procedure Wait_Reached (Point : Barrier_Point);

   procedure Release (Point : Barrier_Point);

end Structured_Server_Test_Control;
