with Ada.Finalization;

--  Supplies bounded closeable channels that transfer unique buffer ownership
--  without copying payload bytes. The protected queue carries only pool slot
--  tokens; payload storage remains in the associated pool.
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
   --  the channel and returns any undelivered buffers to Owner.
   type Channel
     (Owner    : not null access Pool;  --  Pool supplying every buffer
      Capacity : Positive)              --  Maximum queued buffer count
   is
     limited new Ada.Finalization.Limited_Controlled with private;

   --  Append Value, waiting while the open channel is full. Success leaves
   --  Value vacant. Close before acceptance raises and preserves Value.
   --  @param Item Channel receiving ownership
   --  @param Value Acquired buffer from Item's pool
   --  @param Metadata Scalar metadata transferred with Value
   --  @exception Channel_Closed Close occurs before acceptance
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
   procedure Timed_Receive_Move
     (Item    : in out Channel;
      Target  : in out Unique_Buffer;
      Timeout : Duration)
     with Pre => not Has_Buffer (Target),
          Post => Has_Buffer (Target);

   --  Receive within one relative deadline and return channel-local metadata.
   --  @param Item Channel yielding ownership
   --  @param Target Vacant buffer that receives ownership on success
   --  @param Timeout Maximum monotonic wait in seconds
   --  @param Metadata Metadata supplied by the sender
   --  @exception Channel_Closed Closed channel has fully drained
   --  @exception Timeout_Error No buffer arrives before the deadline
   procedure Timed_Receive_Move
     (Item     : in out Channel;
      Target   : in out Unique_Buffer;
      Timeout  : Duration;
      Metadata : out Transfer_Metadata)
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

private
   type Token_Array is array (Positive range <>) of Buffer_Token;

   protected type Channel_State (Capacity : Positive) is
      entry Send (Token : Buffer_Token; Accepted : out Boolean);
      entry Receive
        (Token     : out Buffer_Token;
         Available : out Boolean);
      procedure Try_Send
        (Token    : Buffer_Token;
         Result   : out Try_Send_Result;
         Accepted : out Boolean);
      procedure Try_Receive
        (Token  : out Buffer_Token;
         Result : out Try_Receive_Result);
      procedure Close;
      entry Await_Drained;
      function Current return Snapshot;
   private
      Values  : Token_Array (1 .. Capacity) := (others => No_Token);
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

end Flyology.Buffers.Channels;
