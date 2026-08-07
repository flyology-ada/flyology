with Create_Race_Support;
with Fault_Control;
with Flyology;

--  A foreign thread that the Ada runtime never waits for may call scheduler
--  task creation while the environment task finalizes. Create's lifecycle
--  guard is unlocked, so the creator can pass it and then block on a registry
--  shard for the whole of Finalize's quiescence pass. Registering into a group
--  that Finalize has already stopped violates the event loop's stop invariant
--  and aborts the process; registering after the loop exits touches a freed
--  group and a destroyed mutex. The injected create window parks the foreign
--  creator exactly there, and the process-exit check requires the scheduler to
--  have refused the create and reached its normal stopped state.
procedure Create_Finalize_Race_Smoke is

   task type Group_Starter is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Group_Starter;

   task body Group_Starter is
   begin
      Create_Race_Support.Record_Target_Group;
   end Group_Starter;

   Parked : Boolean := False;

begin
   if not Fault_Control.Enabled then
      raise Program_Error with
        "create/finalize race test requires FLYOLOGY_TEST_FAULTS=1 runtime";
   end if;
   if not Create_Race_Support.Arm_Exit_Check then
      raise Program_Error with "cannot register create/finalize exit check";
   end if;

   --  Start and retire one lightweight task so its execution group exists and
   --  its event thread is parked in the poller when finalization begins.
   declare
      Starter : Group_Starter;
      pragma Unreferenced (Starter);
   begin
      null;
   end;

   Fault_Control.Reset;
   Fault_Control.Arm (Fault_Control.Create_Lifecycle_Window, Count => 1);

   if not Create_Race_Support.Start_Racer then
      raise Program_Error with "cannot start the foreign creating thread";
   end if;

   for Attempt in 1 .. 5_000 loop
      Parked := Create_Race_Support.Creator_Parked;
      exit when Parked;
      delay 0.001;
   end loop;
   if not Parked then
      raise Program_Error with
        "foreign creating thread never reached the create window";
   end if;

   --  Returning from here makes GNARL finalize global tasking, which calls
   --  the scheduler's one-shot Finalize. Finalize sees an empty registry and a
   --  quiescent group, stops that group, and only then releases the parked
   --  creator.
end Create_Finalize_Race_Smoke;
