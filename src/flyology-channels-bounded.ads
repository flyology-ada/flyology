--  A bounded FIFO channel with terminal close and drain semantics.
--
--  The channel owns no task and allocates no storage after elaboration.
--  Multiple producers and consumers may call it concurrently. Blocking uses
--  protected entries, preserving the same synchronous API for lightweight and
--  native tasks.
--  @formal Element_Type Definite value transferred by copy through the channel
generic
   --  Definite value transferred by copy through the channel.
   type Element_Type is private;
package Flyology.Channels.Bounded is

   --  Raised when Send observes a closed channel, or Receive observes a closed
   --  and empty channel.
   Channel_Closed : exception;

   --  Raised by a timed Send or Receive whose deadline expires first.
   Timeout_Error : exception;

   --  Result of a nonblocking send attempt.
   --  @enum Item_Sent The value was appended
   --  @enum Channel_Full No capacity was available
   --  @enum Send_Closed The channel had been closed
   type Try_Send_Result is (Item_Sent, Channel_Full, Send_Closed);

   --  Result of a nonblocking receive attempt.
   --  @enum Item_Received The oldest value was returned
   --  @enum Channel_Empty No value was available from an open channel
   --  @enum Receive_Closed The closed channel was fully drained
   type Try_Receive_Result is
     (Item_Received, Channel_Empty, Receive_Closed);

   --  One coherent channel-state snapshot.
   --  @field Closed Whether Close has been called
   --  @field Pending Number of values currently buffered
   --  @field Waiting_Senders Number of callers queued for capacity
   --  @field Waiting_Receivers Number of callers queued for a value
   type Snapshot is record
      Closed            : Boolean;
      Pending           : Natural;
      Waiting_Senders   : Natural;
      Waiting_Receivers : Natural;
   end record;

   --  @exclude Internal fixed storage for Channel.
   type Element_Array is array (Positive range <>) of Element_Type;

   --  Fixed-capacity MPMC FIFO. Close is terminal. Values accepted before
   --  Close remain available in FIFO order; blocked and later senders are
   --  rejected, while receivers finish draining the buffer.
   protected type Channel
     (Capacity : Positive)  --  Maximum buffered value count
   is
      --  Idempotently reject new sends and let accepted values drain.
      procedure Close;

      --  Append Value, waiting while the open channel is full.
      --  @param Value Value copied into the channel
      --  @exception Channel_Closed Close occurs before the value is accepted
      entry Send (Value : Element_Type);

      --  Remove the oldest value, waiting while the open channel is empty.
      --  @param Value Receives the oldest buffered value
      --  @exception Channel_Closed The closed channel has been fully drained
      entry Receive (Value : out Element_Type);

      --  Attempt to append without waiting.
      --  @param Value Value to copy if capacity is available
      --  @param Result Item_Sent, Channel_Full, or Send_Closed
      procedure Try_Send
        (Value  : Element_Type;
         Result : out Try_Send_Result);

      --  Attempt to remove the oldest value without waiting. Value is assigned
      --  only when Result is Item_Received.
      --  @param Value Receives the oldest buffered value on success
      --  @param Result Item_Received, Channel_Empty, or Receive_Closed
      procedure Try_Receive
        (Value  : in out Element_Type;
         Result : out Try_Receive_Result);

      --  Wait until Close has occurred and the buffer is empty.
      entry Await_Drained;

      --  Read channel state under its protected lock.
      --  @return Current close, buffer, and waiter counts
      function Current return Snapshot;
   private
      Buffer : Element_Array (1 .. Capacity);  --  Circular FIFO storage
      Head   : Positive := 1;  --  Next element to receive
      Tail   : Positive := 1;  --  Next slot to send into
      Count  : Natural := 0;  --  Occupied slots
      Stopped : Boolean := False;  --  Terminal close state
   end Channel;

   --  Append Value within one relative deadline. Negative Timeout waits
   --  indefinitely; zero is an immediate attempt. Once the protected Send is
   --  accepted, success wins over a simultaneous deadline.
   --  @param Item Channel to update
   --  @param Value Value copied into the channel
   --  @param Timeout Deadline interval in seconds
   --  @exception Channel_Closed Close occurs before acceptance
   --  @exception Timeout_Error No capacity is available before the deadline
   procedure Timed_Send
     (Item    : in out Channel;
      Value   : Element_Type;
      Timeout : Duration);

   --  Remove the oldest value within one relative deadline. Negative Timeout
   --  waits indefinitely; zero is an immediate attempt. Values accepted before
   --  Close remain receivable until the channel drains.
   --  @param Item Channel to update
   --  @param Value Receives the oldest buffered value
   --  @param Timeout Deadline interval in seconds
   --  @exception Channel_Closed The closed channel is fully drained
   --  @exception Timeout_Error No value is available before the deadline
   procedure Timed_Receive
     (Item    : in out Channel;
      Value   : out Element_Type;
      Timeout : Duration);

end Flyology.Channels.Bounded;
