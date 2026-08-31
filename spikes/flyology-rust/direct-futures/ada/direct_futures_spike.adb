with Ada.Exceptions;
with Ada.Text_IO;
with Direct_Futures_Bridge;
with Flyology;
with Flyology.Operations;
with Interfaces;

procedure Direct_Futures_Spike is
   use type Interfaces.Unsigned_64;

   protected State is
      procedure Begin_Tick_Window;
      procedure Tick;
      procedure End_Tick_Window (Count : out Natural);
      procedure Report (Passed : Boolean; Message : String);
      function Stopped return Boolean;
      entry Await_Result (Passed : out Boolean);
   private
      Window_Active : Boolean := False;
      Tick_Count    : Natural := 0;
      Done          : Boolean := False;
      OK            : Boolean := False;
   end State;

   protected body State is
      procedure Begin_Tick_Window is
      begin
         Tick_Count := 0;
         Window_Active := True;
      end Begin_Tick_Window;

      procedure Tick is
      begin
         if Window_Active then
            Tick_Count := Tick_Count + 1;
         end if;
      end Tick;

      procedure End_Tick_Window (Count : out Natural) is
      begin
         Window_Active := False;
         Count := Tick_Count;
      end End_Tick_Window;

      procedure Report (Passed : Boolean; Message : String) is
      begin
         OK := Passed;
         Done := True;
         if not Passed then
            Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, Message);
         end if;
      end Report;

      function Stopped return Boolean
      is (Done);

      entry Await_Result (Passed : out Boolean) when Done is
      begin
         Passed := OK;
      end Await_Result;
   end State;

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   procedure Await_Value
     (Kind : Direct_Futures_Bridge.Future_Kind; Delay_Millis : Natural; Expected : Long_Long_Integer)
   is
      Set   : aliased Flyology.Operations.Completion_Set (1);
      Item  : Direct_Futures_Bridge.Future_Operation (Set'Access);
      Value : Long_Long_Integer;
   begin
      Direct_Futures_Bridge.Start (Item, Kind, Delay_Millis, Expected);
      Flyology.Operations.Wait_All (Set);
      Direct_Futures_Bridge.Finish (Item, Value);
      Check (Value = Expected, "Rust future returned the wrong value");
   end Await_Value;

   task Runner
     with CPU => 1 is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Runner;

   task Ticker
     with CPU => 1 is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Ticker;

   task body Runner is
      Ticks : Natural;
   begin
      Direct_Futures_Bridge.Reset_Observations;

      --  The first poll self-wakes before Ada arms the readable descriptor.
      Await_Value (Direct_Futures_Bridge.Self_Wake, 0, 41);

      State.Begin_Tick_Window;
      Await_Value (Direct_Futures_Bridge.Delayed, 60, 42);
      State.End_Tick_Window (Ticks);
      Check (Ticks > 0, "same-group ticker made no progress while the Rust future was pending");

      declare
         Set       : aliased Flyology.Operations.Completion_Set (1);
         Item      : Direct_Futures_Bridge.Future_Operation (Set'Access);
         Value     : Long_Long_Integer;
         Cancelled : Boolean := False;
      begin
         Direct_Futures_Bridge.Start (Item, Direct_Futures_Bridge.Delayed, 60, 99);
         Flyology.Operations.Cancel (Item);
         Flyology.Operations.Wait_All (Set);
         begin
            Direct_Futures_Bridge.Finish (Item, Value);
         exception
            when Flyology.Operations.Operation_Cancelled =>
               Cancelled := True;
         end;
         Check (Cancelled, "cancelled Rust future did not report cancellation");
         delay 0.080;
         Check
           (Direct_Futures_Bridge.Late_Wakes > 0,
            "cancelled delayed future did not exercise an escaped late waker");
      end;

      Check (Direct_Futures_Bridge.Signal_Failures = 0, "Rust wake descriptor signaling failed");
      Check (Direct_Futures_Bridge.Concurrent_Polls = 0, "one Rust future was polled concurrently");
      State.Report (True, "");
   exception
      when Error : others =>
         State.Report
           (False,
            "direct-futures spike failed: "
            & Ada.Exceptions.Exception_Name (Error)
            & ": "
            & Ada.Exceptions.Exception_Message (Error));
   end Runner;

   task body Ticker is
   begin
      loop
         delay 0.001;
         State.Tick;
         exit when State.Stopped;
      end loop;
   end Ticker;

   Passed : Boolean;
   pragma Unreferenced (Runner, Ticker);
begin
   State.Await_Result (Passed);
   if not Passed then
      raise Program_Error with "direct Rust future spike failed";
   end if;
   Ada.Text_IO.Put_Line ("direct Rust future spike: PASS");
end Direct_Futures_Spike;
