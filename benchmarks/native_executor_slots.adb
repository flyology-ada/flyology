with Ada.Real_Time;
with Ada.Text_IO;
with Flyology.Cancellation;
with Flyology.Native_Executors;

--  Measure complete native round trips with one free slot. A large retained
--  set makes a linear free-slot search traverse nearly the whole capacity;
--  worker dispatch, wakes, execution, and result transfer remain in the time.
procedure Native_Executor_Slots is
   use type Ada.Real_Time.Time;

   procedure Work
     (Input    : Integer;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time;
      Result   : out Integer)
   is
      pragma Unreferenced (Token, Deadline);
   begin
      Result := Input;
   end Work;

   package Executors is new Flyology.Native_Executors (Integer, Integer, Work);

   function Measure (Capacity : Positive; Rounds : Positive) return Long_Float is
      Item : aliased Executors.Executor (Workers => 1, Capacity => Capacity);
      type Handle_Array is array (Positive range <>) of Executors.Operation_Handle (Item'Access);
      Handles  : Handle_Array (1 .. Capacity);
      Accepted : Boolean;
      Result   : Integer;
      Started  : Ada.Real_Time.Time;
      Elapsed  : Duration;
   begin
      Executors.Start (Item);
      for Index in Handles'Range loop
         loop
            Executors.Submit
              (Item, Index, null, Ada.Real_Time.Time_Last, Handles (Index), Accepted);
            exit when Accepted;
            delay 0.0;
         end loop;
      end loop;
      Executors.Await (Item, Handles (Capacity), Result);
      if Result /= Capacity then
         raise Program_Error with "native executor warmup returned the wrong result";
      end if;

      Started := Ada.Real_Time.Clock;
      for Index in 1 .. Rounds loop
         Executors.Submit
           (Item, Index, null, Ada.Real_Time.Time_Last, Handles (Capacity), Accepted);
         if not Accepted then
            raise Program_Error with "native executor round trip was rejected";
         end if;
         Executors.Await (Item, Handles (Capacity), Result);
         if Result /= Index then
            raise Program_Error with "native executor round trip returned the wrong result";
         end if;
      end loop;
      Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);

      for Index in 1 .. Capacity - 1 loop
         Executors.Await (Item, Handles (Index), Result);
         if Result /= Index then
            raise Program_Error with "native executor retained result changed";
         end if;
      end loop;
      Executors.Shutdown (Item);
      return Long_Float (Elapsed) * 1_000_000_000.0 / Long_Float (Rounds);
   end Measure;

   Rounds : constant Positive := 10_000;
begin
   Ada.Text_IO.Put_Line
     ("native_executor_roundtrip_ns capacity=1 retained=0 rounds="
      & Positive'Image (Rounds) & " value=" & Long_Float'Image (Measure (1, Rounds)));
   Ada.Text_IO.Put_Line
     ("native_executor_roundtrip_ns capacity=1024 retained=1023 rounds="
      & Positive'Image (Rounds) & " value=" & Long_Float'Image (Measure (1_024, Rounds)));
end Native_Executor_Slots;
