with Gnatevl.Observability;
with Gnatevl.Observability.Stall_Watchdogs;

procedure Stall_Watchdog_Native_Smoke is
   package Observation renames Gnatevl.Observability;
   package Watchdogs renames Gnatevl.Observability.Stall_Watchdogs;

   use type Watchdogs.Group_Condition;

   Watchdog : Watchdogs.Watchdog;
   Sample   : Observation.Group_Snapshot;
begin
   if Watchdogs.Is_Running (Watchdog)
     or else Watchdogs.Latest_Report (Watchdog).Condition
       /= Watchdogs.Not_Started
     or else Observation.Snapshot (0, Sample)
   then
      raise Program_Error with "declaring a watchdog was not inert";
   end if;

   Watchdogs.Start
     (Watchdog,
      (Group           => 0,
       Sample_Interval => 0.005,
       Stall_Threshold => 0.020));
   delay 0.030;
   if not Watchdogs.Is_Running (Watchdog)
     or else Watchdogs.Latest_Report (Watchdog).Condition
       /= Watchdogs.Group_Absent
     or else Observation.Snapshot (0, Sample)
   then
      raise Program_Error with "watching an absent group started the runtime";
   end if;

   Watchdogs.Stop (Watchdog);
   if Watchdogs.Is_Running (Watchdog)
     or else Watchdogs.Latest_Report (Watchdog).Condition
       /= Watchdogs.Monitor_Stopped
     or else Observation.Snapshot (0, Sample)
   then
      raise Program_Error with "watchdog did not stop cleanly";
   end if;

   --  Restart exercises ownership cleanup instead of accumulating monitor
   --  tasks behind a one-shot API.
   Watchdogs.Start
     (Watchdog,
      (Group           => 0,
       Sample_Interval => 0.005,
       Stall_Threshold => 0.020));
   delay 0.010;
   Watchdogs.Stop (Watchdog);
   if Watchdogs.Is_Running (Watchdog) then
      raise Program_Error with "restarted watchdog leaked its monitor task";
   end if;

   declare
      Finalized : Watchdogs.Watchdog;
   begin
      Watchdogs.Start
        (Finalized,
         (Group           => 0,
          Sample_Interval => 0.005,
          Stall_Threshold => 0.020));
      delay 0.010;
      --  Deliberately omit Stop: limited-controlled finalization owns it.
   end;
   if Observation.Snapshot (0, Sample) then
      raise Program_Error with "finalized watchdog started the event runtime";
   end if;
end Stall_Watchdog_Native_Smoke;
