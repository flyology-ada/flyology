with Ada.Real_Time;
with Ada.Text_IO;
with Flyology.Channels.Bounded;
with Flyology.Operations;

--  Reproduce issue #137's send path with pending receives that do not run
--  until the timed batch has finished. Each row is the median of seven runs.

procedure Channel_Subscription_Benchmark is
   package Channels is new Flyology.Channels.Bounded (Integer, 0);

   use type Ada.Real_Time.Time;
   use type Channels.Try_Send_Result;

   Sends : constant := 20_000;
   type Samples is array (1 .. 7) of Duration;

   function Measure (Subscribers : Natural) return Duration is
      Channel : aliased Channels.Channel (Capacity => Sends);
      Set     : aliased Flyology.Operations.Completion_Set (24);
      type Operation_Array is
        array (Positive range <>)
        of aliased Channels.Receive_Operation (Set'Access);
      Pending : Operation_Array (1 .. 24);
      Result  : Channels.Try_Send_Result;
      Started : Ada.Real_Time.Time;
   begin
      for Index in 1 .. Subscribers loop
         Channels.Receive (Channel'Access, 60.0, Pending (Index));
      end loop;
      Started := Ada.Real_Time.Clock;
      for Index in 1 .. Sends loop
         Channel.Try_Send (Index, Result);
         if Result /= Channels.Item_Sent then
            raise Program_Error
              with "benchmark channel did not accept a value";
         end if;
      end loop;
      declare
         Elapsed : constant Duration :=
           Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
      begin
         for Index in 1 .. Subscribers loop
            Flyology.Operations.Cancel (Pending (Index));
         end loop;
         return Elapsed;
      end;
   end Measure;

   procedure Report (Subscribers : Natural) is
      Times : Samples;
      Swap  : Duration;
   begin
      for Index in Times'Range loop
         Times (Index) := Measure (Subscribers);
      end loop;
      for Left in Times'First .. Times'Last - 1 loop
         for Right in Left + 1 .. Times'Last loop
            if Times (Right) < Times (Left) then
               Swap := Times (Left);
               Times (Left) := Times (Right);
               Times (Right) := Swap;
            end if;
         end loop;
      end loop;
      Ada.Text_IO.Put_Line
        (Natural'Image (Subscribers)
         & " subscribers: "
         & Duration'Image (Times (4))
         & " s / 20,000 sends");
   end Report;
begin
   Report (0);
   Report (1);
   Report (8);
   Report (24);
end Channel_Subscription_Benchmark;
