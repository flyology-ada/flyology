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
   Stress_Rounds : constant Positive := 32;

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

   procedure Finish_Success
     (Item : in out Rust_Async_Jobs.Job_Operation;
      Expected : Interfaces.Integer_64)
   is
      Value : Interfaces.Integer_64;
   begin
      Rust_Async_Jobs.Finish (Item, Value);
      Check (Value = Expected, "shared-wake job returned an unexpected value");
   end Finish_Success;

   procedure Finish_Race
     (Item       : in out Rust_Async_Jobs.Job_Operation;
      Expected   : Interfaces.Integer_64;
      Succeeded  : in out Natural;
      Cancelled  : in out Natural)
   is
      Value : Interfaces.Integer_64;
   begin
      Rust_Async_Jobs.Finish (Item, Value);
      Check (Value = Expected, "racing Rust job returned an unexpected value");
      Succeeded := Succeeded + 1;
   exception
      when Flyology.Operations.Operation_Cancelled =>
         Cancelled := Cancelled + 1;
   end Finish_Race;

   procedure Exercise_Shared_Wake_And_Races (Lane : String) is
      Succeeded : Natural := 0;
      Cancelled : Natural := 0;
   begin
      for Round in 1 .. Stress_Rounds loop
         declare
            Base : constant Interfaces.Integer_64 :=
              Interfaces.Integer_64 (Round) * 100;
            Set : aliased Flyology.Operations.Completion_Set (8);
            J1  : Rust_Async_Jobs.Job_Operation :=
              Rust_Async_Jobs.Start
                (Set'Access, Runtime, Rust_Async_Jobs.Complete_After_Delay, 0.001, Base + 1);
            J2  : Rust_Async_Jobs.Job_Operation :=
              Rust_Async_Jobs.Start
                (Set'Access, Runtime, Rust_Async_Jobs.Complete_After_Delay, 0.001, Base + 2);
            J3  : Rust_Async_Jobs.Job_Operation :=
              Rust_Async_Jobs.Start
                (Set'Access, Runtime, Rust_Async_Jobs.Complete_After_Delay, 0.001, Base + 3);
            J4  : Rust_Async_Jobs.Job_Operation :=
              Rust_Async_Jobs.Start
                (Set'Access, Runtime, Rust_Async_Jobs.Complete_After_Delay, 0.001, Base + 4);
            J5  : Rust_Async_Jobs.Job_Operation :=
              Rust_Async_Jobs.Start
                (Set'Access, Runtime, Rust_Async_Jobs.Complete_After_Delay, 0.001, Base + 5);
            J6  : Rust_Async_Jobs.Job_Operation :=
              Rust_Async_Jobs.Start
                (Set'Access, Runtime, Rust_Async_Jobs.Complete_After_Delay, 0.001, Base + 6);
            J7  : Rust_Async_Jobs.Job_Operation :=
              Rust_Async_Jobs.Start
                (Set'Access, Runtime, Rust_Async_Jobs.Complete_After_Delay, 0.001, Base + 7);
            J8  : Rust_Async_Jobs.Job_Operation :=
              Rust_Async_Jobs.Start
                (Set'Access, Runtime, Rust_Async_Jobs.Complete_After_Delay, 0.001, Base + 8);
         begin
            Flyology.Operations.Wait_All (Set);
            Finish_Success (J1, Base + 1);
            Finish_Success (J2, Base + 2);
            Finish_Success (J3, Base + 3);
            Finish_Success (J4, Base + 4);
            Finish_Success (J5, Base + 5);
            Finish_Success (J6, Base + 6);
            Finish_Success (J7, Base + 7);
            Finish_Success (J8, Base + 8);
         end;

         declare
            Base : constant Interfaces.Integer_64 :=
              Interfaces.Integer_64 (Round) * 1_000;
            Set : aliased Flyology.Operations.Completion_Set (8);
            J1  : Rust_Async_Jobs.Job_Operation :=
              Rust_Async_Jobs.Start
                (Set'Access, Runtime, Rust_Async_Jobs.Complete_After_Delay, 0.0, Base + 1);
            J2  : Rust_Async_Jobs.Job_Operation :=
              Rust_Async_Jobs.Start
                (Set'Access, Runtime, Rust_Async_Jobs.Complete_After_Delay, 0.0, Base + 2);
            J3  : Rust_Async_Jobs.Job_Operation :=
              Rust_Async_Jobs.Start
                (Set'Access, Runtime, Rust_Async_Jobs.Complete_After_Delay, 0.0, Base + 3);
            J4  : Rust_Async_Jobs.Job_Operation :=
              Rust_Async_Jobs.Start
                (Set'Access, Runtime, Rust_Async_Jobs.Complete_After_Delay, 0.0, Base + 4);
            J5  : Rust_Async_Jobs.Job_Operation :=
              Rust_Async_Jobs.Start
                (Set'Access, Runtime, Rust_Async_Jobs.Complete_After_Delay, 0.0, Base + 5);
            J6  : Rust_Async_Jobs.Job_Operation :=
              Rust_Async_Jobs.Start
                (Set'Access, Runtime, Rust_Async_Jobs.Complete_After_Delay, 0.0, Base + 6);
            J7  : Rust_Async_Jobs.Job_Operation :=
              Rust_Async_Jobs.Start
                (Set'Access, Runtime, Rust_Async_Jobs.Complete_After_Delay, 0.0, Base + 7);
            J8  : Rust_Async_Jobs.Job_Operation :=
              Rust_Async_Jobs.Start
                (Set'Access, Runtime, Rust_Async_Jobs.Complete_After_Delay, 0.0, Base + 8);
         begin
            if Round mod 2 = 0 then
               --  Let the zero-delay futures race ahead on alternating
               --  rounds, so cancellation crosses both sides of terminal
               --  publication instead of measuring only cancel-first.
               delay 0.005;
            end if;
            Flyology.Operations.Cancel (J1);
            Flyology.Operations.Cancel (J2);
            Flyology.Operations.Cancel (J3);
            Flyology.Operations.Cancel (J4);
            Flyology.Operations.Cancel (J5);
            Flyology.Operations.Cancel (J6);
            Flyology.Operations.Cancel (J7);
            Flyology.Operations.Cancel (J8);
            Flyology.Operations.Wait_All (Set);
            Finish_Race (J1, Base + 1, Succeeded, Cancelled);
            Finish_Race (J2, Base + 2, Succeeded, Cancelled);
            Finish_Race (J3, Base + 3, Succeeded, Cancelled);
            Finish_Race (J4, Base + 4, Succeeded, Cancelled);
            Finish_Race (J5, Base + 5, Succeeded, Cancelled);
            Finish_Race (J6, Base + 6, Succeeded, Cancelled);
            Finish_Race (J7, Base + 7, Succeeded, Cancelled);
            Finish_Race (J8, Base + 8, Succeeded, Cancelled);
         end;
      end loop;
      Check
        (Succeeded + Cancelled = Stress_Rounds * 8,
         "cancel/complete race lost a terminal outcome");
      Check
        (Succeeded > 0 and then Cancelled > 0,
         "cancel/complete campaign did not exercise both terminal outcomes");
      Ada.Text_IO.Put_Line
        ("TRACE " & Lane & " cancel race: succeeded=" & Succeeded'Image &
         " cancelled=" & Cancelled'Image);
   end Exercise_Shared_Wake_And_Races;

   procedure Exercise_Slot_Exhaustion is
      Set               : aliased Flyology.Operations.Completion_Set (9);
      Capacity_Rejected : Boolean := False;
      J1                : Rust_Async_Jobs.Job_Operation :=
        Rust_Async_Jobs.Start
          (Set'Access, Runtime, Rust_Async_Jobs.Complete_After_Delay, 5.0, 1);
      J2                : Rust_Async_Jobs.Job_Operation :=
        Rust_Async_Jobs.Start
          (Set'Access, Runtime, Rust_Async_Jobs.Complete_After_Delay, 5.0, 2);
      J3                : Rust_Async_Jobs.Job_Operation :=
        Rust_Async_Jobs.Start
          (Set'Access, Runtime, Rust_Async_Jobs.Complete_After_Delay, 5.0, 3);
      J4                : Rust_Async_Jobs.Job_Operation :=
        Rust_Async_Jobs.Start
          (Set'Access, Runtime, Rust_Async_Jobs.Complete_After_Delay, 5.0, 4);
      J5                : Rust_Async_Jobs.Job_Operation :=
        Rust_Async_Jobs.Start
          (Set'Access, Runtime, Rust_Async_Jobs.Complete_After_Delay, 5.0, 5);
      J6                : Rust_Async_Jobs.Job_Operation :=
        Rust_Async_Jobs.Start
          (Set'Access, Runtime, Rust_Async_Jobs.Complete_After_Delay, 5.0, 6);
      J7                : Rust_Async_Jobs.Job_Operation :=
        Rust_Async_Jobs.Start
          (Set'Access, Runtime, Rust_Async_Jobs.Complete_After_Delay, 5.0, 7);
      J8                : Rust_Async_Jobs.Job_Operation :=
        Rust_Async_Jobs.Start
          (Set'Access, Runtime, Rust_Async_Jobs.Complete_After_Delay, 5.0, 8);
   begin
      begin
         declare
            Ninth : Rust_Async_Jobs.Job_Operation :=
              Rust_Async_Jobs.Start
                (Set'Access, Runtime, Rust_Async_Jobs.Complete_Immediately, 0.0, 9);
            pragma Unreferenced (Ninth);
         begin
            null;
         end;
      exception
         when Rust_Async_Jobs.Rust_Capacity_Error =>
            Capacity_Rejected := True;
      end;

      Flyology.Operations.Cancel (J1);
      Flyology.Operations.Cancel (J2);
      Flyology.Operations.Cancel (J3);
      Flyology.Operations.Cancel (J4);
      Flyology.Operations.Cancel (J5);
      Flyology.Operations.Cancel (J6);
      Flyology.Operations.Cancel (J7);
      Flyology.Operations.Cancel (J8);
      Flyology.Operations.Wait_All (Set);
      declare
         Value : Interfaces.Integer_64;
      begin
         begin
            Rust_Async_Jobs.Finish (J1, Value);
         exception
            when Flyology.Operations.Operation_Cancelled =>
               null;
         end;
         begin
            Rust_Async_Jobs.Finish (J2, Value);
         exception
            when Flyology.Operations.Operation_Cancelled =>
               null;
         end;
         begin
            Rust_Async_Jobs.Finish (J3, Value);
         exception
            when Flyology.Operations.Operation_Cancelled =>
               null;
         end;
         begin
            Rust_Async_Jobs.Finish (J4, Value);
         exception
            when Flyology.Operations.Operation_Cancelled =>
               null;
         end;
         begin
            Rust_Async_Jobs.Finish (J5, Value);
         exception
            when Flyology.Operations.Operation_Cancelled =>
               null;
         end;
         begin
            Rust_Async_Jobs.Finish (J6, Value);
         exception
            when Flyology.Operations.Operation_Cancelled =>
               null;
         end;
         begin
            Rust_Async_Jobs.Finish (J7, Value);
         exception
            when Flyology.Operations.Operation_Cancelled =>
               null;
         end;
         begin
            Rust_Async_Jobs.Finish (J8, Value);
         exception
            when Flyology.Operations.Operation_Cancelled =>
               null;
         end;
      end;
      Check (Capacity_Rejected, "ninth Rust slot was not rejected");

      --  The next generation must immediately reuse the released capacity.
      Run_Job (Rust_Async_Jobs.Complete_Immediately, 0.0, 99);
   end Exercise_Slot_Exhaustion;

   procedure Exercise_Busy_Shutdown is
      Set               : aliased Flyology.Operations.Completion_Set (1);
      Job               : Rust_Async_Jobs.Job_Operation :=
        Rust_Async_Jobs.Start
          (Set'Access, Runtime, Rust_Async_Jobs.Complete_After_Delay, 5.0, 1);
      Shutdown_Rejected : Boolean := False;
      Value             : Interfaces.Integer_64;
   begin
      begin
         Rust_Async_Jobs.Shutdown (Runtime);
      exception
         when Rust_Async_Jobs.Rust_Engine_Busy =>
            Shutdown_Rejected := True;
      end;
      Check (Shutdown_Rejected, "Rust engine shutdown accepted an active job");
      Flyology.Operations.Cancel (Job);
      Flyology.Operations.Wait_All (Set);
      begin
         Rust_Async_Jobs.Finish (Job, Value);
      exception
         when Flyology.Operations.Operation_Cancelled =>
            null;
      end;
   end Exercise_Busy_Shutdown;

   procedure Exercise_Abandonment is
   begin
      declare
         Set : aliased Flyology.Operations.Completion_Set (1);
         Job : constant Rust_Async_Jobs.Job_Operation :=
           Rust_Async_Jobs.Start
             (Set'Access, Runtime, Rust_Async_Jobs.Complete_After_Delay, 5.0, 41);
      begin
         Check (Flyology.Operations.Is_Active (Job), "long Rust job was not admitted");
         --  Scope exit must cancel, drain, and release the Rust slot without
         --  an explicit wait or typed Finish.
      end;
      Check
        (Rust_Async_Jobs.Active_Jobs (Runtime) = 0,
         "abandoned pending operation retained a Rust slot");

      declare
         Set : aliased Flyology.Operations.Completion_Set (1);
         Job : constant Rust_Async_Jobs.Job_Operation :=
           Rust_Async_Jobs.Start
             (Set'Access, Runtime, Rust_Async_Jobs.Complete_Immediately, 0.0, 42);
      begin
         Check (Flyology.Operations.Is_Active (Job), "early Rust job was not registered");
         --  The retained wake is drained by operation finalization before the
         --  controlled Rust lease releases the terminal job.
      end;
      Check
        (Rust_Async_Jobs.Active_Jobs (Runtime) = 0,
         "abandoned early completion retained a Rust slot");
   end Exercise_Abandonment;

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
         Exercise_Shared_Wake_And_Races ("native");
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
         Exercise_Shared_Wake_And_Races ("lightweight");
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

   Exercise_Slot_Exhaustion;
   Exercise_Busy_Shutdown;
   Exercise_Abandonment;
   Rust_Async_Jobs.Shutdown (Runtime);
   Ada.Text_IO.Put_Line
     ("PASS Ada hosts Rust async stress: shared wakes, slot reuse, races, shutdown, and same-group progress");
exception
   when Error : others =>
      Ada.Text_IO.Put_Line (Ada.Exceptions.Exception_Information (Error));
      raise;
end Ada_Hosts_Spike;
