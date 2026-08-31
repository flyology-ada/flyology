with Ada.Exceptions;
with Ada.Text_IO;
with Flyology;
with Flyology.IO.Timers;
with Flyology.Operations;
with Interfaces;
with Rust_Async_Jobs;

procedure Ada_Hosts_Spike is
   use type Interfaces.Integer_64;

   Runtime : aliased Rust_Async_Jobs.Engine;

   protected Observations is
      procedure Native_Finished (Passed : Boolean);
      procedure Lightweight_Finished (Passed : Boolean);
      procedure Ticker_Finished (Passed : Boolean);
      entry Await_Native (Passed : out Boolean);
      entry Await_Lightweight (Passed : out Boolean);
      entry Await_Wait_Start;
      procedure Start_Wait;
      procedure End_Wait;
      procedure Tick;
      function Ticks_During_Wait return Natural;
   private
      Native_Ready      : Boolean := False;
      Native_OK         : Boolean := False;
      Lightweight_Ready : Boolean := False;
      Lightweight_OK    : Boolean := False;
      Ticker_Ready      : Boolean := False;
      Ticker_OK         : Boolean := False;
      Waiting           : Boolean := False;
      Wait_Started      : Boolean := False;
      During_Wait       : Natural := 0;
   end Observations;

   protected body Observations is
      procedure Native_Finished (Passed : Boolean) is
      begin
         Native_OK := Passed;
         Native_Ready := True;
      end Native_Finished;

      procedure Lightweight_Finished (Passed : Boolean) is
      begin
         Lightweight_OK := Passed;
         Lightweight_Ready := True;
      end Lightweight_Finished;

      procedure Ticker_Finished (Passed : Boolean) is
      begin
         Ticker_OK := Passed;
         Ticker_Ready := True;
      end Ticker_Finished;

      entry Await_Native (Passed : out Boolean) when Native_Ready is
      begin
         Passed := Native_OK;
      end Await_Native;

      entry Await_Lightweight (Passed : out Boolean)
        when Lightweight_Ready and Ticker_Ready
      is
      begin
         Passed := Lightweight_OK and Ticker_OK;
      end Await_Lightweight;

      entry Await_Wait_Start when Wait_Started is
      begin
         null;
      end Await_Wait_Start;

      procedure Start_Wait is
      begin
         Waiting := True;
         Wait_Started := True;
      end Start_Wait;

      procedure End_Wait is
      begin
         Waiting := False;
      end End_Wait;

      procedure Tick is
      begin
         if Waiting then
            During_Wait := During_Wait + 1;
         end if;
      end Tick;

      function Ticks_During_Wait return Natural
      is (During_Wait);
   end Observations;

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   procedure Run_Job
     (Mode      : Rust_Async_Jobs.Job_Mode;
      Delay_For : Duration;
      Expected  : Interfaces.Integer_64;
      Cancel    : Boolean := False)
   is
      Set   : aliased Flyology.Operations.Completion_Set (1);
      Job   : Rust_Async_Jobs.Job_Operation :=
        Rust_Async_Jobs.Start (Set'Access, Runtime, Mode, Delay_For, Expected);
      Value : Interfaces.Integer_64;
   begin
      if Cancel then
         Flyology.Operations.Cancel (Job);
      end if;
      Flyology.Operations.Wait_All (Set);
      Rust_Async_Jobs.Finish (Job, Value);
      Check
        (not Cancel and then Value = Expected,
         "Rust job returned an unexpected value");
   exception
      when Flyology.Operations.Operation_Cancelled =>
         Check (Cancel, "Rust job was unexpectedly cancelled");
   end Run_Job;

   procedure Exercise_Common is
      Failed_As_Expected : Boolean := False;
   begin
      Run_Job (Rust_Async_Jobs.Complete_Immediately, 0.0, 11);
      Run_Job (Rust_Async_Jobs.Complete_After_Delay, 0.020, 22);
      begin
         Run_Job (Rust_Async_Jobs.Panic_After_Delay, 0.001, 0);
      exception
         when Rust_Async_Jobs.Rust_Job_Error =>
            Failed_As_Expected := True;
      end;
      Check
        (Failed_As_Expected,
         "Rust async panic was not translated into an Ada error");
      Run_Job (Rust_Async_Jobs.Complete_After_Delay, 5.0, 0, Cancel => True);
   end Exercise_Common;

   Passed : Boolean;
begin
   Rust_Async_Jobs.Initialize (Runtime);

   declare
      task Native_Runner is
         pragma Task_Info (Flyology.Native_Task);
      end Native_Runner;

      task body Native_Runner is
      begin
         Exercise_Common;
         Observations.Native_Finished (True);
      exception
         when Error : others =>
            Ada.Text_IO.Put_Line
              (Ada.Exceptions.Exception_Information (Error));
            Observations.Native_Finished (False);
      end Native_Runner;
   begin
      Observations.Await_Native (Passed);
      Check (Passed, "native-task Rust async cases failed");
   end;

   declare
      task Lightweight_Runner
        with CPU => 1 is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Lightweight_Runner;

      task Ticker
        with CPU => 1 is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Ticker;

      task body Lightweight_Runner is
         Set   : aliased Flyology.Operations.Completion_Set (1);
         Job   : Rust_Async_Jobs.Job_Operation :=
           Rust_Async_Jobs.Start
             (Set'Access,
              Runtime,
              Rust_Async_Jobs.Complete_After_Delay,
              0.150,
              33);
         Value : Interfaces.Integer_64;
      begin
         Observations.Start_Wait;
         Flyology.Operations.Wait_All (Set);
         Observations.End_Wait;
         Rust_Async_Jobs.Finish (Job, Value);
         Check
           (Value = 33,
            "lightweight delayed Rust job returned an unexpected value");
         Check
           (Observations.Ticks_During_Wait = 5,
            "same-group ticker did not progress during Rust wait");
         Exercise_Common;
         Observations.Lightweight_Finished (True);
      exception
         when Error : others =>
            Observations.End_Wait;
            Ada.Text_IO.Put_Line
              (Ada.Exceptions.Exception_Information (Error));
            Observations.Lightweight_Finished (False);
      end Lightweight_Runner;

      task body Ticker is
      begin
         Observations.Await_Wait_Start;
         for Step in 1 .. 5 loop
            Flyology.IO.Timers.Sleep_For (0.010);
            Observations.Tick;
         end loop;
         Observations.Ticker_Finished (True);
      exception
         when Error : others =>
            Ada.Text_IO.Put_Line
              (Ada.Exceptions.Exception_Information (Error));
            Observations.Ticker_Finished (False);
      end Ticker;
   begin
      Observations.Await_Lightweight (Passed);
      Check (Passed, "lightweight-task Rust async cases failed");
   end;

   Rust_Async_Jobs.Shutdown (Runtime);
   Ada.Text_IO.Put_Line
     ("PASS Ada hosts Rust async: early completion, timer, panic, cancellation, and same-group progress");
exception
   when Error : others =>
      Ada.Text_IO.Put_Line (Ada.Exceptions.Exception_Information (Error));
      raise;
end Ada_Hosts_Spike;
