with Flyology.Adaptive_Pool_Test_Hooks;
with Flyology.Connection_Test_Hooks;
with Flyology.Buffer_Test_Hooks;
with Flyology.Channel_Test_Hooks;
with Flyology.DNS_Test_Observations;
with Flyology.Dynamic_Destroy_Test_Hooks;
with Flyology.File_Watch_Test_Hooks;
with Flyology.Structured_Server_Test_Hooks;
with Flyology.Subprocess_Test_Hooks;
with Flyology.Task_Lifecycle_Test_Hooks;
with Flyology.TLS_Test_Hooks;
with Flyology.Wall_Clock_IO_Testing;
with Flyology.Wall_Clock_Testing;
with Flyology.Worker_Pool_Test_Hooks;

procedure Flyology.Test_Hook_Elision_Probe is
   Observed : Boolean := False
   with Volatile;
begin
   if Flyology.Adaptive_Pool_Test_Hooks.Enabled then
      Flyology.Adaptive_Pool_Test_Hooks.Reset;
   end if;
   if Flyology.Buffer_Test_Hooks.Enabled then
      Flyology.Buffer_Test_Hooks.Arm_Next_Acquisition_Near_Exhaustion;
   end if;
   if Flyology.Channel_Test_Hooks.Enabled then
      Flyology.Channel_Test_Hooks.Before_Send_Barrier;
   end if;
   if Flyology.DNS_Test_Observations.Enabled then
      Flyology.DNS_Test_Observations.Reset;
   end if;
   if Flyology.Dynamic_Destroy_Test_Hooks.Enabled then
      Flyology.Dynamic_Destroy_Test_Hooks.Reset;
   end if;
   if Flyology.TLS_Test_Hooks.Enabled then
      Flyology.TLS_Test_Hooks.Reset;
   end if;
   if Flyology.Connection_Test_Hooks.Enabled then
      Flyology.Connection_Test_Hooks.Barrier (0);
   end if;
   if Flyology.Worker_Pool_Test_Hooks.Enabled then
      Flyology.Worker_Pool_Test_Hooks.Run_Claim_Barrier;
   end if;
   if Flyology.Task_Lifecycle_Test_Hooks.Enabled then
      Flyology.Task_Lifecycle_Test_Hooks.Barrier
        (Flyology.Task_Lifecycle_Test_Hooks.Static_Monitor_Registered);
   end if;
   if Flyology.Subprocess_Test_Hooks.Enabled then
      Observed := Flyology.Subprocess_Test_Hooks.Fail_Reaper_Allocation;
   end if;
   if Flyology.Structured_Server_Test_Hooks.Enabled then
      Flyology.Structured_Server_Test_Hooks.Barrier (0);
   end if;
   if Flyology.File_Watch_Test_Hooks.Enabled then
      Observed := Flyology.File_Watch_Test_Hooks.Consume_Events_Lost;
   end if;
   if Flyology.Wall_Clock_Testing.Enabled then
      Flyology.Wall_Clock_Testing.Note_Sample;
   end if;
   if Flyology.Wall_Clock_IO_Testing.Enabled then
      Flyology.Wall_Clock_IO_Testing.Reset;
   end if;
end Flyology.Test_Hook_Elision_Probe;
