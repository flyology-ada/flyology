with Ada.Strings.Unbounded;
with Flyology.Bounded_Channels;
with Flyology.Cancellation;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Metrics;

--  Supplies an optional sole-writer SSE lifecycle above the raw SSE API.
package Flyology.HTTP.Server.SSE_Handlers is

   --  One queued server-sent event.
   --  @field Data Event data
   --  @field Event Optional event type
   --  @field Id Optional event identifier
   --  @field Retry Optional retry milliseconds
   type Event_Value is record
      Data  : Ada.Strings.Unbounded.Unbounded_String;
      Event : Ada.Strings.Unbounded.Unbounded_String;
      Id    : Ada.Strings.Unbounded.Unbounded_String;
      Retry : Natural := 0;
   end record;

   --  Request-scoped SSE session. Producer tasks may only call Publish,
   --  Try_Publish, Close, and Cancelled. Exactly one connection-owner task
   --  calls Run. The session must not outlive its Exchange handler scope.
   --  @field Capacity Maximum queued events
   type Session (Capacity : Positive := 32) is limited private;

   --  Enqueue with backpressure, or return Accepted false after close.
   --  @param Item SSE session
   --  @param Value Event value
   --  @param Accepted Whether the event was queued
   procedure Publish
     (Item     : in out Session;
      Value    : Event_Value;
      Accepted : out Boolean);

   --  Attempt to enqueue without waiting.
   --  @param Item SSE session
   --  @param Value Event value
   --  @param Accepted Whether the event was queued
   procedure Try_Publish
     (Item     : in out Session;
      Value    : Event_Value;
      Accepted : out Boolean);

   --  Close producer admission after queued events drain.
   --  @param Item SSE session
   procedure Close (Item : in out Session);

   --  Report owner-side failure or disconnect cancellation.
   --  @param Item SSE session
   --  @return True when Run requested producer cancellation
   function Cancelled (Item : Session) return Boolean;

   --  Own the connection, serialize all event writes, and drain until Close.
   --  A send failure closes the mailbox and signals producer cancellation.
   --  @param X Request exchange
   --  @param Item SSE session
   --  @param Metric_Output Optional lifecycle metric sink
   procedure Run
     (X             : in out Applications.Exchange;
      Item          : in out Session;
      Metric_Output : access Metrics.Sink'Class := null);

private
   package Event_Channels is new Flyology.Bounded_Channels (Event_Value);

   type Session (Capacity : Positive := 32) is limited record
      Outbox : Event_Channels.Channel (Capacity);
      Stop   : Flyology.Cancellation.Token;
   end record;

end Flyology.HTTP.Server.SSE_Handlers;
