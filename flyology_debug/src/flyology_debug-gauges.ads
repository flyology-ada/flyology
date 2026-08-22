--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

--  Stores one persistent, timestamped value for each application-defined
--  gauge. Each gauge has independent synchronization: Set contends only with
--  Read or Clear while that same key is copied. A multi-key snapshot is
--  coherent per key but does not establish one atomic instant across keys.
--
--  Copying Gauge_Value_Type must not block, reenter this package instance, or
--  raise an exception because copies occur inside a protected operation.
--  Now executes outside every gauge slot and may be called concurrently. A
--  custom implementation must be task safe and return values from one
--  monotonic clock domain. Its exceptions propagate without updating a gauge.
--  Its latency is part of Set and it should not block when low update latency
--  is required.
--  @formal Gauge_Kind Typed identity of every gauge retained by the instance
--  @formal Gauge_Value_Type Definite latest value copied for a gauge
--  @formal Now Task-safe monotonic timestamp source called by Set

generic
   type Gauge_Kind is (<>);
   type Gauge_Value_Type is private;
   with function Now return Timestamp is Flyology_Debug.Clock;
package Flyology_Debug.Gauges is
   --  An independently owned sample of every gauge slot.
   type Snapshot is private;

   --  Timestamp and replace the persistent value of Gauge without allocation
   --  or I/O. Updating one gauge does not contend with other gauge keys.
   --  @param Gauge Typed gauge identity
   --  @param Value Latest value copied into the gauge slot
   procedure Set (Gauge : Gauge_Kind; Value : Gauge_Value_Type);

   --  Copy every gauge without clearing it. Concurrent updates may appear in
   --  this snapshot or the next one independently for each gauge key.
   --  @param Result Snapshot replaced by the sampled gauge state
   procedure Read (Result : out Snapshot);

   --  Clear every gauge. Concurrent Set calls are ordered independently at
   --  each key and may therefore survive or precede that key's clear.
   procedure Clear;

   --  Report whether Result contains a value for Gauge.
   --  @param Result Snapshot to inspect
   --  @param Gauge Typed gauge identity
   --  @return True after a Set represented by Result
   function Is_Set (Result : Snapshot; Gauge : Gauge_Kind) return Boolean;

   --  Return the latest value sampled for Gauge.
   --  @param Result Snapshot to inspect
   --  @param Gauge Typed gauge identity
   --  @return Latest copied gauge value
   --  @exception Constraint_Error Gauge is not set in Result
   function Value_Of (Result : Snapshot; Gauge : Gauge_Kind) return Gauge_Value_Type;

   --  Return the producer timestamp sampled for Gauge.
   --  @param Result Snapshot to inspect
   --  @param Gauge Typed gauge identity
   --  @return Monotonic nanosecond timestamp for the latest sampled value
   --  @exception Constraint_Error Gauge is not set in Result
   function Timestamp_Of (Result : Snapshot; Gauge : Gauge_Kind) return Timestamp;

private
   type Gauge_Record is record
      Is_Set    : Boolean := False;
      Timestamp : Flyology_Debug.Timestamp := 0;
      Value     : Gauge_Value_Type;
   end record;

   type Gauge_Array is array (Gauge_Kind) of Gauge_Record;

   type Snapshot is record
      Values : Gauge_Array;
   end record;
end Flyology_Debug.Gauges;
