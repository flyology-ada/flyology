--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Interfaces;

--  Root namespace for bounded, in-memory debugging utilities.

package Flyology_Debug is

   --  Nanoseconds from a platform monotonic origin. Values are suitable for
   --  ordering and elapsed-time calculation, not conversion to wall time.
   type Timestamp is new Interfaces.Unsigned_64;

   --  Read the platform monotonic clock in nanosecond units. The backend is
   --  mach_absolute_time on Darwin and CLOCK_MONOTONIC_RAW on Linux; actual
   --  resolution remains platform-dependent.
   --  @return Nanoseconds from the platform monotonic origin
   --  @exception Program_Error The platform clock read failed
   function Clock return Timestamp;

   --  Select producer one for tracers that do not configure automatic
   --  producer selection. Producer_Count is accepted so this function has
   --  the same profile as an application-supplied selector.
   --  @param Producer_Count Number of configured producer shards
   --  @return One
   function First_Producer (Producer_Count : Positive) return Positive
   with Inline;

   --  Raised when a producer operation is attempted after terminal closure.
   Closed_Error : exception;

   --  Behavior selected when a tracer's bounded message storage is full.
   --  @enum Overwrite_Oldest Retain producer progress and the newest evidence
   --  while counting overwritten messages.
   --  @enum Drop_Newest Preserve retained evidence and count each newly
   --  submitted message that cannot be retained.
   --  @enum Block_Producer Preserve every accepted message by waiting for a
   --  consumer to release retained capacity.
   type Overflow_Policy is (Overwrite_Oldest, Drop_Newest, Block_Producer);
end Flyology_Debug;
