with Ada.Exceptions;
with Ada.Text_IO;
with Flyology;
with Flyology.IO.Timers;
with Flyology.Operations;
with Interfaces;
with Rust_Async_IO;

procedure Tokio_IO_Spike is
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_32;
   use type Rust_Async_IO.Byte_Array;

   Runtime : aliased Rust_Async_IO.Engine;

   protected Results is
      procedure Complete (Lightweight : Boolean; Passed : Boolean);
      entry Await_Native (Passed : out Boolean);
      entry Await_Lightweight (Passed : out Boolean);
      entry Await_Ticker_Start;
      procedure Start_Ticker_Window;
      procedure Stop_Ticker_Window;
      procedure Tick;
      function Ticks_During_Wait return Natural;
   private
      Native_Done      : Boolean := False;
      Native_OK        : Boolean := False;
      Lightweight_Done : Boolean := False;
      Lightweight_OK   : Boolean := False;
      Ticker_Started   : Boolean := False;
      Ticker_Window    : Boolean := False;
      Ticks            : Natural := 0;
   end Results;

   protected body Results is
      procedure Complete (Lightweight : Boolean; Passed : Boolean) is
      begin
         if Lightweight then
            Lightweight_OK := Passed;
            Lightweight_Done := True;
         else
            Native_OK := Passed;
            Native_Done := True;
         end if;
      end Complete;

      entry Await_Native (Passed : out Boolean) when Native_Done is
      begin
         Passed := Native_OK;
      end Await_Native;

      entry Await_Lightweight (Passed : out Boolean) when Lightweight_Done is
      begin
         Passed := Lightweight_OK;
      end Await_Lightweight;

      entry Await_Ticker_Start when Ticker_Started is
      begin
         null;
      end Await_Ticker_Start;

      procedure Start_Ticker_Window is
      begin
         Ticker_Window := True;
         Ticker_Started := True;
      end Start_Ticker_Window;

      procedure Stop_Ticker_Window is
      begin
         Ticker_Window := False;
      end Stop_Ticker_Window;

      procedure Tick is
      begin
         if Ticker_Window then
            Ticks := Ticks + 1;
         end if;
      end Tick;

      function Ticks_During_Wait return Natural
      is (Ticks);
   end Results;

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   procedure Exercise_Success
     (Complete_Before_Arm : Boolean := False; Slow : Boolean := False)
   is
      Payload_Length : constant Positive := (if Slow then 32 else 31);
      Guard          : constant Interfaces.Unsigned_8 := 16#D3#;
      Untouched      : constant Interfaces.Unsigned_8 := 16#7C#;
      Input          : Rust_Async_IO.Byte_Array (1 .. Payload_Length + 2) :=
        [others => Guard];
      Output         : Rust_Async_IO.Byte_Array (1 .. Payload_Length + 2) :=
        [others => Untouched];
      Set            : aliased Flyology.Operations.Completion_Set (1);
      Job            : Rust_Async_IO.IO_Operation :=
        Rust_Async_IO.Start
          (Set'Access,
           Runtime,
           Input (2 .. Payload_Length + 1),
           Chunk_Size          => 3,
           Step_Delay          => (if Slow then 0.005 else 0.0),
           Complete_Before_Arm => Complete_Before_Arm);
      Stats          : Rust_Async_IO.Progress;
      Length         : Natural;
   begin
      if Complete_Before_Arm then
         Check
           (Rust_Async_IO.Published_Before_Arm (Job),
            "Tokio I/O did not publish before the test-only late arm");
      end if;
      --  Start copied the input. Replacing every borrowed payload byte now
      --  must not affect the response retained by Rust.
      for Index in 1 .. Payload_Length loop
         Input (Index + 1) := 16#EE#;
      end loop;
      Check
        (Input (1) = Guard and then Input (Input'Last) = Guard,
         "input canary changed after Start");

      if Slow then
         Results.Start_Ticker_Window;
      end if;
      Flyology.Operations.Wait_All (Set);
      if Slow then
         Results.Stop_Ticker_Window;
      end if;

      Check
        (Output = Rust_Async_IO.Byte_Array'(Output'Range => Untouched),
         "Rust touched Ada output before typed Finish");
      Check
        (Rust_Async_IO.Active_Descriptors (Runtime) = 0,
         "terminal job still owned socket descriptors");
      Stats := Rust_Async_IO.Snapshot (Job);
      Check
        (Stats.Request_Writes > 1
         and then Stats.Request_Reads > 1
         and then Stats.Response_Writes > 1
         and then Stats.Response_Reads > 1,
         "duplex operation did not make partial progress in every direction");
      Rust_Async_IO.Finish (Job, Output (2 .. Payload_Length + 1), Length);
      Check
        (Length = Payload_Length,
         "typed Finish returned an unexpected length");
      Check
        (Output (1) = Untouched and then Output (Output'Last) = Untouched,
         "typed Finish crossed an output canary");
      for Index in 1 .. Payload_Length loop
         Check
           (Output (Index + 1) = (Guard xor 16#A5#),
            "typed Finish returned incorrect duplex data");
      end loop;
      Check
        (Rust_Async_IO.Active_Jobs (Runtime) = 0,
         "typed Finish retained a Rust slot");
   end Exercise_Success;

   procedure Exercise_Cancellation is
      Guard     : constant Interfaces.Unsigned_8 := 16#B4#;
      Input     : Rust_Async_IO.Byte_Array (1 .. 130) := [others => Guard];
      Output    : Rust_Async_IO.Byte_Array (1 .. 130) := [others => Guard];
      Set       : aliased Flyology.Operations.Completion_Set (1);
      Job       : Rust_Async_IO.IO_Operation :=
        Rust_Async_IO.Start
          (Set'Access,
           Runtime,
           Input (2 .. 129),
           Chunk_Size => 1,
           Step_Delay => 0.002);
      Before    : Rust_Async_IO.Progress;
      After     : Rust_Async_IO.Progress;
      Length    : Natural;
      Cancelled : Boolean := False;
   begin
      for Index in 2 .. 129 loop
         Input (Index) := 16#19#;
      end loop;
      delay 0.012;
      Before := Rust_Async_IO.Snapshot (Job);
      Flyology.Operations.Cancel (Job);
      Flyology.Operations.Wait_All (Set);
      After := Rust_Async_IO.Snapshot (Job);
      Check
        (Before.Request_Writes > 0,
         "cancellation did not race an I/O operation after partial progress");
      Check
        (After.Request_Writes < 128 or else After.Request_Reads < 128,
         "cancellation arrived only after request I/O completed");
      Check
        (Rust_Async_IO.Active_Descriptors (Runtime) = 0,
         "cancelled terminal job retained a socket descriptor");
      begin
         Rust_Async_IO.Finish (Job, Output (2 .. 129), Length);
      exception
         when Flyology.Operations.Operation_Cancelled =>
            Cancelled := True;
      end;
      Check (Cancelled, "I/O cancellation was not retained by typed Finish");
      Check
        (Input (1) = Guard and then Input (Input'Last) = Guard,
         "cancelled Rust job crossed an input canary");
      Check
        (Output (1) = Guard and then Output (Output'Last) = Guard,
         "cancelled Rust job crossed an output canary");
      Check
        (Rust_Async_IO.Active_Jobs (Runtime) = 0,
         "cancelled typed Finish retained a Rust slot");
   end Exercise_Cancellation;

   procedure Exercise_Abandonment is
      Guard : constant Interfaces.Unsigned_8 := 16#62#;
      Input : Rust_Async_IO.Byte_Array (1 .. 66) := [others => Guard];
   begin
      declare
         Set : aliased Flyology.Operations.Completion_Set (1);
         Job : constant Rust_Async_IO.IO_Operation :=
           Rust_Async_IO.Start
             (Set'Access,
              Runtime,
              Input (2 .. 65),
              Chunk_Size => 1,
              Step_Delay => 0.010);
      begin
         for Index in 2 .. 65 loop
            Input (Index) := 16#F1#;
         end loop;
         Check
           (Flyology.Operations.Is_Active (Job),
            "abandoned I/O job was not active");
      end;
      Check
        (Rust_Async_IO.Active_Jobs (Runtime) = 0,
         "abandoned I/O operation retained a Rust slot");
      Check
        (Rust_Async_IO.Active_Descriptors (Runtime) = 0,
         "abandoned I/O operation retained a descriptor");
      Check
        (Input (1) = Guard and then Input (Input'Last) = Guard,
         "abandoned I/O operation crossed an input canary");
   end Exercise_Abandonment;

   procedure Exercise_Lane (Lightweight : Boolean) is
   begin
      Exercise_Success;
      Exercise_Cancellation;
      Exercise_Abandonment;
      Results.Complete (Lightweight, True);
   exception
      when Error : others =>
         Ada.Text_IO.Put_Line (Ada.Exceptions.Exception_Information (Error));
         Results.Complete (Lightweight, False);
   end Exercise_Lane;

   Passed : Boolean;
begin
   Rust_Async_IO.Initialize (Runtime);

   declare
      task Native_Runner is
         pragma Task_Info (Flyology.Native_Task);
      end Native_Runner;

      task body Native_Runner is
      begin
         Exercise_Success (Complete_Before_Arm => True);
         Exercise_Lane (Lightweight => False);
      exception
         when Error : others =>
            Ada.Text_IO.Put_Line
              (Ada.Exceptions.Exception_Information (Error));
            Results.Complete (Lightweight => False, Passed => False);
      end Native_Runner;
   begin
      select
         Results.Await_Native (Passed);
      or
         delay 5.0;
         raise Program_Error with "native Tokio I/O runner did not report";
      end select;
      Check (Passed, "native Tokio I/O cases failed");
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
      begin
         Exercise_Success (Slow => True);
         Check
           (Results.Ticks_During_Wait = 5,
            "same-group ticker did not progress during Tokio socket I/O");
         Exercise_Lane (Lightweight => True);
      exception
         when Error : others =>
            Results.Stop_Ticker_Window;
            Ada.Text_IO.Put_Line
              (Ada.Exceptions.Exception_Information (Error));
            Results.Complete (Lightweight => True, Passed => False);
      end Lightweight_Runner;

      task body Ticker is
      begin
         Results.Await_Ticker_Start;
         for Step in 1 .. 5 loop
            Flyology.IO.Timers.Sleep_For (0.010);
            Results.Tick;
         end loop;
      end Ticker;
   begin
      select
         Results.Await_Lightweight (Passed);
      or
         delay 5.0;
         raise Program_Error
           with "lightweight Tokio I/O runner did not report";
      end select;
      Check (Passed, "lightweight Tokio I/O cases failed");
   end;

   Check
     (Rust_Async_IO.Active_Jobs (Runtime) = 0,
      "engine retained jobs before shutdown");
   Check
     (Rust_Async_IO.Active_Descriptors (Runtime) = 0,
      "engine retained descriptors before shutdown");
   Rust_Async_IO.Shutdown (Runtime);
   Ada.Text_IO.Put_Line
     ("PASS Ada-hosted Tokio duplex I/O: ownership, partial progress, cancellation, and abandonment");
exception
   when Error : others =>
      Ada.Text_IO.Put_Line (Ada.Exceptions.Exception_Information (Error));
      raise;
end Tokio_IO_Spike;
