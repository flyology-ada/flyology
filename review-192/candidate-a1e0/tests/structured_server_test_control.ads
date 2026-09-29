package Structured_Server_Test_Control is

   type Barrier_Point is
     (Before_Acquisition,
      During_Acquisition,
      After_Acquisition,
      Serving,
      Listener_Close,
      During_Worker_Activation,
      After_Worker_Activation);

   procedure Reset;

   procedure Arm (Point : Barrier_Point);

   procedure Wait_Reached (Point : Barrier_Point);

   procedure Release (Point : Barrier_Point);

   procedure Fail_Activation_At (Ordinal : Positive);

end Structured_Server_Test_Control;
