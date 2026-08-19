with Ada.Real_Time;
with Flyology;
with Flyology.Execution_Groups;
with Flyology.Observability;
with Interfaces;

--  Check the per-group utilization counters: a group whose only task sleeps
--  reports its event loop as almost entirely idle, a group whose task holds
--  the loop in CPU code reports almost no idle time, and the reported idle
--  time never exceeds the reported uptime or moves backwards.
procedure Observability_Utilization_Smoke is
   package Observation renames Flyology.Observability;
   package Groups renames Flyology.Execution_Groups;
   package Real_Time renames Ada.Real_Time;

   use type Interfaces.Unsigned_64;
   use type Real_Time.Time;

   --  Long enough that scheduling noise cannot dominate either measurement
   --  and short enough to keep the suite quick.
   Window : constant Duration := 0.300;

   Idle_Group : constant Groups.Group_Id := Groups.For_CPU (1);
   Busy_Group : constant Groups.Group_Id := Groups.For_CPU (2);

   function Idle_Percent (Item : Observation.Group_Snapshot) return Natural is
   begin
      if Item.Uptime_Nanoseconds = 0 then
         return 0;
      end if;
      return Natural ((Item.Idle_Nanoseconds * 100) / Item.Uptime_Nanoseconds);
   end Idle_Percent;

   procedure Check_Consistent
     (Item  : Observation.Group_Snapshot;
      Label : String) is
   begin
      if Item.Idle_Nanoseconds > Item.Uptime_Nanoseconds then
         raise Program_Error with
           Label & " reports more idle time than uptime";
      end if;
   end Check_Consistent;

   task Sleeper is
      pragma Task_Info (Flyology.Lightweight_Task);
      pragma CPU (1);
   end Sleeper;

   task body Sleeper is
   begin
      delay Window;
   end Sleeper;

   task Spinner is
      pragma Task_Info (Flyology.Lightweight_Task);
      pragma CPU (2);
   end Spinner;

   task body Spinner is
      --  A cooperative loop that never suspends keeps its event loop out of
      --  the poller for the whole window, which is what makes the busy case
      --  distinguishable from the sleeping one.
      Deadline : constant Real_Time.Time :=
        Real_Time.Clock + Real_Time.To_Time_Span (Window);
      Sink     : Interfaces.Unsigned_64 := 0;
   begin
      while Real_Time.Clock < Deadline loop
         for Step in 1 .. 10_000 loop
            Sink := Sink + Interfaces.Unsigned_64 (Step);
         end loop;
      end loop;
      if Sink = 0 then
         raise Program_Error with "spin loop was optimized away";
      end if;
   end Spinner;

   Idle_First   : Observation.Group_Snapshot;
   Idle_Second  : Observation.Group_Snapshot;
   Busy_Sample  : Observation.Group_Snapshot;
begin
   --  Sample while both tasks are still inside their window.
   delay Window / 2;

   if not Observation.Snapshot (Idle_Group, Idle_First) then
      raise Program_Error with "sleeping group has no snapshot";
   end if;
   if not Observation.Snapshot (Busy_Group, Busy_Sample) then
      raise Program_Error with "spinning group has no snapshot";
   end if;

   Check_Consistent (Idle_First, "sleeping group");
   Check_Consistent (Busy_Sample, "spinning group");

   if Idle_First.Uptime_Nanoseconds = 0 then
      raise Program_Error with "started group reports no uptime";
   end if;
   if Idle_First.Idle_Waits = 0 then
      raise Program_Error with "sleeping group recorded no poller wait";
   end if;
   if Idle_Percent (Idle_First) < 80 then
      raise Program_Error with
        "sleeping group reports only"
        & Natural'Image (Idle_Percent (Idle_First)) & "% idle";
   end if;
   if Idle_Percent (Busy_Sample) > 20 then
      raise Program_Error with
        "spinning group reports"
        & Natural'Image (Idle_Percent (Busy_Sample)) & "% idle";
   end if;

   --  An in-progress poller wait is included in the reported idle time, so a
   --  group that stays blocked keeps accumulating between snapshots.
   delay Window;
   if not Observation.Snapshot (Idle_Group, Idle_Second) then
      raise Program_Error with "sleeping group lost its snapshot";
   end if;
   Check_Consistent (Idle_Second, "sleeping group");
   if Idle_Second.Uptime_Nanoseconds < Idle_First.Uptime_Nanoseconds then
      raise Program_Error with "group uptime moved backwards";
   end if;
   if Idle_Second.Idle_Nanoseconds < Idle_First.Idle_Nanoseconds then
      raise Program_Error with "group idle time moved backwards";
   end if;
   if Idle_Second.Idle_Nanoseconds = Idle_First.Idle_Nanoseconds then
      raise Program_Error with "blocked group accumulated no idle time";
   end if;
end Observability_Utilization_Smoke;
