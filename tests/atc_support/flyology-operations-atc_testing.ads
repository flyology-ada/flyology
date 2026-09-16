package Flyology.Operations.ATC_Testing is
   type Observed_Source is (Immediate, Dependency, None);
   type Observed_Child_State is (Vacant, Pending, Terminal);
   type Observed_Outcome is
     (No_Outcome, Success, Cancelled_Outcome, Failed_Outcome);

   type Observation is record
      Reached         : Boolean := False;
      Depth           : Natural := 0;
      Stabilizing     : Boolean := False;
      Dirty           : Boolean := False;
      Source          : Observed_Source := None;
      Deadline        : Boolean := False;
      Child           : Boolean := False;
      Child_State     : Observed_Child_State := Vacant;
      Child_Deadline  : Boolean := False;
      Root_Terminal   : Boolean := False;
      Gate_Terminal   : Boolean := False;
      Root_Outcome    : Observed_Outcome := No_Outcome;
      Gate_Outcome    : Observed_Outcome := No_Outcome;
      Deferral        : Natural := 0;
      Request_Pending : Boolean := False;
      Delivered       : Boolean := False;
      Wait_Failed     : Boolean := False;
   end record;

   type Observation_Array is array (Natural range 0 .. 6) of Observation;

   procedure Run (Scenario : String);
   procedure Run_Replay (Scenario : String; Observed : out Observation_Array);
   procedure Run_Abort;
end Flyology.Operations.ATC_Testing;
