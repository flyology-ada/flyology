with Ada.Real_Time;
with Ada.Text_IO;
with Flyology;
with Flyology.Observability.Stall_Watchdogs;
with Showcase_Support;

procedure Stall_Watchdog is
   package RT renames Ada.Real_Time;
   package TIO renames Ada.Text_IO;
   package Watchdogs renames Flyology.Observability.Stall_Watchdogs;

   use type RT.Time;
   use type Flyology.Observability.Counter;

   protected Completion is
      procedure Finish;
      entry Wait;
   private
      Done : Boolean := False;
   end Completion;

   protected body Completion is
      procedure Finish is
      begin
         Done := True;
      end Finish;

      entry Wait when Done is
      begin
         null;
      end Wait;
   end Completion;

   Monitor : Watchdogs.Watchdog;

   task Event_Work is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Event_Work;

   task body Event_Work is
      Finish : RT.Time;
   begin
      --  First park normally, then monopolize the loop without yielding.
      delay 0.150;
      Finish := RT.Clock + RT.Milliseconds (400);
      while RT.Clock < Finish loop
         null;
      end loop;
      Completion.Finish;
   end Event_Work;

   procedure Print (Label : String) is
      Report : constant Watchdogs.Watchdog_Report := Watchdogs.Latest_Report (Monitor);
   begin
      TIO.Put_Line
        (Label
         & ": "
         & Report.Condition'Image
         & ", ready="
         & Report.Ready'Image
         & ", waiting="
         & Report.Waiting'Image
         & ", running="
         & Report.Running'Image
         & ", observed-for="
         & Showcase_Support.Fixed_Image (Long_Float (Report.Observed_For), Decimals => 3)
         & " s, episodes="
         & Report.Stall_Episodes'Image);
   end Print;
begin
   TIO.Put_Line ("native watchdog sampling event group 0 every 25 ms; " & "stall threshold 100 ms");
   Watchdogs.Start (Monitor, (Group => 0, Sample_Interval => 0.025, Stall_Threshold => 0.100));

   delay 0.075;
   Print ("normally parked");

   declare
      Deadline : constant RT.Time := RT.Clock + RT.Seconds (2);
   begin
      while Watchdogs.Latest_Report (Monitor).Stall_Episodes = 0 and then RT.Clock < Deadline loop
         delay 0.025;
      end loop;
   end;
   Print ("CPU loop sampled");

   Completion.Wait;
   delay 0.050;
   Print ("after completion");
   Watchdogs.Stop (Monitor);
   TIO.Put_Line
     ("the episode counter is latched; detection reports sampled loop lag and"
      & " does not preempt the task or claim a hard deadlock");
end Stall_Watchdog;
