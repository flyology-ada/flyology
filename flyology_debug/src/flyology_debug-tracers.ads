--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Finalization;
with Interfaces;

--  Collects typed trace messages without performing I/O. Trace calls timestamp
--  and copy their payload into bounded in-memory storage. Take transfers a
--  detached buffer to its calling consumer without copying retained payloads;
--  an application timer task may drive those requests.
--
--  Overwrite_Oldest keeps producer progress and the newest messages when
--  history is full. Batches disclose how many older messages were replaced.
--  Drop_Newest preserves retained history and counts declined new messages.
--  Block_Producer instead waits for Take, Clear, Disable, or terminal Close.
--  Close wakes blocked producers, which then raise Closed_Error. Try_Trace is
--  available where waiting is not acceptable.
--
--  Copying Message_Type must not block, reenter this package instance, or
--  raise an exception. Its size and copy cost are part of the caller-visible
--  tracing cost. Producer_Count configures independent producer shards, each
--  with its own protected store and two preallocated buffers. Producers using
--  different ids do not serialize with one another. Capacity, retention order,
--  admission sequences, loss counters, Take, and Clear are per producer.
--  The consumer owns each detached buffer until Release or finalization.
--
--  Now executes outside the protected store and may be called concurrently by
--  producers. A custom implementation must therefore be task safe and return
--  values from one monotonic clock domain. Its exceptions propagate before a
--  message is admitted. Its latency is part of the producer cost and it should
--  not block when low tracing latency is required.
--
--  Select_Producer supplies the shard for Trace and Try_Trace calls that omit
--  an explicit producer. It executes outside the protected stores, must be
--  task safe and nonblocking, and must return 1 .. Producer_Count. It is not
--  called when Producer_Count is one. Explicit-producer overloads bypass it.
--  Its exceptions propagate before the clock is read or a message is admitted.
--  @formal Message_Type Definite trace payload copied into retained history
--  @formal Capacity Maximum trace messages retained by the instance
--  @formal Overflow Behavior when bounded message retention is exhausted
--  @formal Now Task-safe monotonic timestamp source for producer operations
--  @formal Producer_Count Number of independently synchronized producer shards
--  @formal Select_Producer Task-safe automatic producer shard selector

generic
   type Message_Type is private;
   Capacity : Positive := 1_024;
   Overflow : Overflow_Policy := Overwrite_Oldest;
   with function Now return Timestamp is Flyology_Debug.Clock;
   Producer_Count : Positive := 1;
   with function Select_Producer (Producer_Count : Positive) return Positive is Flyology_Debug.First_Producer;
package Flyology_Debug.Tracers is
   --  Saturating count of messages lost at a history boundary.
   subtype Loss_Count is Interfaces.Unsigned_64;

   --  Count type returned by the overwrite-specific compatibility accessor.
   subtype Overwrite_Count is Loss_Count;

   --  Modular order assigned to messages accepted by one producer's protected
   --  store. Retention order remains authoritative across the practically
   --  remote Unsigned_64 wrap boundary.
   subtype Sequence_Number is Interfaces.Unsigned_64;

   --  Explicit producer shard. Assign distinct hot producers distinct ids to
   --  avoid shared-store contention. Sharing an id remains task safe, but its
   --  producers serialize with one another. Capacity is available separately
   --  to every id.
   subtype Producer_Id is Positive range 1 .. Producer_Count;

   --  Loss and sequence metadata transferred with a detached batch.
   --  Empty batches set Has_Traces to False and both sequence fields to zero.
   --  @field Retained Number of trace records in the batch
   --  @field Overwritten Older records replaced while producing the batch
   --  @field Dropped New messages declined while the batch was full
   --  @field Has_Traces Whether First_Sequence and Last_Sequence are present
   --  @field First_Sequence Producer-local order of the oldest retained record
   --  @field Last_Sequence Producer-local order of the newest retained record
   type Batch_Statistics is record
      Retained       : Natural;
      Overwritten    : Loss_Count;
      Dropped        : Loss_Count;
      Has_Traces     : Boolean;
      First_Sequence : Sequence_Number;
      Last_Sequence  : Sequence_Number;
   end record;

   --  One timestamped copy of a submitted message.
   type Trace_Record is private;

   --  Exclusive consumer ownership of one detached trace buffer. Batch is
   --  limited so the handle cannot be copied; finalization releases it. The
   --  owner must exclude concurrent access to one Batch, particularly Release
   --  while an accessor is running. Do not request another batch from this
   --  package instance while retaining one; nested acquisition can wait on the
   --  caller's own reservation.
   type Batch is limited private;

   --  Exclusive consumer ownership of one detached buffer from every producer
   --  shard. The handle is limited and finalization releases all its buffers.
   --  The owner must exclude concurrent access to one Merged_Batch. Do not call
   --  Take or Take_Merged while retaining another batch from this instance.
   type Merged_Batch is limited private;

   --  Aggregate retention and loss metadata for a merged batch. Aggregate
   --  counters saturate if producer totals cannot be represented.
   --  @field Retained Number of trace records across all producer buffers
   --  @field Overwritten Older records replaced across producer buffers
   --  @field Dropped New messages declined across producer buffers
   type Merged_Batch_Statistics is record
      Retained    : Interfaces.Unsigned_64;
      Overwritten : Loss_Count;
      Dropped     : Loss_Count;
   end record;

   --  Timestamp and retain Message without allocation or I/O when enabled.
   --  A disabled tracer silently ignores the operation.
   --  Overwrite_Oldest replaces the oldest record when full.
   --  Drop_Newest silently declines Message and increments Dropped.
   --  Block_Producer waits until Take or Clear releases capacity.
   --  After Close, the operation raises Closed_Error instead of waiting.
   --  @param Message Definite payload copied into the automatically selected
   --  producer
   --  @exception Closed_Error The tracer is closed
   --  @exception Constraint_Error Automatic selection returned an invalid id
   procedure Trace (Message : Message_Type);

   --  Timestamp and retain Message in an explicit producer shard. Its policy
   --  and lifecycle behavior match Trace for producer one.
   --  @param Message Definite payload copied by the tracer
   --  @param Producer Independent producer shard receiving Message
   --  @exception Closed_Error The tracer is closed
   procedure Trace (Message : Message_Type; Producer : Producer_Id);

   --  Attempt Trace without waiting for history capacity. Overwrite_Oldest
   --  always accepts after acquiring the protected store. Drop_Newest counts
   --  a full-history decline in the detached batch. Block_Producer declines
   --  immediately while history is full. Disabled and closed tracers also
   --  decline without calling Now.
   --  @param Message Definite payload offered to the automatically selected
   --  producer
   --  @param Accepted True when Message was copied into history
   --  @exception Constraint_Error Automatic selection returned an invalid id
   procedure Try_Trace (Message : Message_Type; Accepted : out Boolean);

   --  Attempt Trace for an explicit producer shard without waiting for
   --  history capacity.
   --  @param Message Definite payload offered to the tracer
   --  @param Accepted True when Message was copied into history
   --  @param Producer Independent producer shard offered Message
   procedure Try_Trace (Message : Message_Type; Accepted : out Boolean; Producer : Producer_Id);

   --  Reversibly allow producer operations. Enable has no effect after Close.
   procedure Enable;

   --  Reversibly ignore later producer operations and wake producers waiting
   --  in Block_Producer mode. Retained history remains available.
   procedure Disable;

   --  Report whether producer operations are currently enabled. Callers may
   --  use this cheap atomic query to avoid constructing expensive messages.
   --  Concurrent state changes may take effect immediately before or after
   --  the query.
   --  @return True when the tracer currently accepts producer operations
   function Is_Enabled return Boolean;

   --  Release any buffer currently held by Result, reserve Producer for this
   --  consumer, then atomically transfer its retained state while the producer
   --  uses its other preallocated buffer. Concurrent Take calls for one
   --  producer wait until the prior consumer releases its batch. Different
   --  producers may be taken independently. Producer calls waiting in
   --  Block_Producer mode may proceed once their producer's swap completes.
   --  Calling Take while retaining another batch from this package instance is
   --  unsupported because nested consumer reservations can deadlock.
   --  @param Result Exclusive handle replaced by producer one's detached batch
   procedure Take (Result : in out Batch);

   --  Transfer retained state from an explicit producer shard.
   --  @param Result Exclusive handle replaced by the detached trace batch
   --  @param Producer Producer shard whose retained state is transferred
   procedure Take (Result : in out Batch; Producer : Producer_Id);

   --  Release buffers currently held by Result, then atomically reserve every
   --  producer before detaching any buffer. The subsequent producer swaps are
   --  individually atomic but are not a simultaneous cross-producer snapshot.
   --  Producers resume into their spare buffers after their individual swap.
   --  A merged take waits without retaining a partial set of producers.
   --  Calling it while retaining another batch from this package instance is
   --  unsupported because it would wait on the caller's own reservation.
   --  @param Result Exclusive handle replaced by all detached trace buffers
   procedure Take_Merged (Result : in out Merged_Batch);

   --  Return Result's detached buffer and consumer reservation for reuse. The
   --  operation is idempotent; finalization performs it automatically when
   --  necessary, including after an interrupted Take.
   --  @param Result Consumer batch to release
   procedure Release (Result : in out Batch);

   --  Return every detached buffer and reservation owned by Result. The
   --  operation is idempotent; finalization also performs it automatically,
   --  including after an interrupted Take_Merged.
   --  @param Result Merged consumer batch to release
   procedure Release (Result : in out Merged_Batch);

   --  Report whether Result owns a consumer reservation. This remains true if
   --  Take is interrupted after reserving its producer but before detachment,
   --  allowing a surviving owner to call Release safely.
   --  @param Result Consumer batch to inspect
   --  @return True while Result must be released before another acquisition
   function Is_Acquired (Result : Batch) return Boolean;

   --  Report whether Result owns a consumer reservation. This remains true if
   --  Take_Merged is interrupted after reserving all producers but before every
   --  buffer is detached, allowing a surviving owner to call Release safely.
   --  @param Result Merged consumer batch to inspect
   --  @return True while Result must be released before another acquisition
   function Is_Acquired (Result : Merged_Batch) return Boolean;

   --  Return the producer shard from which Result was detached.
   --  @param Result Acquired batch to inspect
   --  @return Producer supplied to Take
   --  @exception Constraint_Error Result does not own a buffer
   function Producer_Of (Result : Batch) return Producer_Id;

   --  Clear retained messages and both loss counters. Producer calls waiting
   --  in Block_Producer mode for producer one may then proceed.
   procedure Clear;

   --  Clear retained messages and loss counters for an explicit producer.
   --  Producer calls waiting in Block_Producer mode for that producer may then
   --  proceed.
   --  @param Producer Producer shard whose retained state is discarded
   procedure Clear (Producer : Producer_Id);

   --  Permanently reject new traces. The operation is idempotent and wakes
   --  every producer blocked for history capacity; retained state remains
   --  available to Take or Clear.
   procedure Close;

   --  Report whether Close has permanently closed this tracer instance.
   --  @return True after Close has begun rejecting producer operations
   function Is_Closed return Boolean;

   --  Return the number of valid retention-ordered trace records in Result.
   --  @param Result Acquired batch to inspect
   --  @return Count in the range 0 .. Capacity
   --  @exception Constraint_Error Result does not own a buffer
   function Trace_Count (Result : Batch) return Natural;

   --  Return retention, loss, and admission-order metadata for Result.
   --  @param Result Acquired batch to inspect
   --  @return Metadata captured with the detached buffer
   --  @exception Constraint_Error Result does not own a buffer
   function Statistics (Result : Batch) return Batch_Statistics;

   --  Return aggregate retention and loss metadata for Result.
   --  @param Result Acquired merged batch to inspect
   --  @return Aggregate metadata from all detached producer buffers
   --  @exception Constraint_Error Result does not own all producer buffers
   function Statistics (Result : Merged_Batch) return Merged_Batch_Statistics;

   --  Return one retained record in oldest-to-newest admission order. Calls
   --  from concurrent producers may be admitted in a different order from
   --  their captured timestamps.
   --  @param Result Acquired batch to inspect
   --  @param Index One-based index not greater than Trace_Count
   --  @return Timestamped copied message
   --  @exception Constraint_Error Result is unacquired or Index exceeds its
   --  trace count
   function Trace_At (Result : Batch; Index : Positive) return Trace_Record;

   --  Return the producer timestamp of Record_At.
   --  @param Record_At Trace record to inspect
   --  @return Monotonic nanosecond timestamp captured before history insertion
   function Timestamp_Of (Record_At : Trace_Record) return Timestamp;

   --  Return the protected-store admission order of Record_At.
   --  @param Record_At Trace record to inspect
   --  @return Modular sequence number assigned when the record was retained
   function Sequence_Of (Record_At : Trace_Record) return Sequence_Number;

   --  Return an independent copy of the payload in Record_At.
   --  @param Record_At Trace record to inspect
   --  @return Submitted message value
   function Message_Of (Record_At : Trace_Record) return Message_Type;

   --  Visit retained messages in oldest-to-newest admission order without
   --  copying records or payloads. Message designates storage owned by Result
   --  and must not be retained after Process returns. Process must not release
   --  or replace Result while Visit is active. The callbacks run outside the
   --  protected store, so producers continue using the active buffer.
   --  @param Result Acquired batch to inspect
   --  @param Process Consumer callback invoked once per retained message
   --  @exception Constraint_Error Result does not own a buffer
   procedure Visit
     (Result  : Batch;
      Process :
        not null access procedure
          (Sequence    : Sequence_Number;
           Captured_At : Flyology_Debug.Timestamp;
           Message     : not null access constant Message_Type));

   --  Visit all retained messages without copying records or payloads. The
   --  merge preserves each producer's admission order and selects the earliest
   --  timestamp among the current producer heads, breaking equal timestamps by
   --  Producer_Id. It therefore does not reorder one producer's records even
   --  if concurrently captured timestamps differ from admission order.
   --  Message designates storage owned by Result and must not be retained
   --  after Process returns. Callbacks run outside all protected stores.
   --  @param Result Acquired merged batch to inspect
   --  @param Process Consumer callback invoked once per retained message
   --  @exception Constraint_Error Result does not own all producer buffers
   procedure Visit_Merged
     (Result  : Merged_Batch;
      Process :
        not null access procedure
          (Producer    : Producer_Id;
           Sequence    : Sequence_Number;
           Captured_At : Flyology_Debug.Timestamp;
           Message     : not null access constant Message_Type));

   --  Return oldest messages replaced by newer messages. The count saturates
   --  rather than wrapping and resets when a batch is detached or through
   --  Clear.
   --  @param Result Acquired batch to inspect
   --  @return History overwrite count represented by Result
   --  @exception Constraint_Error Result does not own a buffer
   function Overwrites (Result : Batch) return Overwrite_Count;

private
   type Trace_Record is record
      Sequence  : Sequence_Number := 0;
      Timestamp : Flyology_Debug.Timestamp := 0;
      Message   : aliased Message_Type;
   end record;

   type Trace_Array is array (Positive range 1 .. Capacity) of Trace_Record;

   type Batch is new Ada.Finalization.Limited_Controlled with record
      Producer : Natural range 0 .. Producer_Count := 0;
      Slot     : Natural range 0 .. 2 := 0;
      Reserved : Boolean := False;
   end record;

   --  @exclude
   --  @param Result Batch finalized for internal buffer return
   overriding
   procedure Finalize (Result : in out Batch);

   type Merged_Slot_Array is array (Producer_Id) of Natural range 0 .. 2;

   type Merged_Batch is new Ada.Finalization.Limited_Controlled with record
      Slots    : Merged_Slot_Array := (others => 0);
      Reserved : Boolean := False;
      Acquired : Boolean := False;
   end record;

   --  @exclude
   --  @param Result Merged batch finalized for internal buffer return
   overriding
   procedure Finalize (Result : in out Merged_Batch);
end Flyology_Debug.Tracers;
