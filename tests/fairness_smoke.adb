with Ada.Real_Time;
with Flyology;
with Flyology.Fairness;

procedure Fairness_Smoke is
   use Ada.Real_Time;

   protected State is
      procedure Arm;
      entry Await_Arm (Started : out Time);
      procedure Pulse;
      procedure Work_Finished;
      entry Await_Completion;
      function Pulse_Preceded_Work return Boolean;
      function Pulse_Latency return Time_Span;
   private
      Armed       : Boolean := False;
      Completed   : Natural := 0;
      Armed_At    : Time := Time_First;
      Pulsed_At   : Time := Time_First;
      Finished_At : Time := Time_First;
   end State;

   protected body State is
      procedure Arm is
      begin
         Armed_At := Clock;
         Armed := True;
      end Arm;

      entry Await_Arm (Started : out Time) when Armed is
      begin
         Started := Armed_At;
      end Await_Arm;

      procedure Pulse is
      begin
         Pulsed_At := Clock;
         Completed := Completed + 1;
      end Pulse;

      procedure Work_Finished is
      begin
         Finished_At := Clock;
         Completed := Completed + 1;
      end Work_Finished;

      entry Await_Completion when Completed = 2 is
      begin
         null;
      end Await_Completion;

      function Pulse_Preceded_Work return Boolean is
        (Pulsed_At < Finished_At);

      function Pulse_Latency return Time_Span is
        (Pulsed_At - Armed_At);
   end State;

   task CPU_Work is
      pragma Task_Info (Flyology.Lightweight_Task);
   end CPU_Work;

   task Pulse is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Pulse;

   task body CPU_Work is
      Budget  : Flyology.Fairness.Yield_Budget;
      Started : Time;
      Stop_At : Time;
      Value   : Long_Long_Integer := 1;
      pragma Volatile (Value);
   begin
      State.Await_Arm (Started);
      Stop_At := Started + Milliseconds (400);
      Budget.Configure (Microseconds (100));
      while Clock < Stop_At loop
         Value := (Value * 1_103_515_245 + 12_345) mod 2_147_483_647;
         Budget.Checkpoint;
      end loop;
      State.Work_Finished;
   end CPU_Work;

   task body Pulse is
   begin
      State.Arm;
      delay 0.020;
      State.Pulse;
   end Pulse;

   pragma Unreferenced (CPU_Work, Pulse);
begin
   State.Await_Completion;
   pragma Assert (State.Pulse_Preceded_Work);
   pragma Assert (State.Pulse_Latency < Milliseconds (200));
end Fairness_Smoke;
