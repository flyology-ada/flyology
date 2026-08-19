--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Command_Line;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Text_IO;
with Flyology;
with Flyology.Execution_Groups;
with Flyology.IO.Sockets;
with Flyology.Observability;
with Interfaces;

--  Report how often an event loop takes its idle path, which is the frequency
--  at which the loop's utilization accounting reads the monotonic clock.
--  Multiplying this rate by the cost of two readings, which
--  runtime_callback_bench reports as monotonic_clock_read, gives that
--  accounting's share of a loop's time directly, without needing a
--  differential timing measurement fine enough to resolve it.
--
--  Two lightweight tasks on separate groups exchange one byte over a connected
--  socket pair. Each round trip leaves both loops with nothing ready, so both
--  take the idle path once per trip, which is close to the highest sustained
--  rate a loop doing real work can reach.
procedure Idle_Wait_Rate is
   package Observation renames Flyology.Observability;
   package Groups renames Flyology.Execution_Groups;
   package Sockets renames Flyology.IO.Sockets;
   package Real_Time renames Ada.Real_Time;

   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.Unsigned_64;
   use type Real_Time.Time;

   Window : constant Duration :=
     (if Ada.Command_Line.Argument_Count >= 1
      then Duration'Value (Ada.Command_Line.Argument (1))
      else 2.0);

   Left  : Sockets.Socket_Type;
   Right : Sockets.Socket_Type;

   Payload : constant Ada.Streams.Stream_Element_Array (1 .. 1) := (1 => 7);

   procedure Show (Group : Groups.Group_Id; Label : String) is
      Item    : Observation.Group_Snapshot;
      Seconds : Long_Float;
   begin
      if not Observation.Snapshot (Group, Item) then
         Ada.Text_IO.Put_Line (Label & ": no snapshot");
         return;
      end if;
      if Item.Uptime_Nanoseconds = 0 then
         Ada.Text_IO.Put_Line (Label & ": loop has not started");
         return;
      end if;
      Seconds := Long_Float (Item.Uptime_Nanoseconds) / 1.0E9;
      Ada.Text_IO.Put_Line
        (Label
         & " idle_waits=" & Item.Idle_Waits'Image
         & " uptime_s=" & Long_Float'Image (Seconds)
         & " waits_per_second="
         & Long_Float'Image (Long_Float (Item.Idle_Waits) / Seconds)
         & " idle_fraction="
         & Long_Float'Image
             (Long_Float (Item.Idle_Nanoseconds)
              / Long_Float (Item.Uptime_Nanoseconds)));
   end Show;

   Trips : Interfaces.Unsigned_64 := 0;
begin
   --  Open the pair before the exchange tasks activate.
   Sockets.Create_Socket_Pair (Left, Right);

   declare
      task Echo is
         pragma Task_Info (Flyology.Lightweight_Task);
         pragma CPU (2);
      end Echo;

      task body Echo is
         Item : Ada.Streams.Stream_Element_Array (1 .. 1);
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         loop
            Sockets.Receive (Right, Item, Last);
            exit when Last < Item'First;
            Sockets.Send (Right, Item (Item'First .. Last), Last);
            exit when Last < Item'First;
         end loop;
      exception
         --  The driver closes its end to stop this loop.
         when others =>
            null;
      end Echo;

      task Driver is
         pragma Task_Info (Flyology.Lightweight_Task);
         pragma CPU (1);
         entry Report (Count : out Interfaces.Unsigned_64);
      end Driver;

      task body Driver is
         Item     : Ada.Streams.Stream_Element_Array (1 .. 1);
         Last     : Ada.Streams.Stream_Element_Offset;
         Deadline : constant Real_Time.Time :=
           Real_Time.Clock + Real_Time.To_Time_Span (Window);
         Total    : Interfaces.Unsigned_64 := 0;
      begin
         while Real_Time.Clock < Deadline loop
            Sockets.Send (Left, Payload, Last);
            exit when Last < Payload'First;
            Sockets.Receive (Left, Item, Last);
            exit when Last < Item'First;
            Total := Total + 1;
         end loop;
         accept Report (Count : out Interfaces.Unsigned_64) do
            Count := Total;
         end Report;
      exception
         when others =>
            null;
      end Driver;
   begin
      Driver.Report (Trips);
      --  Close the driver's end inside the block so the echo task sees end of
      --  stream and terminates; the block cannot complete until it does.
      Sockets.Close_Socket (Left);
   end;

   Sockets.Close_Socket (Right);

   Ada.Text_IO.Put_Line ("round_trips=" & Trips'Image);
   Show (Groups.For_CPU (1), "driver_group");
   Show (Groups.For_CPU (2), "echo_group");
end Idle_Wait_Rate;
