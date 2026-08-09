--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Text_IO;
with Flyology_Debug;
with Flyology_Debug.Gauges;
with Flyology_Debug.Tracers;
with Interfaces;

procedure Flyology_Debug_Smoke is
   use type Flyology_Debug.Timestamp;
   use type Interfaces.Unsigned_64;

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   type Event_Kind is (Accepted, Completed);
   type Message is record
      Kind  : Event_Kind;
      Value : Integer;
   end record;
   type Gauge is (Queue_Depth, Active_Requests);

   Fake_Time : Flyology_Debug.Timestamp := 1_000;

   function Fake_Clock return Flyology_Debug.Timestamp is
      Result : constant Flyology_Debug.Timestamp := Fake_Time;
   begin
      Fake_Time := Fake_Time + 10;
      return Result;
   end Fake_Clock;

   Counting_Clock_Calls : Natural := 0;

   function Counting_Clock return Flyology_Debug.Timestamp is
   begin
      Counting_Clock_Calls := Counting_Clock_Calls + 1;
      return Flyology_Debug.Timestamp (Counting_Clock_Calls);
   end Counting_Clock;

   function Concurrent_Clock return Flyology_Debug.Timestamp is (0);

   Merge_Time : Flyology_Debug.Timestamp := 100;

   function Merge_Clock return Flyology_Debug.Timestamp is
      Result : constant Flyology_Debug.Timestamp := Merge_Time;
   begin
      Merge_Time := Merge_Time + 10;
      return Result;
   end Merge_Clock;

   Selection_Calls : Natural := 0;

   function Select_Second (Producer_Count : Positive) return Positive is
   begin
      Selection_Calls := Selection_Calls + 1;
      return (if Producer_Count = 1 then 1 else 2);
   end Select_Second;

   function Select_Outside (Producer_Count : Positive) return Positive is
     (Producer_Count + 1);

   package Wrapping is new Flyology_Debug.Tracers
     (Message_Type => Message,
      Capacity     => 3,
      Overflow     => Flyology_Debug.Overwrite_Oldest);

   package Blocking is new Flyology_Debug.Tracers
     (Message_Type => Integer,
      Capacity     => 1,
      Overflow     => Flyology_Debug.Block_Producer);

   package Dropping is new Flyology_Debug.Tracers
     (Message_Type => Integer,
      Capacity     => 2,
      Overflow     => Flyology_Debug.Drop_Newest,
      Now          => Fake_Clock);

   package Pausing is new Flyology_Debug.Tracers
     (Message_Type => Integer,
      Capacity     => 1,
      Overflow     => Flyology_Debug.Block_Producer);

   package Polling is new Flyology_Debug.Tracers
     (Message_Type => Integer,
      Capacity     => 1,
      Overflow     => Flyology_Debug.Block_Producer,
      Now          => Counting_Clock);

   package Sharded is new Flyology_Debug.Tracers
     (Message_Type   => Integer,
      Capacity       => 32,
      Overflow       => Flyology_Debug.Overwrite_Oldest,
      Now            => Concurrent_Clock,
      Producer_Count => 4);

   package Merging is new Flyology_Debug.Tracers
     (Message_Type    => Integer,
      Capacity        => 4,
      Now             => Merge_Clock,
      Producer_Count  => 2,
      Select_Producer => Select_Second);

   package Invalid_Selection is new Flyology_Debug.Tracers
     (Message_Type    => Integer,
      Capacity        => 1,
      Now             => Merge_Clock,
      Producer_Count  => 2,
      Select_Producer => Select_Outside);

   package Reservations is new Flyology_Debug.Tracers
     (Message_Type   => Integer,
      Capacity       => 2,
      Now            => Concurrent_Clock,
      Producer_Count => 2);

   package Metrics is new Flyology_Debug.Gauges
     (Gauge_Kind       => Gauge,
      Gauge_Value_Type => Integer,
      Now              => Fake_Clock);

   Wrapped         : Wrapping.Batch;
   Retained_Copy   : Wrapping.Batch;
   Blocked_Copy    : Blocking.Batch;
   Gauges          : Metrics.Snapshot;
   Retained_Gauges : Metrics.Snapshot;
   Accepted_Now    : Boolean;
begin
   declare
      Rejected : Boolean := False;
   begin
      begin
         Invalid_Selection.Trace (1);
      exception
         when Constraint_Error =>
            Rejected := True;
      end;
      Check (Rejected, "out-of-range automatic producer was accepted");
   end;

   for Value in 1 .. 5 loop
      Wrapping.Trace
        ((Kind  => (if Value = 5 then Completed else Accepted),
          Value => Value));
   end loop;
   Metrics.Set (Queue_Depth, 7);
   Metrics.Set (Queue_Depth, 4);
   Metrics.Set (Active_Requests, 2);
   Wrapping.Take (Retained_Copy);
   Metrics.Read (Retained_Gauges);

   Check
     (Wrapping.Trace_Count (Retained_Copy) = 3, "wrapping count is wrong");
   Check
     (Wrapping.Message_Of (Wrapping.Trace_At (Retained_Copy, 1)).Value = 3,
      "wrapping did not discard the oldest message");
   Check
     (Wrapping.Message_Of (Wrapping.Trace_At (Retained_Copy, 3)).Value = 5,
      "wrapping did not retain the newest message");
   Check
     (Wrapping.Overwrites (Retained_Copy) = 2, "overwrite count is wrong");
   Check
     (Wrapping.Sequence_Of (Wrapping.Trace_At (Retained_Copy, 1)) = 3 and then
      Wrapping.Sequence_Of (Wrapping.Trace_At (Retained_Copy, 3)) = 5,
      "admission sequence did not follow retained order");
   Check
     (Wrapping.Timestamp_Of (Wrapping.Trace_At (Retained_Copy, 1)) <=
      Wrapping.Timestamp_Of (Wrapping.Trace_At (Retained_Copy, 3)),
      "trace timestamps are not chronological");
   Check
     (Metrics.Is_Set (Retained_Gauges, Queue_Depth),
      "updated gauge is not set");
   Check
     (Metrics.Value_Of (Retained_Gauges, Queue_Depth) = 4,
      "gauge did not retain its latest value");
   Check
     (Metrics.Timestamp_Of (Retained_Gauges, Queue_Depth) = 1_010,
      "gauge did not use the injected clock");

   declare
      Stats         : constant Wrapping.Batch_Statistics :=
        Wrapping.Statistics (Retained_Copy);
      Visited       : Natural := 0;
      Value_Total   : Integer := 0;
      First_Visited : Wrapping.Sequence_Number := 0;
      Last_Visited  : Wrapping.Sequence_Number := 0;

      procedure Observe
        (Sequence    : Wrapping.Sequence_Number;
         Captured_At : Flyology_Debug.Timestamp;
         Payload     : not null access constant Message)
      is
      begin
         Check (Captured_At > 0, "borrowed visit returned an empty timestamp");
         Visited := Visited + 1;
         Value_Total := Value_Total + Payload.Value;
         if Visited = 1 then
            First_Visited := Sequence;
         end if;
         Last_Visited := Sequence;
      end Observe;
   begin
      Check
        (Stats.Retained = 3 and then
         Stats.Overwritten = 2 and then
         Stats.Dropped = 0 and then
         Stats.Has_Traces and then
         Stats.First_Sequence = 3 and then
         Stats.Last_Sequence = 5,
         "wrapping batch statistics are wrong");
      Wrapping.Visit (Retained_Copy, Observe'Access);
      Check
        (Visited = 3 and then Value_Total = 12 and then
         First_Visited = 3 and then Last_Visited = 5,
         "borrowed visit did not preserve retained order");
   end;

   Wrapping.Release (Retained_Copy);
   Check
     (not Wrapping.Is_Acquired (Retained_Copy),
      "released trace batch still reports acquired");
   Wrapping.Take (Wrapped);
   Check (Wrapping.Trace_Count (Wrapped) = 0, "trace clear did not persist");
   Check (Wrapping.Overwrites (Wrapped) = 0, "clear kept overwrite count");
   Wrapping.Release (Wrapped);

   Metrics.Read (Gauges);
   Check
     (Metrics.Is_Set (Gauges, Queue_Depth) and then
      Metrics.Value_Of (Gauges, Queue_Depth) = 4,
      "gauge did not persist across trace collection");
   Metrics.Clear;
   Metrics.Read (Gauges);
   Check
     (not Metrics.Is_Set (Gauges, Queue_Depth),
      "gauge clear did not persist");
   Check
     (Metrics.Is_Set (Retained_Gauges, Queue_Depth) and then
      Metrics.Value_Of (Retained_Gauges, Queue_Depth) = 4,
      "a later read changed an earlier gauge snapshot");

   declare
      Failed : Boolean := False;
   begin
      begin
         if Metrics.Value_Of (Gauges, Queue_Depth) = 0 then
            null;
         end if;
      exception
         when Constraint_Error =>
            Failed := True;
      end;
      Check (Failed, "unset gauge value did not fail closed");
   end;

   Wrapping.Trace ((Kind => Accepted, Value => 30));
   declare
      First        : Wrapping.Batch;
      Second       : Wrapping.Batch;
      First_Count  : Natural := 0;
      Second_Count : Natural := 0;
      First_Value  : Integer := 0;
      Second_Value : Integer := 0;

      protected Completion is
         procedure Release_Readers;
         entry Await_Start;
         procedure Mark_Done;
         entry Wait_All_Done;
      private
         Released : Boolean := False;
         Done     : Natural := 0;
      end Completion;

      protected body Completion is
         procedure Release_Readers is
         begin
            Released := True;
         end Release_Readers;

         entry Await_Start when Released is
         begin
            null;
         end Await_Start;

         procedure Mark_Done is
         begin
            Done := Done + 1;
         end Mark_Done;

         entry Wait_All_Done when Done = 2 is
         begin
            null;
         end Wait_All_Done;
      end Completion;

      task First_Reader;
      task Second_Reader;

      task body First_Reader is
      begin
         Completion.Await_Start;
         Wrapping.Take (First);
         First_Count := Wrapping.Trace_Count (First);
         if First_Count = 1 then
            First_Value :=
              Wrapping.Message_Of (Wrapping.Trace_At (First, 1)).Value;
         end if;
         Wrapping.Release (First);
         Completion.Mark_Done;
      end First_Reader;

      task body Second_Reader is
      begin
         Completion.Await_Start;
         Wrapping.Take (Second);
         Second_Count := Wrapping.Trace_Count (Second);
         if Second_Count = 1 then
            Second_Value :=
              Wrapping.Message_Of (Wrapping.Trace_At (Second, 1)).Value;
         end if;
         Wrapping.Release (Second);
         Completion.Mark_Done;
      end Second_Reader;
   begin
      Completion.Release_Readers;
      Completion.Wait_All_Done;
      Check
        (First_Count + Second_Count = 1,
         "concurrent collections duplicated or lost retained history");
      Check
        ((First_Count = 1 and then First_Value = 30) or else
         (Second_Count = 1 and then Second_Value = 30),
         "concurrent collections returned the wrong message");
   end;

   Wrapping.Trace ((Kind => Accepted, Value => 40));
   declare
      protected Completion is
         procedure Mark_Acquired;
         entry Wait_Acquired;
      private
         Acquired : Boolean := False;
      end Completion;

      protected body Completion is
         procedure Mark_Acquired is
         begin
            Acquired := True;
         end Mark_Acquired;

         entry Wait_Acquired when Acquired is
         begin
            null;
         end Wait_Acquired;
      end Completion;

      task Holder;

      task body Holder is
         Held : Wrapping.Batch;
      begin
         Wrapping.Take (Held);
         Completion.Mark_Acquired;
         delay 60.0;
      end Holder;
   begin
      Completion.Wait_Acquired;
      abort Holder;
      while not Holder'Terminated loop
         delay 0.001;
      end loop;
   end;

   Wrapping.Trace ((Kind => Accepted, Value => 41));
   Wrapping.Take (Wrapped);
   Check
     (Wrapping.Trace_Count (Wrapped) = 1 and then
      Wrapping.Message_Of (Wrapping.Trace_At (Wrapped, 1)).Value = 41,
      "aborted consumer did not return its detached buffer");
   Wrapping.Release (Wrapped);

   declare
      Iterations : constant Positive := 32;

      protected Coordination is
         procedure Claim (Producer : out Sharded.Producer_Id);
         procedure Start;
         entry Await_Start;
         procedure Finish;
         entry Await_Finish;
      private
         Next_Producer : Natural := 0;
         Started       : Boolean := False;
         Finished      : Natural := 0;
      end Coordination;

      protected body Coordination is
         procedure Claim (Producer : out Sharded.Producer_Id) is
         begin
            Next_Producer := Next_Producer + 1;
            Producer := Sharded.Producer_Id (Next_Producer);
         end Claim;

         procedure Start is
         begin
            Started := True;
         end Start;

         entry Await_Start when Started is
         begin
            null;
         end Await_Start;

         procedure Finish is
         begin
            Finished := Finished + 1;
         end Finish;

         entry Await_Finish when Finished = Sharded.Producer_Id'Last is
         begin
            null;
         end Await_Finish;
      end Coordination;

      task type Writer;

      task body Writer is
         Producer : Sharded.Producer_Id;
      begin
         Coordination.Claim (Producer);
         Coordination.Await_Start;
         for Index in 1 .. Iterations loop
            Sharded.Trace
              (Producer * 1_000 + Index,
               Producer);
         end loop;
         Coordination.Finish;
      end Writer;

      Writers : array (Sharded.Producer_Id) of Writer;
      Held    : Sharded.Batch;
   begin
      Coordination.Start;
      Coordination.Await_Finish;

      for Producer in Sharded.Producer_Id loop
         Sharded.Take (Held, Producer);
         Check
           (Sharded.Producer_Of (Held) = Producer,
            "sharded batch reports the wrong producer");
         Check
           (Sharded.Trace_Count (Held) = Iterations,
            "sharded producer lost retained messages");
         Check
           (Sharded.Sequence_Of (Sharded.Trace_At (Held, 1)) = 1 and then
            Sharded.Sequence_Of (Sharded.Trace_At (Held, Iterations)) =
              Interfaces.Unsigned_64 (Iterations),
            "sharded admission sequence is not producer local");
         Check
           (Sharded.Message_Of (Sharded.Trace_At (Held, 1)) =
              Producer * 1_000 + 1
            and then
            Sharded.Message_Of (Sharded.Trace_At (Held, Iterations)) =
              Producer * 1_000 + Iterations,
            "sharded producer history crossed producer ids");
      end loop;
      Sharded.Release (Held);

      Sharded.Trace (10_001, 1);
      Sharded.Trace (20_001, 2);
      Sharded.Clear (1);
      Sharded.Take (Held, 1);
      Check
        (Sharded.Trace_Count (Held) = 0,
         "producer-specific clear retained its producer history");
      Sharded.Take (Held, 2);
      Check
        (Sharded.Producer_Of (Held) = 2 and then
         Sharded.Trace_Count (Held) = 1 and then
         Sharded.Message_Of (Sharded.Trace_At (Held, 1)) = 20_001,
         "producer-specific clear changed another producer");
      Sharded.Release (Held);
   end;

   Merging.Trace (20);
   Merging.Trace (10, 1);
   Merging.Trace (21);
   Merge_Time := 90;
   Merging.Trace (22);
   Check
     (Selection_Calls = 3,
      "automatic selection ran for an explicit producer or wrong count");
   Merging.Disable;
   Merging.Trace (22);
   Merging.Try_Trace (22, Accepted_Now);
   Check
     (not Accepted_Now and then Selection_Calls = 3,
      "disabled tracing invoked automatic producer selection");
   Merging.Enable;
   declare
      Merged    : Merging.Merged_Batch;
      Count     : Natural := 0;
      Values    : array (Positive range 1 .. 4) of Integer := (others => 0);
      Producers : array (Positive range 1 .. 4) of Merging.Producer_Id :=
        (others => 1);
      Sequences : array (Positive range 1 .. 4) of
        Merging.Sequence_Number := (others => 0);
      Captures  : array (Positive range 1 .. 4) of
        Flyology_Debug.Timestamp := (others => 0);

      procedure Observe
        (Producer    : Merging.Producer_Id;
         Sequence    : Merging.Sequence_Number;
         Captured_At : Flyology_Debug.Timestamp;
         Payload     : not null access constant Integer)
      is
      begin
         Check (Captured_At > 0, "merged visit lost its timestamp");
         Count := Count + 1;
         Values (Count) := Payload.all;
         Producers (Count) := Producer;
         Sequences (Count) := Sequence;
         Captures (Count) := Captured_At;
      end Observe;
   begin
      Merging.Take_Merged (Merged);
      declare
         Stats : constant Merging.Merged_Batch_Statistics :=
           Merging.Statistics (Merged);
      begin
         Check
           (Stats.Retained = 4 and then Stats.Overwritten = 0 and then
            Stats.Dropped = 0,
            "merged batch statistics are wrong");
      end;
      Merging.Visit_Merged (Merged, Observe'Access);
      Check
        (Count = 4 and then Values = [20, 10, 21, 22] and then
         Producers = [2, 1, 2, 2] and then Sequences = [1, 1, 2, 3]
         and then Captures = [100, 110, 120, 90],
         "merged visit did not preserve shard order or timestamp heads");
      Merging.Release (Merged);
      Check
        (not Merging.Is_Acquired (Merged),
         "released merged batch still reports acquired");
   end;

   --  A merged consumer must wait for an all-producer reservation without
   --  detaching producer one while producer two belongs to another consumer.
   --  Keeping Pending outside the merged task also checks that aborting the
   --  waiter cannot strand hidden ownership in a surviving result object.
   declare
      Held_Second : Reservations.Batch;
      Pending     : Reservations.Merged_Batch;
      First_Done  : Boolean := False;

      protected Coordination is
         procedure Mark_Held;
         entry Wait_Held;
         procedure Mark_Merged_Started;
         entry Wait_Merged_Started;
         procedure Allow_Holder_Release;
         entry Wait_Holder_Release;
         procedure Mark_First_Done;
         entry Wait_First_Done;
      private
         Held           : Boolean := False;
         Merged_Started : Boolean := False;
         Holder_Release : Boolean := False;
         First_Complete : Boolean := False;
      end Coordination;

      protected body Coordination is
         procedure Mark_Held is
         begin
            Held := True;
         end Mark_Held;

         entry Wait_Held when Held is
         begin
            null;
         end Wait_Held;

         procedure Mark_Merged_Started is
         begin
            Merged_Started := True;
         end Mark_Merged_Started;

         entry Wait_Merged_Started when Merged_Started is
         begin
            null;
         end Wait_Merged_Started;

         procedure Allow_Holder_Release is
         begin
            Holder_Release := True;
         end Allow_Holder_Release;

         entry Wait_Holder_Release when Holder_Release is
         begin
            null;
         end Wait_Holder_Release;

         procedure Mark_First_Done is
         begin
            First_Complete := True;
         end Mark_First_Done;

         entry Wait_First_Done when First_Complete is
         begin
            null;
         end Wait_First_Done;
      end Coordination;

      task Holder;
      task Merged_Waiter;
      task First_Reader;

      task body Holder is
      begin
         Reservations.Take (Held_Second, Producer => 2);
         Coordination.Mark_Held;
         Coordination.Wait_Holder_Release;
         Reservations.Release (Held_Second);
      end Holder;

      task body Merged_Waiter is
      begin
         Coordination.Wait_Held;
         Coordination.Mark_Merged_Started;
         Reservations.Take_Merged (Pending);
         Reservations.Release (Pending);
      end Merged_Waiter;

      task body First_Reader is
         First : Reservations.Batch;
      begin
         Coordination.Wait_Merged_Started;
         delay 0.010;
         Reservations.Take (First, Producer => 1);
         Reservations.Release (First);
         Coordination.Mark_First_Done;
      end First_Reader;
   begin
      Coordination.Wait_Held;
      Coordination.Wait_Merged_Started;
      delay 0.020;
      abort Merged_Waiter;
      while not Merged_Waiter'Terminated loop
         delay 0.001;
      end loop;
      select
         Coordination.Wait_First_Done;
         First_Done := True;
      or
         delay 1.0;
      end select;

      Coordination.Allow_Holder_Release;

      if not First_Done then
         Reservations.Release (Pending);
         Coordination.Wait_First_Done;
      end if;
      while not Holder'Terminated or else not First_Reader'Terminated loop
         delay 0.001;
      end loop;

      Check
        (First_Done,
         "merged acquisition retained a partial producer reservation");
      Check
        (not Reservations.Is_Acquired (Pending),
         "aborted merged waiter left a surviving reservation");
      Reservations.Take_Merged (Pending);
      Reservations.Release (Pending);
   end;

   Dropping.Trace (1);
   Dropping.Trace (2);
   Dropping.Trace (3);
   Dropping.Try_Trace (4, Accepted_Now);
   Check (not Accepted_Now, "full dropping tracer accepted Try_Trace");
   declare
      Dropped_Batch : Dropping.Batch;
   begin
      Dropping.Take (Dropped_Batch);
      declare
         Stats : constant Dropping.Batch_Statistics :=
           Dropping.Statistics (Dropped_Batch);
      begin
         Check
           (Stats.Retained = 2 and then Stats.Overwritten = 0 and then
            Stats.Dropped = 2 and then Stats.Has_Traces and then
            Stats.First_Sequence = 1 and then Stats.Last_Sequence = 2,
            "drop-newest batch statistics are wrong");
         Check
           (Dropping.Message_Of (Dropping.Trace_At (Dropped_Batch, 1)) = 1
            and then
            Dropping.Message_Of (Dropping.Trace_At (Dropped_Batch, 2)) = 2,
            "drop-newest did not preserve retained history");
         Check
           (Dropping.Timestamp_Of (Dropping.Trace_At (Dropped_Batch, 1)) =
              1_030
            and then
            Dropping.Timestamp_Of (Dropping.Trace_At (Dropped_Batch, 2)) =
              1_040,
            "tracer did not use the injected clock");
      end;
      Dropping.Release (Dropped_Batch);
   end;

   Pausing.Disable;
   Check (not Pausing.Is_Enabled, "disabled tracer reports enabled");
   Pausing.Trace (0);
   Pausing.Try_Trace (0, Accepted_Now);
   Check (not Accepted_Now, "disabled tracer accepted Try_Trace");
   Pausing.Enable;
   Check (Pausing.Is_Enabled, "enabled tracer reports disabled");
   Pausing.Trace (10);
   declare
      Held : Pausing.Batch;

      protected Completion is
         procedure Mark_Started;
         procedure Mark_Done;
         entry Wait_Started;
         entry Wait_Done;
         function Is_Done return Boolean;
      private
         Started : Boolean := False;
         Done    : Boolean := False;
      end Completion;

      protected body Completion is
         procedure Mark_Started is
         begin
            Started := True;
         end Mark_Started;

         procedure Mark_Done is
         begin
            Done := True;
         end Mark_Done;

         entry Wait_Started when Started is
         begin
            null;
         end Wait_Started;

         entry Wait_Done when Done is
         begin
            null;
         end Wait_Done;

         function Is_Done return Boolean is (Done);
      end Completion;

      task Writer;

      task body Writer is
      begin
         Completion.Mark_Started;
         Pausing.Trace (11);
         Completion.Mark_Done;
      end Writer;
   begin
      Completion.Wait_Started;
      Check
        (not Completion.Is_Done,
         "pausing producer completed before disable");
      Pausing.Disable;
      Completion.Wait_Done;
      Pausing.Take (Held);
      Check
        (Pausing.Trace_Count (Held) = 1 and then
         Pausing.Message_Of (Pausing.Trace_At (Held, 1)) = 10,
         "disable changed retained history or kept a blocked message");
      Pausing.Release (Held);
      Pausing.Enable;
      Pausing.Trace (12);
      Pausing.Take (Held);
      Check
        (Pausing.Trace_Count (Held) = 1 and then
         Pausing.Message_Of (Pausing.Trace_At (Held, 1)) = 12,
         "re-enabled tracer did not resume admission");
      Pausing.Release (Held);
   end;

   declare
      Held     : Polling.Batch;
      Rejected : Boolean := False;
   begin
      Check (Counting_Clock_Calls = 0, "counting clock started nonzero");
      Polling.Trace (1);
      Check
        (Counting_Clock_Calls = 1,
         "accepted trace did not call the injected clock exactly once");
      Polling.Try_Trace (2, Accepted_Now);
      Check
        (not Accepted_Now and then Counting_Clock_Calls = 1,
         "full blocking Try_Trace called the clock");

      Polling.Disable;
      Polling.Trace (3);
      Polling.Try_Trace (3, Accepted_Now);
      Check
        (not Accepted_Now and then Counting_Clock_Calls = 1,
         "disabled producer operation called the clock");

      Polling.Enable;
      Polling.Take (Held);
      Polling.Release (Held);
      Polling.Try_Trace (4, Accepted_Now);
      Check
        (Accepted_Now and then Counting_Clock_Calls = 2,
         "available blocking Try_Trace did not use the clock once");

      Polling.Close;
      Polling.Try_Trace (5, Accepted_Now);
      Check
        (not Accepted_Now and then Counting_Clock_Calls = 2,
         "closed Try_Trace called the clock");
      begin
         Polling.Trace (5);
      exception
         when Flyology_Debug.Closed_Error =>
            Rejected := True;
      end;
      Check
        (Rejected and then Counting_Clock_Calls = 2,
         "closed Trace called the clock or failed to reject");
   end;

   Blocking.Try_Trace (10, Accepted_Now);
   Check (Accepted_Now, "empty blocking tracer declined a message");
   Blocking.Try_Trace (11, Accepted_Now);
   Check (not Accepted_Now, "full blocking tracer accepted Try_Trace");

   declare
      protected Completion is
         procedure Mark_Started;
         procedure Mark_Done;
         entry Wait_Started;
         entry Wait_Done;
         function Is_Done return Boolean;
      private
         Started : Boolean := False;
         Done    : Boolean := False;
      end Completion;

      protected body Completion is
         procedure Mark_Started is
         begin
            Started := True;
         end Mark_Started;

         procedure Mark_Done is
         begin
            Done := True;
         end Mark_Done;

         entry Wait_Started when Started is
         begin
            null;
         end Wait_Started;

         entry Wait_Done when Done is
         begin
            null;
         end Wait_Done;

         function Is_Done return Boolean is (Done);
      end Completion;

      task Writer;

      task body Writer is
      begin
         Completion.Mark_Started;
         Blocking.Trace (11);
         Completion.Mark_Done;
      end Writer;
   begin
      Completion.Wait_Started;
      Check
        (not Completion.Is_Done,
         "blocking producer completed before capacity was cleared");

      Blocking.Take (Blocked_Copy);
      Check
        (Blocking.Message_Of (Blocking.Trace_At (Blocked_Copy, 1)) = 10,
         "take returned the wrong blocking message");
      Blocking.Release (Blocked_Copy);
      Completion.Wait_Done;
      Blocking.Take (Blocked_Copy);
      Check
        (Blocking.Message_Of (Blocking.Trace_At (Blocked_Copy, 1)) = 11,
         "released producer message was not retained");
      Blocking.Release (Blocked_Copy);
   end;

   Blocking.Trace (20);
   declare
      protected Completion is
         procedure Mark_Started;
         procedure Mark_Closed;
         procedure Mark_Unexpected;
         entry Wait_All_Started;
         entry Wait_All_Done;
         function Done_Count return Natural;
         function Closed_Count return Natural;
         function Unexpected_Count return Natural;
      private
         Started    : Natural := 0;
         Done       : Natural := 0;
         Closed     : Natural := 0;
         Unexpected : Natural := 0;
      end Completion;

      protected body Completion is
         procedure Mark_Started is
         begin
            Started := Started + 1;
         end Mark_Started;

         procedure Mark_Closed is
         begin
            Closed := Closed + 1;
            Done := Done + 1;
         end Mark_Closed;

         procedure Mark_Unexpected is
         begin
            Unexpected := Unexpected + 1;
            Done := Done + 1;
         end Mark_Unexpected;

         entry Wait_All_Started when Started = 3 is
         begin
            null;
         end Wait_All_Started;

         entry Wait_All_Done when Done = 3 is
         begin
            null;
         end Wait_All_Done;

         function Done_Count return Natural is (Done);

         function Closed_Count return Natural is (Closed);

         function Unexpected_Count return Natural is (Unexpected);
      end Completion;

      task type Closing_Writer;

      task body Closing_Writer is
      begin
         Completion.Mark_Started;
         begin
            Blocking.Trace (21);
            Completion.Mark_Unexpected;
         exception
            when Flyology_Debug.Closed_Error =>
               Completion.Mark_Closed;
         end;
      end Closing_Writer;

      Writers : array (1 .. 3) of Closing_Writer;
   begin
      Completion.Wait_All_Started;
      Check
        (Completion.Done_Count = 0,
         "full tracer did not block every closing producer");

      Blocking.Close;
      Completion.Wait_All_Done;
      Check (Blocking.Is_Closed, "closed tracer reports open");
      Check (not Blocking.Is_Enabled, "closed tracer reports enabled");
      Blocking.Enable;
      Check
        (not Blocking.Is_Enabled,
         "enable reopened a terminally closed tracer");
      Check
        (Completion.Closed_Count = 3 and then
         Completion.Unexpected_Count = 0,
         "close did not reject every blocked producer");

      Blocking.Try_Trace (22, Accepted_Now);
      Check (not Accepted_Now, "closed tracer accepted Try_Trace");

      declare
         Rejected : Boolean := False;
      begin
         begin
            Blocking.Trace (23);
         exception
            when Flyology_Debug.Closed_Error =>
               Rejected := True;
         end;
         Check (Rejected, "closed tracer accepted a later trace");
      end;

      Blocking.Close;
      Blocking.Take (Blocked_Copy);
      Check
        (Blocking.Trace_Count (Blocked_Copy) = 1 and then
         Blocking.Message_Of (Blocking.Trace_At (Blocked_Copy, 1)) = 20,
         "close did not preserve retained history");
      Blocking.Release (Blocked_Copy);
   end;

   Ada.Text_IO.Put_Line ("flyology_debug smoke: PASS");
end Flyology_Debug_Smoke;
