with Ada.Exceptions;
with Ada.Streams;
with Ada.Text_IO;
with Direct_IO_Futures_Bridge;
with Flyology;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.Operations;
with Interfaces;

procedure Direct_IO_Futures_Spike is
   use type Ada.Streams.Stream_Element_Offset;
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

   task type Delayed_Sender
     (Socket       : not null access Flyology.IO.Sockets.Socket_Type;
      Delay_Millis : Natural)
     with CPU => 1
   is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Delayed_Sender;

   task body Delayed_Sender is
      Data : constant Ada.Streams.Stream_Element_Array := [1 => 42];
      Last : Ada.Streams.Stream_Element_Offset;
   begin
      delay Duration (Delay_Millis) / 1_000.0;
      Flyology.IO.Sockets.Send_Socket (Socket.all, Data, Last);
      Check (Last = Data'Last, "same-group sender did not write one byte");
   end Delayed_Sender;

   procedure Await_Value
     (Kind         : Direct_IO_Futures_Bridge.Future_Kind;
      First_FD     : Flyology.IO.Descriptor;
      Second_FD    : Flyology.IO.Descriptor;
      Delay_Millis : Natural;
      Input_Value  : Long_Long_Integer;
      Offset       : Long_Long_Integer := 0)
   is
      Set    : aliased Flyology.Operations.Completion_Set (1);
      Item   : Direct_IO_Futures_Bridge.Future_Operation (Set'Access);
      Result : Long_Long_Integer;
   begin
      Direct_IO_Futures_Bridge.Start (Item, Kind, First_FD, Second_FD, Delay_Millis, Input_Value);
      Flyology.Operations.Wait_All (Set);
      Direct_IO_Futures_Bridge.Finish (Item, Result);
      Check (Result = Input_Value + Offset, "Rust future returned the wrong value");
   end Await_Value;

   procedure Open_Pair
     (Left : in out Flyology.IO.Sockets.Socket_Type; Right : in out Flyology.IO.Sockets.Socket_Type) is
   begin
      Flyology.IO.Sockets.Create_Socket_Pair (Left, Right);
      Flyology.IO.Sockets.Prepare (Left);
      Flyology.IO.Sockets.Prepare (Right);
   end Open_Pair;

   procedure Close_Pair
     (Left : in out Flyology.IO.Sockets.Socket_Type; Right : in out Flyology.IO.Sockets.Socket_Type) is
   begin
      Flyology.IO.Sockets.Close_Socket (Left);
      Flyology.IO.Sockets.Close_Socket (Right);
   end Close_Pair;

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
      Direct_IO_Futures_Bridge.Reset_Observations;

      --  A Rust timer future publishes only a Flyology monotonic deadline.
      State.Begin_Tick_Window;
      Await_Value
        (Direct_IO_Futures_Bridge.Delay_Only,
         Flyology.IO.Invalid_Descriptor,
         Flyology.IO.Invalid_Descriptor,
         30,
         10);
      State.End_Tick_Window (Ticks);
      Check (Ticks > 0, "same-group ticker made no progress during a Rust timer future");

      --  Rust borrows the readable descriptor. A same-group Ada task owns the
      --  peer and makes it ready after the owner task has suspended.
      declare
         Left  : aliased Flyology.IO.Sockets.Socket_Type;
         Right : aliased Flyology.IO.Sockets.Socket_Type;
      begin
         Open_Pair (Left, Right);
         declare
            Sender : Delayed_Sender (Right'Access, 25);
            pragma Unreferenced (Sender);
         begin
            State.Begin_Tick_Window;
            Await_Value
              (Direct_IO_Futures_Bridge.Read_One,
               Flyology.IO.Sockets.Native_Descriptor (Left),
               Flyology.IO.Invalid_Descriptor,
               0,
               20);
            State.End_Tick_Window (Ticks);
            Check (Ticks > 0, "same-group tasks did not progress during Rust descriptor readiness");
         end;
         Close_Pair (Left, Right);
      end;

      --  The byte exists before the first poll. Rust deliberately returns
      --  Pending once, and the later Flyology arm must still observe it.
      declare
         Left  : Flyology.IO.Sockets.Socket_Type;
         Right : Flyology.IO.Sockets.Socket_Type;
         Data  : constant Ada.Streams.Stream_Element_Array := [1 => 43];
         Last  : Ada.Streams.Stream_Element_Offset;
      begin
         Open_Pair (Left, Right);
         Flyology.IO.Sockets.Send_Socket (Right, Data, Last);
         Check (Last = Data'Last, "ready-before-arm setup did not write one byte");
         Await_Value
           (Direct_IO_Futures_Bridge.Ready_Before_Arm,
            Flyology.IO.Sockets.Native_Descriptor (Left),
            Flyology.IO.Invalid_Descriptor,
            0,
            30);
         Close_Pair (Left, Right);
      end;

      --  One poll can publish two descriptors and one deadline. Readiness of
      --  the second descriptor wins and Rust retries both nonblocking reads.
      declare
         Left_1  : Flyology.IO.Sockets.Socket_Type;
         Right_1 : Flyology.IO.Sockets.Socket_Type;
         Left_2  : Flyology.IO.Sockets.Socket_Type;
         Right_2 : aliased Flyology.IO.Sockets.Socket_Type;
      begin
         Open_Pair (Left_1, Right_1);
         Open_Pair (Left_2, Right_2);
         declare
            Sender : Delayed_Sender (Right_2'Access, 25);
            pragma Unreferenced (Sender);
         begin
            Await_Value
              (Direct_IO_Futures_Bridge.Read_Either,
               Flyology.IO.Sockets.Native_Descriptor (Left_1),
               Flyology.IO.Sockets.Native_Descriptor (Left_2),
               250,
               42,
               2);
         end;
         Close_Pair (Left_1, Right_1);
         Close_Pair (Left_2, Right_2);
      end;

      --  Direction is part of the interest record; a fresh local socket is
      --  writable and should repoll without Rust performing a blocking call.
      declare
         Left  : Flyology.IO.Sockets.Socket_Type;
         Right : Flyology.IO.Sockets.Socket_Type;
      begin
         Open_Pair (Left, Right);
         Await_Value
           (Direct_IO_Futures_Bridge.Write_Ready,
            Flyology.IO.Sockets.Native_Descriptor (Left),
            Flyology.IO.Invalid_Descriptor,
            0,
            50);
         Close_Pair (Left, Right);
      end;

      --  Cancellation destroys the Rust future before the sole Ada owners
      --  close either borrowed descriptor.
      declare
         Left      : Flyology.IO.Sockets.Socket_Type;
         Right     : Flyology.IO.Sockets.Socket_Type;
         Set       : aliased Flyology.Operations.Completion_Set (1);
         Item      : Direct_IO_Futures_Bridge.Future_Operation (Set'Access);
         Value     : Long_Long_Integer;
         Cancelled : Boolean := False;
      begin
         Open_Pair (Left, Right);
         Direct_IO_Futures_Bridge.Start
           (Item,
            Direct_IO_Futures_Bridge.Never_Read,
            Flyology.IO.Sockets.Native_Descriptor (Left),
            Flyology.IO.Invalid_Descriptor,
            0,
            0);
         Flyology.Operations.Cancel (Item);
         Flyology.Operations.Wait_All (Set);
         begin
            Direct_IO_Futures_Bridge.Finish (Item, Value);
         exception
            when Flyology.Operations.Operation_Cancelled =>
               Cancelled := True;
         end;
         Check (Cancelled, "cancelled Rust future did not report cancellation");
         Close_Pair (Left, Right);
      end;

      Check (Direct_IO_Futures_Bridge.Poll_Count >= 11, "too few serialized Rust poll steps ran");
      Check (Direct_IO_Futures_Bridge.Concurrent_Polls = 0, "Rust futures were polled concurrently");
      Check (Direct_IO_Futures_Bridge.Drop_Count = 6, "not every Rust future was destroyed exactly once");
      State.Report (True, "");
   exception
      when Error : others =>
         State.Report
           (False,
            "direct I/O futures spike failed: "
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
      raise Program_Error with "direct I/O Rust future spike failed";
   end if;
   Ada.Text_IO.Put_Line ("direct I/O Rust future spike: PASS");
end Direct_IO_Futures_Spike;
