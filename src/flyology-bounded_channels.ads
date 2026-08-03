--  Supplies fixed-capacity closeable channels with ordinary Ada entry
--  semantics. A blocked sender or receiver resumes when the channel closes.
--  @formal Element_Type Value transferred by the channel
--  @formal Empty_Value Value assigned after dequeue to release slot storage
generic
   type Element_Type is private;
   Empty_Value : Element_Type;
package Flyology.Bounded_Channels is

   --  Fixed-capacity multi-producer, multi-consumer channel.
   --  @field Capacity Maximum queued values
   type Channel (Capacity : Positive) is tagged limited private;

   --  Wait for space and enqueue Value, or return Accepted false after
   --  Close. The entry provides natural lightweight-task backpressure.
   --  @param Item Channel
   --  @param Value Value to enqueue
   --  @param Accepted False only when closed
   procedure Send
     (Item     : in out Channel;
      Value    : Element_Type;
      Accepted : out Boolean);

   --  Wait for a value. Values queued before Close remain receivable;
   --  Available is false once the closed channel is empty.
   --  @param Item Channel
   --  @param Value Received value when Available
   --  @param Available Whether a value was returned
   procedure Receive
     (Item      : in out Channel;
      Value     : out Element_Type;
      Available : out Boolean);

   --  Wait for a value for at most Timeout seconds. A negative timeout waits
   --  without a deadline. Timed_Out distinguishes an open empty channel from
   --  a closed and drained channel.
   --  @param Item Channel
   --  @param Value Received value when Available
   --  @param Available Whether a value was returned
   --  @param Timeout Maximum monotonic wait in seconds
   --  @param Timed_Out True only when the wait interval expired
   procedure Receive_For
     (Item      : in out Channel;
      Value     : out Element_Type;
      Available : out Boolean;
      Timeout   : Duration;
      Timed_Out : out Boolean);

   --  Attempt to enqueue without waiting.
   --  @param Item Channel
   --  @param Value Value to enqueue
   --  @param Accepted True only when open space was available
   procedure Try_Send
     (Item     : in out Channel;
      Value    : Element_Type;
      Accepted : out Boolean);

   --  Wait for space for at most Timeout seconds. A negative timeout waits
   --  without a deadline. Closing the channel returns Accepted false without
   --  setting Timed_Out.
   --  @param Item Channel
   --  @param Value Value to enqueue
   --  @param Accepted Whether the value was queued
   --  @param Timeout Maximum monotonic wait in seconds
   --  @param Timed_Out True only when the wait interval expired
   procedure Send_For
     (Item      : in out Channel;
      Value     : Element_Type;
      Accepted  : out Boolean;
      Timeout   : Duration;
      Timed_Out : out Boolean);

   --  Attempt to receive without waiting.
   --  @param Item Channel
   --  @param Value Received value when Available
   --  @param Available True only when a queued value was available
   procedure Try_Receive
     (Item      : in out Channel;
      Value     : out Element_Type;
      Available : out Boolean);

   --  Idempotently close the channel and wake blocked callers.
   --  @param Item Channel
   procedure Close (Item : in out Channel);

   --  Report whether Close was called.
   --  @param Item Channel
   --  @return True after closure
   function Is_Closed (Item : Channel) return Boolean;

   --  Return queued value count.
   --  @param Item Channel
   --  @return Current queue depth
   function Length (Item : Channel) return Natural;

private
   type Element_Array is array (Positive range <>) of Element_Type;

   protected type Channel_State (Capacity : Positive) is
      entry Send (Value : Element_Type; Accepted : out Boolean);
      entry Receive (Value : out Element_Type; Available : out Boolean);
      procedure Try_Send (Value : Element_Type; Accepted : out Boolean);
      procedure Try_Receive
        (Value : out Element_Type; Available : out Boolean);
      procedure Close;
      function Is_Closed return Boolean;
      function Length return Natural;
   private
      Values : Element_Array (1 .. Capacity);
      Head   : Positive := 1;
      Tail   : Positive := 1;
      Count  : Natural := 0;
      Closed : Boolean := False;
   end Channel_State;

   type Channel (Capacity : Positive) is tagged limited record
      State : Channel_State (Capacity);
   end record;

end Flyology.Bounded_Channels;
