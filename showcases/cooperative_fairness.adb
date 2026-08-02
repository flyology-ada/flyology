with Ada.Real_Time;
with Ada.Text_IO;
with Gnatevl.Fairness;

procedure Cooperative_Fairness is
   use Ada.Real_Time;
   use Ada.Text_IO;

   Work_Time  : constant Time_Span := Milliseconds (300);
   Pulse_Time : constant Duration := 0.020;

   procedure Run
     (Cooperative  : Boolean;
      Pulse_Latency : out Duration;
      Work_Elapsed  : out Duration)
   is
      protected State is
         procedure Arm;
         entry Await_Arm (Started : out Time);
         procedure Pulse;
         procedure Work_Finished;
         entry Await_Completion;
         function Pulse_At return Time;
         function Finished_At return Time;
      private
         Armed      : Boolean := False;
         Completed  : Natural := 0;
         Armed_At   : Time := Time_First;
         Pulsed_At  : Time := Time_First;
         Work_At    : Time := Time_First;
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
            Work_At := Clock;
            Completed := Completed + 1;
         end Work_Finished;

         entry Await_Completion when Completed = 2 is
         begin
            null;
         end Await_Completion;

         function Pulse_At return Time is (Pulsed_At);
         function Finished_At return Time is (Work_At);
      end State;

      task CPU_Work;
      task Pulse;

      task body CPU_Work is
         Budget  : Gnatevl.Fairness.Yield_Budget;
         Started : Time;
         Stop_At : Time;
         Value   : Long_Long_Integer := 1;
         pragma Volatile (Value);
      begin
         State.Await_Arm (Started);
         Stop_At := Started + Work_Time;
         if Cooperative then
            Budget.Configure (Microseconds (100));
         end if;
         while Clock < Stop_At loop
            Value := (Value * 1_103_515_245 + 12_345) mod 2_147_483_647;
            if Cooperative then
               Budget.Checkpoint;
            end if;
         end loop;
         State.Work_Finished;
      end CPU_Work;

      task body Pulse is
      begin
         State.Arm;
         delay Pulse_Time;
         State.Pulse;
      end Pulse;

      Started : Time;
      pragma Unreferenced (CPU_Work, Pulse);
   begin
      State.Await_Arm (Started);
      State.Await_Completion;
      Pulse_Latency := To_Duration (State.Pulse_At - Started);
      Work_Elapsed := To_Duration (State.Finished_At - Started);
   end Run;

   Uncooperative_Pulse : Duration;
   Uncooperative_Work  : Duration;
   Cooperative_Pulse   : Duration;
   Cooperative_Work    : Duration;
begin
   Put_Line ("same event loop, 300 ms of CPU work, 20 ms pulse timer");
   Run (False, Uncooperative_Pulse, Uncooperative_Work);
   Run (True, Cooperative_Pulse, Cooperative_Work);

   Put_Line
     ("  no checkpoints: pulse=" & Uncooperative_Pulse'Image
      & " s, work=" & Uncooperative_Work'Image & " s");
   Put_Line
     ("  100 us budget: pulse=" & Cooperative_Pulse'Image
      & " s, work=" & Cooperative_Work'Image & " s");
   Put_Line
     ("  pulse-latency improvement:"
      & Long_Float'Image
          (Long_Float (Uncooperative_Pulse) /
           Long_Float (Cooperative_Pulse))
      & "x");
   Put_Line
     ("checkpoints preserve cooperative safety; they do not preempt arbitrary"
      & " Ada instructions");
end Cooperative_Fairness;
