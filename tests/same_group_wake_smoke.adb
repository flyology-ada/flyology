with Fault_Control;
with Flyology;
with Flyology.Observability;
with Interfaces;

procedure Same_Group_Wake_Smoke is
   Rounds        : constant := 1_000;
   Sample        : Flyology.Observability.Group_Snapshot;
   Idle_Observed : Boolean := False;

   use type Interfaces.Unsigned_64;

   protected Results is
      procedure Report (Poller_Wakes : Natural; Registry_Wakes : Natural);
      entry Wait_For_Report;
      function Poller_Wakes return Natural;
      function Registry_Wakes return Natural;
   private
      Reported          : Boolean := False;
      Poller_Wake_Count : Natural := 0;
      Registry_Count    : Natural := 0;
   end Results;

   protected body Results is
      procedure Report (Poller_Wakes : Natural; Registry_Wakes : Natural) is
      begin
         Poller_Wake_Count := Poller_Wakes;
         Registry_Count := Registry_Wakes;
         Reported := True;
      end Report;

      entry Wait_For_Report when Reported is
      begin
         null;
      end Wait_For_Report;

      function Poller_Wakes return Natural is (Poller_Wake_Count);
      function Registry_Wakes return Natural is (Registry_Count);
   end Results;

   task Server with CPU => 1 is
      pragma Task_Info (Flyology.Lightweight_Task);
      entry Ping;
      entry Stop;
   end Server;

   task body Server is
   begin
      loop
         select
            accept Ping;
         or
            accept Stop;
            exit;
         end select;
      end loop;
   end Server;

   task Client with CPU => 1 is
      pragma Task_Info (Flyology.Lightweight_Task);
      entry Run;
   end Client;

   task body Client is
   begin
      accept Run;
      Fault_Control.Reset;
      for Iteration in 1 .. Rounds loop
         Server.Ping;
      end loop;
      Results.Report
        (Fault_Control.Calls (Fault_Control.Poller_Wake),
         Fault_Control.Registry_Lookup_Count (Fault_Control.Wake));
   end Client;
begin
   if not Fault_Control.Enabled then
      raise Program_Error with "same-group wake test requires FLYOLOGY_TEST_FAULTS=1 runtime";
   end if;

   Client.Run;
   Results.Wait_For_Report;
   if Results.Poller_Wakes /= 0 then
      Server.Stop;
      raise Program_Error with "same-group rendezvous signaled the poller";
   end if;
   if Results.Registry_Wakes /= Rounds then
      Server.Stop;
      raise Program_Error with "same-group rendezvous did not use one registry lookup per wake";
   end if;

   --  Wait until the server is suspended and its loop has entered the idle
   --  poll. A native caller must notify that loop to resume the entry.
   for Attempt in 1 .. 100 loop
      Idle_Observed :=
        Flyology.Observability.Snapshot (1, Sample)
          and then Sample.Waiting >= 1
          and then Sample.Ready = 0
          and then Sample.Running = 0
          and then Sample.Idle_Waits > 0;
      exit when Idle_Observed;
      delay 0.001;
   end loop;
   if not Idle_Observed then
      Server.Stop;
      raise Program_Error with "server did not reach its idle entry wait";
   end if;
   Fault_Control.Reset;
   Server.Ping;
   Idle_Observed := Fault_Control.Calls (Fault_Control.Poller_Wake) /= 0;
   Server.Stop;
   if not Idle_Observed then
      raise Program_Error with "native caller failed to signal the idle loop";
   end if;
end Same_Group_Wake_Smoke;
