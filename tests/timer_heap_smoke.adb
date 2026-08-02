with Ada.Real_Time;
with Flyology;

procedure Timer_Heap_Smoke is
   use Ada.Real_Time;

   Timer_Count : constant := 512;

   protected Results is
      procedure Finished (Passed : Boolean);
      procedure Unexpected_Completion;
      entry Wait;
      function Passed return Boolean;
   private
      Completed  : Natural := 0;
      All_OK     : Boolean := True;
      Unexpected : Boolean := False;
   end Results;

   protected body Results is
      procedure Finished (Passed : Boolean) is
      begin
         Completed := Completed + 1;
         All_OK := All_OK and Passed;
      end Finished;

      procedure Unexpected_Completion is
      begin
         Unexpected := True;
      end Unexpected_Completion;

      entry Wait when Completed = Timer_Count is
      begin
         null;
      end Wait;

      function Passed return Boolean is (All_OK and not Unexpected);
   end Results;

begin
   declare
      task type Timed_Worker (Index : Positive) is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Timed_Worker;

      task body Timed_Worker is
         Delay_For : constant Duration :=
           Duration ((Index * 17) mod 31 + 1) / 1_000.0;
         Started : constant Time := Clock;
      begin
         delay Delay_For;
         Results.Finished
           (To_Duration (Clock - Started) >= Delay_For - 0.001
            and then To_Duration (Clock - Started) < 1.0);
      exception
         when others =>
            Results.Finished (False);
      end Timed_Worker;

      type Timed_Worker_Access is access Timed_Worker;
      Workers : array (1 .. Timer_Count) of Timed_Worker_Access;
   begin
      for Index in Workers'Range loop
         Workers (Index) := new Timed_Worker (Index);
      end loop;
      Results.Wait;
   end;

   declare
      task type Cancelled_Timer is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Cancelled_Timer;

      task body Cancelled_Timer is
      begin
         delay 10.0;
         Results.Unexpected_Completion;
      end Cancelled_Timer;

      Timers : array (1 .. 64) of Cancelled_Timer;
   begin
      delay 0.020;
      for Index in Timers'Range loop
         abort Timers (Index);
      end loop;
   end;

   if not Results.Passed then
      raise Program_Error with "timer heap ordering or cancellation failed";
   end if;
end Timer_Heap_Smoke;
