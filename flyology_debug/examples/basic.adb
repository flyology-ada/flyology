--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Flyology_Debug.Gauges;
with Flyology_Debug.Tracers;

procedure Basic is
   type Event is (Request_Accepted, Request_Completed);
   type Message is record
      Kind       : Event;
      Request_Id : Positive;
   end record;
   type Gauge is (Active_Requests, Queue_Depth);

   package Debug is new Flyology_Debug.Tracers
     (Message_Type => Message, Capacity => 256);

   package Metrics is new Flyology_Debug.Gauges
     (Gauge_Kind => Gauge, Gauge_Value_Type => Natural);

   Trace_Result : Debug.Batch;
   Gauge_Result : Metrics.Snapshot;

   procedure Observe
     (Sequence    : Debug.Sequence_Number;
      Captured_At : Flyology_Debug.Timestamp;
      Payload     : not null access constant Message)
   is
      pragma Unreferenced (Sequence, Captured_At);
   begin
      pragma Assert (Payload.Request_Id in 41 .. 42);
   end Observe;
begin
   Debug.Trace ((Kind => Request_Accepted, Request_Id => 42));
   Debug.Trace ((Kind => Request_Completed, Request_Id => 41));
   Metrics.Set (Active_Requests, 1);
   Metrics.Set (Queue_Depth, 3);

   --  A timer task can take traces, sample gauges, and hand both to
   --  application-specific rendering, persistence, or analysis code.
   Debug.Take (Trace_Result);
   Metrics.Read (Gauge_Result);
   Debug.Visit (Trace_Result, Observe'Access);

   pragma Assert (Debug.Trace_Count (Trace_Result) = 2);
   pragma Assert (Metrics.Value_Of (Gauge_Result, Active_Requests) = 1);
   Debug.Release (Trace_Result);
end Basic;
