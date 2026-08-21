with Ada.Finalization;
with Flyology.Cancellation;
with Flyology.Operations;
private with Flyology.Buffers.Drivers;
private with System;

--  Supplies bounded closeable channels that transfer unique buffer ownership
--  without copying payload bytes. The protected queue carries fixed ownership
--  records; payload storage remains in the associated pool.
package Flyology.Buffers.Channels is

   --  Distinct 64-bit scalar metadata transferred atomically with a buffer
   --  token. This value is channel-local and does not alter the buffer's
   --  application Tag. Callers define and validate their own encoding.
   type Transfer_Metadata is mod 2 ** 64;
   --  Default metadata used by send overloads. Zero is an ordinary encoded
   --  value, not an indication that metadata is absent.
   No_Metadata : constant Transfer_Metadata := 0;

   --  Raised when a send observes a closed channel, or a receive observes a
   --  closed and drained channel.
   Channel_Closed : exception;

   --  Raised by a timed send or receive whose deadline expires first.
   Timeout_Error : exception;

   --  Raised when a cancellation-aware receive observes its one-shot token.
   Operation_Cancelled : exception renames
     Flyology.Cancellation.Operation_Cancelled;

   --  Result of a nonblocking send attempt.
   --  @enum Item_Sent Ownership transferred to the channel
   --  @enum Channel_Full No capacity was available; sender retains ownership
   --  @enum Send_Closed Channel is closed; sender retains ownership
   type Try_Send_Result is (Item_Sent, Channel_Full, Send_Closed);

   --  Result of a nonblocking receive attempt.
   --  @enum Item_Received Target received sole ownership
   --  @enum Channel_Empty No value was available from an open channel
   --  @enum Receive_Closed Closed channel has fully drained
   type Try_Receive_Result is
     (Item_Received, Channel_Empty, Receive_Closed);

   --  One coherent channel-state snapshot.
   --  @field Closed Whether Close has been called
   --  @field Pending Number of buffer tokens currently queued
   --  @field Waiting_Senders Number of callers queued for capacity
   --  @field Waiting_Receivers Number of callers queued for a buffer
   type Snapshot is record
      Closed            : Boolean;
      Pending           : Natural;
      Waiting_Senders   : Natural;
      Waiting_Receivers : Natural;
   end record;

   --  Fixed-capacity MPMC FIFO tied to one buffer pool. Finalization closes
   --  the channel and returns any undelivered buffers to Owner. Every
   --  transfer commits its queue update and its ownership change in one
   --  protected action, so aborting a sender or a receiver leaves the message
   --  with exactly one owner: the sender, the channel, or the target.
   type Channel
     (Owner    : not null access Pool;  --  Pool supplying every buffer
      Capacity : Positive)              --  Maximum queued buffer count
   is
     limited new Ada.Finalization.Limited_Controlled with private;

   --  Named access capability used by operation-producing overloads. The
   --  channel must outlive every operation started through this capability.
   --  A local aliased channel therefore supplies Queue'Unchecked_Access only
   --  within a scope that finishes or finalizes all such operations first.
   type Channel_Access is access all Channel;

   --  Append Value, waiting while the open channel is full. Success leaves
   --  Value vacant. Close before acceptance raises and preserves Value.
   --  @param Item Channel receiving ownership
   --  @param Value Acquired buffer from Item's pool
   --  @param Metadata Scalar metadata transferred with Value
   --  @exception Channel_Closed Close occurs before acceptance
   --  @exception Program_Error Value is vacant or belongs to another pool
   procedure Send_Move
     (Item  : in out Channel;
      Value : in out Unique_Buffer;
      Metadata : Transfer_Metadata := No_Metadata)
     with Pre => Has_Buffer (Value),
          Post => not Has_Buffer (Value);

   --  Receive the oldest buffer, waiting while the channel is open and empty.
   --  Target must be vacant and belong to Item's pool.
   --  @param Item Channel yielding ownership
   --  @param Target Vacant buffer that receives the oldest payload
   --  @exception Channel_Closed Closed channel has fully drained
   --  @exception Program_Error Target is occupied or belongs to another pool
   procedure Receive_Move
     (Item   : in out Channel;
      Target : in out Unique_Buffer)
     with Pre => not Has_Buffer (Target),
          Post => Has_Buffer (Target);

   --  Receive the oldest buffer and its channel-local metadata.
   --  @param Item Channel yielding ownership
   --  @param Target Vacant buffer that receives the oldest payload
   --  @param Metadata Metadata supplied by the sender
   --  @exception Channel_Closed Closed channel has fully drained
   --  @exception Program_Error Target is occupied or belongs to another pool
   procedure Receive_Move
     (Item     : in out Channel;
      Target   : in out Unique_Buffer;
      Metadata : out Transfer_Metadata)
     with Pre => not Has_Buffer (Target),
          Post => Has_Buffer (Target);

   --  Attempt to append without waiting. Value becomes vacant only for
   --  Item_Sent.
   --  @param Item Channel receiving ownership
   --  @param Value Acquired buffer from Item's pool
   --  @param Result Send outcome
   --  @param Metadata Scalar metadata transferred with Value
   --  @exception Program_Error Value is vacant or belongs to another pool
   procedure Try_Send_Move
     (Item   : in out Channel;
      Value  : in out Unique_Buffer;
      Result : out Try_Send_Result;
      Metadata : Transfer_Metadata := No_Metadata)
     with Pre => Has_Buffer (Value),
          Post => (Result = Item_Sent) = (not Has_Buffer (Value));

   --  Attempt to receive without waiting. Target becomes acquired only for
   --  Item_Received.
   --  @param Item Channel yielding ownership
   --  @param Target Vacant buffer that receives ownership on success
   --  @param Result Receive outcome
   --  @exception Program_Error Target is occupied or belongs to another pool
   procedure Try_Receive_Move
     (Item   : in out Channel;
      Target : in out Unique_Buffer;
      Result : out Try_Receive_Result)
     with Pre => not Has_Buffer (Target),
          Post => (Result = Item_Received) = Has_Buffer (Target);

   --  Attempt to receive without waiting and return channel-local metadata
   --  only when a buffer is received.
   --  @param Item Channel yielding ownership
   --  @param Target Vacant buffer that receives ownership on success
   --  @param Result Receive outcome
   --  @param Metadata Sender metadata, or No_Metadata when no buffer is
   --    received; No_Metadata is not a presence indicator
   --  @exception Program_Error Target is occupied or belongs to another pool
   procedure Try_Receive_Move
     (Item     : in out Channel;
      Target   : in out Unique_Buffer;
      Result   : out Try_Receive_Result;
      Metadata : out Transfer_Metadata)
     with Pre => not Has_Buffer (Target),
          Post => (Result = Item_Received) = Has_Buffer (Target);

   --  Append Value within one relative deadline. Negative Timeout waits
   --  indefinitely; zero is an immediate attempt. Timeout and close preserve
   --  Value.
   --  @param Item Channel receiving ownership
   --  @param Value Acquired buffer from Item's pool
   --  @param Timeout Maximum monotonic wait in seconds
   --  @param Metadata Scalar metadata transferred with Value
   --  @exception Channel_Closed Close occurs before acceptance
   --  @exception Timeout_Error Capacity remains unavailable until the deadline
   --  @exception Program_Error Value is vacant or belongs to another pool
   procedure Timed_Send_Move
     (Item    : in out Channel;
      Value   : in out Unique_Buffer;
      Timeout : Duration;
      Metadata : Transfer_Metadata := No_Metadata)
     with Pre => Has_Buffer (Value),
          Post => not Has_Buffer (Value);

   --  Receive within one relative deadline. Negative Timeout waits without a
   --  deadline; zero is an immediate attempt. Timeout leaves Target vacant.
   --  @param Item Channel yielding ownership
   --  @param Target Vacant buffer that receives ownership on success
   --  @param Timeout Maximum monotonic wait in seconds
   --  @exception Channel_Closed Closed channel has fully drained
   --  @exception Timeout_Error No buffer arrives before the deadline
   --  @exception Program_Error Target is occupied or belongs to another pool
   procedure Timed_Receive_Move
     (Item    : in out Channel;
      Target  : in out Unique_Buffer;
      Timeout : Duration)
     with Pre => not Has_Buffer (Target),
          Post => Has_Buffer (Target);

   --  Receive within one relative deadline or until Token is requested.
   --  Cancellation leaves Target vacant unless delivery completed first.
   --  @param Item Channel yielding ownership
   --  @param Target Vacant buffer that receives the oldest payload
   --  @param Timeout Maximum monotonic wait in seconds
   --  @param Token Optional one-shot cancellation source
   --  @exception Channel_Closed Closed channel has fully drained
   --  @exception Timeout_Error No buffer arrives before the deadline
   --  @exception Operation_Cancelled Token is requested before delivery
   --  @exception Program_Error Target is occupied or belongs to another pool
   procedure Timed_Receive_Move
     (Item    : in out Channel;
      Target  : in out Unique_Buffer;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
     with Pre => not Has_Buffer (Target),
          Post => Has_Buffer (Target);

   --  Receive within one relative deadline and return channel-local metadata.
   --  @param Item Channel yielding ownership
   --  @param Target Vacant buffer that receives ownership on success
   --  @param Timeout Maximum monotonic wait in seconds
   --  @param Metadata Metadata supplied by the sender
   --  @exception Channel_Closed Closed channel has fully drained
   --  @exception Timeout_Error No buffer arrives before the deadline
   --  @exception Program_Error Target is occupied or belongs to another pool
   procedure Timed_Receive_Move
     (Item     : in out Channel;
      Target   : in out Unique_Buffer;
      Timeout  : Duration;
      Metadata : out Transfer_Metadata)
     with Pre => not Has_Buffer (Target),
          Post => Has_Buffer (Target);

   --  Receive a buffer and metadata within a deadline or until cancellation.
   --  Ownership and exception semantics match the overload without metadata.
   --  @param Item Channel yielding ownership
   --  @param Target Vacant buffer that receives the oldest payload
   --  @param Timeout Maximum monotonic wait in seconds
   --  @param Metadata Metadata supplied by the sender. A cancellation
   --    observed after delivery completed leaves it unassigned
   --  @param Token Optional one-shot cancellation source
   --  @exception Channel_Closed Closed channel has fully drained
   --  @exception Timeout_Error No buffer arrives before the deadline
   --  @exception Operation_Cancelled Token is requested before delivery
   --  @exception Program_Error Target is occupied or belongs to another pool
   procedure Timed_Receive_Move
     (Item     : in out Channel;
      Target   : in out Unique_Buffer;
      Timeout  : Duration;
      Metadata : out Transfer_Metadata;
      Token    : access Flyology.Cancellation.Token)
     with Pre => not Has_Buffer (Target),
          Post => Has_Buffer (Target);

   --  Idempotently reject new sends and allow queued buffers to drain.
   --  @param Item Channel to close
   procedure Close (Item : in out Channel);

   --  Wait until Close has occurred and every accepted buffer was received.
   --  @param Item Channel to observe
   procedure Await_Drained (Item : in out Channel);

   --  Read channel state under its protected lock.
   --  @param Item Channel to inspect
   --  @return Current close, queue, and waiter counts
   function Current (Item : Channel) return Snapshot;

   --  First-class ownership-transferring send operation.
   type Send_Operation is new Flyology.Operations.Operation with private;

   --  First-class ownership-transferring receive operation.
   type Receive_Operation is new Flyology.Operations.Operation with private;

   --  Start a send after moving Value into the operation. Value is vacant on
   --  return. Success transfers the token to the channel; typed Finish returns
   --  it only for timeout, close, cancellation, or driver failure.
   --  @param Set Completion set that owns the operation slot
   --  @param Item Aliased channel that outlives the operation
   --  @param Value Acquired buffer whose ownership transfers
   --  @param Metadata Scalar metadata transferred on success
   --  @param Timeout Relative deadline; negative waits indefinitely
   --  @return Started limited send operation
   function Send_Move
     (Set      : not null access Flyology.Operations.Completion_Set'Class;
      Item     : not null Channel_Access;
      Value    : in out Unique_Buffer;
      Metadata : Transfer_Metadata := No_Metadata;
      Timeout  : Duration := -1.0) return Send_Operation
     with Pre => Has_Buffer (Value),
          Post => not Has_Buffer (Value);

   --  Start or restart an ownership-transferring send.
   --  @param Item Aliased channel that outlives the operation
   --  @param Value Acquired buffer whose ownership transfers
   --  @param Metadata Scalar metadata transferred on success
   --  @param Timeout Relative deadline; negative waits indefinitely
   --  @param Operation Fresh or consumed send operation
   procedure Send_Move
     (Item      : not null Channel_Access;
      Value     : in out Unique_Buffer;
      Metadata  : Transfer_Metadata := No_Metadata;
      Timeout   : Duration := -1.0;
      Operation : in out Send_Operation)
     with Pre => Has_Buffer (Value)
       and then not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation),
          Post => not Has_Buffer (Value);

   --  Start a receive whose operation will own the dequeued buffer. No vacant
   --  destination is borrowed during the wait; typed Finish supplies it.
   --  @param Set Completion set that owns the operation slot
   --  @param Item Aliased channel that outlives the operation
   --  @param Timeout Relative deadline; negative waits indefinitely
   --  @return Started limited receive operation
   function Receive_Move
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null Channel_Access;
      Timeout : Duration := -1.0) return Receive_Operation;

   --  Start or restart an ownership-transferring receive.
   --  @param Item Aliased channel that outlives the operation
   --  @param Timeout Relative deadline; negative waits indefinitely
   --  @param Operation Fresh or consumed receive operation
   procedure Receive_Move
     (Item      : not null Channel_Access;
      Timeout   : Duration := -1.0;
      Operation : in out Receive_Operation)
     with Pre => not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation);

   --  Consume a send. Value must be vacant. A failed or cancelled send moves
   --  its original buffer into Value before raising; success leaves it vacant.
   --  @param Operation Terminal send operation
   --  @param Value Vacant same-pool destination for untransferred ownership
   procedure Finish
     (Operation : in out Send_Operation;
      Value     : in out Unique_Buffer)
     with Pre => not Has_Buffer (Value);

   --  Consume a successful receive and move its buffer into Target.
   --  @param Operation Terminal receive operation
   --  @param Target Vacant same-pool destination
   procedure Finish
     (Operation : in out Receive_Operation;
      Target    : in out Unique_Buffer)
     with Pre => not Has_Buffer (Target),
          Post => Has_Buffer (Target);

   --  Consume a successful receive and return its transfer metadata.
   --  @param Operation Terminal receive operation
   --  @param Target Vacant same-pool destination
   --  @param Metadata Metadata supplied by the sender
   procedure Finish
     (Operation : in out Receive_Operation;
      Target    : in out Unique_Buffer;
      Metadata  : out Transfer_Metadata)
     with Pre => not Has_Buffer (Target),
          Post => Has_Buffer (Target);

private
   type Detached_Buffer_Array is array (Positive range <>) of
     Flyology.Buffers.Drivers.Detached_Buffer;

   protected type Channel_State (Capacity : Positive) is
      --  Detach and enqueue in one protected action, for the same reason the
      --  receive side attaches in one: an accepted send must never leave the
      --  slot owned by both Value and the channel.
      entry Send
        (Value    : in out Unique_Buffer;
         Metadata : Transfer_Metadata;
         Accepted : out Boolean);
      --  Dequeue and attach in one protected action. Abort is deferred for
      --  its whole duration, so a receiver is either still queued or already
      --  owns the buffer; no window exists in which the token belongs to
      --  neither the channel nor Target.
      entry Receive
        (Target    : in out Unique_Buffer;
         Metadata  : out Transfer_Metadata;
         Available : out Boolean);
      procedure Try_Send
        (Value    : in out Unique_Buffer;
         Metadata : Transfer_Metadata;
         Result   : out Try_Send_Result);
      procedure Try_Receive
        (Target   : in out Unique_Buffer;
         Metadata : out Transfer_Metadata;
         Result   : out Try_Receive_Result);
      procedure Try_Send
        (Value    : in out Flyology.Buffers.Drivers.Detached_Buffer;
         Metadata : Transfer_Metadata;
         Result   : out Try_Send_Result);
      procedure Try_Receive
        (Target   : in out Flyology.Buffers.Drivers.Detached_Buffer;
         Metadata : out Transfer_Metadata;
         Result   : out Try_Receive_Result);
      --  Dequeue into sealed provider storage. Only finalization uses this;
      --  it releases the storage after leaving the protected action.
      procedure Take_Undelivered
        (Target : in out Flyology.Buffers.Drivers.Detached_Buffer;
         Result : out Try_Receive_Result);
      procedure Close;
      entry Await_Drained;
      function Current return Snapshot;
   private
      procedure Signal_Scoped;
      Values  : Detached_Buffer_Array (1 .. Capacity);
      Head    : Positive := 1;
      Tail    : Positive := 1;
      Count   : Natural := 0;
      Stopped : Boolean := False;
   end Channel_State;

   type Channel
     (Owner    : not null access Pool;
      Capacity : Positive) is
     limited new Ada.Finalization.Limited_Controlled with record
      State : Channel_State (Capacity);
   end record;

   --  @exclude
   --  @param Item Channel being finalized
   overriding procedure Finalize (Item : in out Channel);

   type Scoped_Kind is (Scoped_Send, Scoped_Receive);
   type Scoped_Failure is
     (No_Failure, Channel_Closed_Failure, Timeout_Failure, Driver_Failure);

   type Channel_Operation is
     abstract new Flyology.Operations.Operation with record
      Item       : Channel_Access := null;
      Kind       : Scoped_Kind := Scoped_Receive;
      Owned      : Flyology.Buffers.Drivers.Detached_Buffer;
      Metadata   : Transfer_Metadata := No_Metadata;
      Next       : System.Address := System.Null_Address;
      Subscribed : Boolean := False;
      Failure    : Scoped_Failure := No_Failure;
   end record;

   --  @exclude
   overriding procedure Drive
     (Item  : in out Channel_Operation;
      Event : Flyology.Operations.Driver_Event);

   --  @exclude
   overriding procedure Request_Cancellation
     (Item : in out Channel_Operation);

   type Send_Operation is new Channel_Operation with null record;
   type Receive_Operation is new Channel_Operation with null record;

end Flyology.Buffers.Channels;
