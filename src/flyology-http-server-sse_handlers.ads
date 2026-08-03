with Ada.Strings.Unbounded;
with Ada.Finalization;
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
   --  @field Include_Id Emit id even when Id is empty
   --  @field Include_Retry Emit retry even when Retry is zero
   type Event_Value is record
      Data  : Ada.Strings.Unbounded.Unbounded_String;
      Event : Ada.Strings.Unbounded.Unbounded_String;
      Id    : Ada.Strings.Unbounded.Unbounded_String;
      Retry : Natural := 0;
      Include_Id : Boolean := False;
      Include_Retry : Boolean := False;
   end record;

   --  Maximum payload bytes retained by one queued event.
   Max_Queued_Message_Bytes : constant := 64 * 1_024;
   --  Default aggregate payload bytes retained by one session.
   Default_Session_Bytes : constant := 256 * 1_024;

   --  Request-scoped SSE session. Producer tasks may only call Publish,
   --  Try_Publish, Close, and Cancelled. Exactly one connection-owner task
   --  calls Run. The session must not outlive its Exchange handler scope.
   --  @field Capacity Maximum queued events
   --  @field Byte_Limit Maximum retained payload bytes in this session
   --  @field Budget Optional shared server/application outbound budget
   type Session
     (Capacity   : Positive := 32;
      Byte_Limit : Positive := Default_Session_Bytes;
      Budget     : access Outbound_Budget := null) is limited private;

   --  Enqueue with backpressure, or return Accepted false after close.
   --  @param Item SSE session
   --  @param Value Event value
   --  @param Accepted Whether the event was queued
   procedure Publish
     (Item     : in out Session;
      Value    : Event_Value;
      Accepted : out Boolean);

   --  Enqueue with bounded, cancellation-aware backpressure.
   --  @param Item SSE session
   --  @param Value Event value
   --  @param Accepted Whether the event was queued
   --  @param Timeout Maximum monotonic wait
   --  @param Timed_Out Whether Timeout expired while the queue stayed full
   --  @param Token Optional cancellation source
   procedure Publish_For
     (Item      : in out Session;
      Value     : Event_Value;
      Accepted  : out Boolean;
      Timeout   : Duration;
      Timed_Out : out Boolean;
      Token     : access Flyology.Cancellation.Token := null);

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
   --  @param Idle_Quantum Maximum wait before checking cancellation/deadline
   --  @param Heartbeat Idle seconds before an SSE comment probes transport;
   --  zero disables heartbeats
   procedure Run
     (X             : in out Applications.Exchange;
      Item          : in out Session;
      Metric_Output : access Metrics.Sink'Class := null;
      Idle_Quantum  : Duration := 0.05;
      Heartbeat     : Duration := 15.0);

private
   type Outbound_Budget_Access is access all Outbound_Budget;

   protected type Retained_Bytes (Limit : Positive) is
      procedure Try_Reserve (Bytes : Natural; Granted : out Boolean);
      procedure Release (Bytes : Natural);
   private
      Used : Natural := 0;
   end Retained_Bytes;
   type Retained_Bytes_Access is access all Retained_Bytes;
   type Session_Access is access all Session;
   type Boolean_Access is access all Boolean;

   Empty_Event : constant Event_Value := (others => <>);
   package Event_Channels is new
     Flyology.Bounded_Channels (Event_Value, Empty_Event);

   type Session
     (Capacity   : Positive := 32;
      Byte_Limit : Positive := Default_Session_Bytes;
      Budget     : access Outbound_Budget := null) is
     limited new Ada.Finalization.Limited_Controlled with record
      Outbox : Event_Channels.Channel (Capacity);
      Stop   : Flyology.Cancellation.Token;
      Bytes  : aliased Retained_Bytes (Byte_Limit);
   end record;

   --  @exclude
   --  @param Item Session whose queued reservations are released
   overriding procedure Finalize (Item : in out Session);

end Flyology.HTTP.Server.SSE_Handlers;
