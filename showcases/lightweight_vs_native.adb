with Ada.Real_Time;
with Ada.Text_IO;
with Flyology;
with Showcase_Support;

procedure Lightweight_Vs_Native is
   use Ada.Real_Time;
   use Ada.Text_IO;

   Yield_Workers : constant := 256;
   Yield_Turns   : constant := 100;
   Wait_Workers  : constant := 2_048;
   Wait_Time     : constant Duration := 0.020;

   protected type Completion_Counter (Target : Positive) is
      procedure Finished;
      entry Wait;
   private
      Count : Natural := 0;
   end Completion_Counter;

   protected body Completion_Counter is
      procedure Finished is
      begin
         Count := Count + 1;
      end Finished;

      entry Wait when Count = Target is
      begin
         null;
      end Wait;
   end Completion_Counter;

   procedure Report (Lightweight_Elapsed : Duration; Native_Elapsed : Duration) is
      Ratio : constant Long_Float := Long_Float (Native_Elapsed) / Long_Float (Lightweight_Elapsed);
   begin
      Put_Line ("  event loop: " & Lightweight_Elapsed'Image & " s (one OS thread)");
      Put_Line ("  pthreads:   " & Native_Elapsed'Image & " s");
      Put_Line
        ("  native/event-loop time ratio: " & Showcase_Support.Fixed_Image (Ratio, Decimals => 2) & "x");
      if Ratio >= 1.0 then
         Put_Line
           ("  result: event loop is " & Showcase_Support.Fixed_Image (Ratio, Decimals => 2) & "x faster");
      else
         Put_Line
           ("  result: pthreads are "
            & Showcase_Support.Fixed_Image (1.0 / Ratio, Decimals => 2)
            & "x faster");
      end if;
   end Report;

   Lightweight_Elapsed : Duration;
   Native_Elapsed      : Duration;
   Started             : Time;

begin
   Put_Line
     ("case 1: scheduling throughput (" & Yield_Workers'Image & " tasks x" & Yield_Turns'Image & " yields)");

   Started := Clock;
   declare
      Completion : Completion_Counter (Yield_Workers);
      task type Lightweight_Worker is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Lightweight_Worker;

      task body Lightweight_Worker is
      begin
         for Turn in 1 .. Yield_Turns loop
            delay 0.0;
         end loop;
         Completion.Finished;
      end Lightweight_Worker;

      Workers : array (1 .. Yield_Workers) of Lightweight_Worker;
      pragma Unreferenced (Workers);
   begin
      Completion.Wait;
   end;
   Lightweight_Elapsed := To_Duration (Clock - Started);

   Started := Clock;
   declare
      Completion : Completion_Counter (Yield_Workers);
      task type Native_Worker is
         pragma Task_Info (Flyology.Native_Task);
      end Native_Worker;

      task body Native_Worker is
      begin
         for Turn in 1 .. Yield_Turns loop
            delay 0.0;
         end loop;
         Completion.Finished;
      end Native_Worker;

      Workers : array (1 .. Yield_Workers) of Native_Worker;
      pragma Unreferenced (Workers);
   begin
      Completion.Wait;
   end;
   Native_Elapsed := To_Duration (Clock - Started);
   Report (Lightweight_Elapsed, Native_Elapsed);

   New_Line;
   Put_Line
     ("case 2: high-fanout waiting (" & Wait_Workers'Image & " tasks each wait" & Wait_Time'Image & " s)");

   Started := Clock;
   declare
      Completion : Completion_Counter (Wait_Workers);
      task type Lightweight_Waiter is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Lightweight_Waiter;

      task body Lightweight_Waiter is
      begin
         delay Wait_Time;
         Completion.Finished;
      end Lightweight_Waiter;

      Workers : array (1 .. Wait_Workers) of Lightweight_Waiter;
      pragma Unreferenced (Workers);
   begin
      Completion.Wait;
   end;
   Lightweight_Elapsed := To_Duration (Clock - Started);

   Started := Clock;
   declare
      Completion : Completion_Counter (Wait_Workers);
      task type Native_Waiter is
         pragma Task_Info (Flyology.Native_Task);
      end Native_Waiter;

      task body Native_Waiter is
      begin
         delay Wait_Time;
         Completion.Finished;
      end Native_Waiter;

      Workers : array (1 .. Wait_Workers) of Native_Waiter;
      pragma Unreferenced (Workers);
   begin
      Completion.Wait;
   end;
   Native_Elapsed := To_Duration (Clock - Started);
   Report (Lightweight_Elapsed, Native_Elapsed);
end Lightweight_Vs_Native;
