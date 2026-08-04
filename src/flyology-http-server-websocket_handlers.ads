with Ada.Finalization;
with Flyology.Bounded_Channels;
with Flyology.Buffers;
with Flyology.Buffers.Channels;
with Flyology.Bytes;
with Flyology.Cancellation;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Metrics;

--  Supplies an optional sole-writer WebSocket lifecycle above the raw API.
package Flyology.HTTP.Server.WebSocket_Handlers is

   --  One queued outgoing WebSocket application message.
   --  @field Kind Text or binary frame
   --  @field Data Complete message payload
   type Outgoing_Message is record
      Kind : WebSocket_Data_Kind := Text_Frame;
      Data : Flyology.Bytes.Unbounded_Bytes;
   end record;

   --  Maximum payload bytes retained by one queued message.
   Max_Queued_Message_Bytes : constant := 64 * 1_024;
   --  Default aggregate payload bytes retained by one session.
   Default_Session_Bytes : constant := 256 * 1_024;

   --  Request-scoped WebSocket session. Producer tasks may enqueue messages
   --  but cannot access the connection. Exactly one handler calls Run, and
   --  the session must not outlive that handler's Exchange scope.
   --  @field Capacity Maximum queued outgoing messages
   --  @field Byte_Limit Maximum retained payload bytes in this session
   --  @field Budget Optional shared server/application outbound budget
   --  @field Buffer_Pool Optional pool enabling ownership-transfer publishing;
   --     the access discriminant requires the pool to outlive the session
   type Session
     (Capacity   : Positive := 32;
      Byte_Limit : Positive := Default_Session_Bytes;
      Budget     : access Outbound_Budget := null;
      Buffer_Pool : access Flyology.Buffers.Pool := null) is limited private;

   --  Enqueue with backpressure, or return Accepted false after close.
   --  Owner-thread lifecycle callbacks should use Try_Publish to avoid
   --  waiting on their own queue.
   --  @param Item WebSocket session
   --  @param Value Outgoing message
   --  @param Accepted Whether the message was queued
   --  @exception Program_Error Item is configured for moved buffers
   procedure Publish
     (Item     : in out Session;
      Value    : Outgoing_Message;
      Accepted : out Boolean);

   --  Enqueue with bounded, cancellation-aware backpressure.
   --  @param Item WebSocket session
   --  @param Value Outgoing message
   --  @param Accepted Whether the message was queued
   --  @param Timeout Maximum monotonic wait
   --  @param Timed_Out Whether Timeout expired while the queue stayed full
   --  @param Token Optional cancellation source
   --  @exception Program_Error Item is configured for moved buffers
   procedure Publish_For
     (Item      : in out Session;
      Value     : Outgoing_Message;
      Accepted  : out Boolean;
      Timeout   : Duration;
      Timed_Out : out Boolean;
      Token     : access Flyology.Cancellation.Token := null);

   --  Attempt to enqueue without waiting.
   --  @param Item WebSocket session
   --  @param Value Outgoing message
   --  @param Accepted Whether the message was queued
   --  @exception Program_Error Item is configured for moved buffers
   procedure Try_Publish
     (Item     : in out Session;
      Value    : Outgoing_Message;
      Accepted : out Boolean);

   --  Enqueue a pooled payload by transferring ownership without copying.
   --  Item must be configured with Value's pool.
   --  Success leaves Value vacant; close or admission failure preserves it.
   --  @param Item WebSocket session with a configured buffer pool
   --  @param Kind Text or binary frame
   --  @param Value Acquired payload buffer
   --  @param Accepted Whether ownership transferred to the session
   procedure Publish_Move
     (Item     : in out Session;
      Kind     : WebSocket_Data_Kind;
      Value    : in out Flyology.Buffers.Unique_Buffer;
      Accepted : out Boolean)
     with Pre => Flyology.Buffers.Has_Buffer (Value),
          Post => Accepted = (not Flyology.Buffers.Has_Buffer (Value));

   --  Enqueue a pooled payload with bounded, cancellation-aware backpressure.
   --  Timeout or close preserves Value.
   --  @param Item WebSocket session with a configured buffer pool
   --  @param Kind Text or binary frame
   --  @param Value Acquired payload buffer
   --  @param Accepted Whether ownership transferred to the session
   --  @param Timeout Maximum monotonic wait
   --  @param Timed_Out Whether Timeout expired before transfer
   --  @param Token Optional cancellation source
   procedure Publish_Move_For
     (Item      : in out Session;
      Kind      : WebSocket_Data_Kind;
      Value     : in out Flyology.Buffers.Unique_Buffer;
      Accepted  : out Boolean;
      Timeout   : Duration;
      Timed_Out : out Boolean;
      Token     : access Flyology.Cancellation.Token := null)
     with Pre => Flyology.Buffers.Has_Buffer (Value),
          Post => Accepted = (not Flyology.Buffers.Has_Buffer (Value));

   --  Attempt to transfer a pooled payload without waiting.
   --  @param Item WebSocket session with a configured buffer pool
   --  @param Kind Text or binary frame
   --  @param Value Acquired payload buffer
   --  @param Accepted Whether ownership transferred to the session
   procedure Try_Publish_Move
     (Item     : in out Session;
      Kind     : WebSocket_Data_Kind;
      Value    : in out Flyology.Buffers.Unique_Buffer;
      Accepted : out Boolean)
     with Pre => Flyology.Buffers.Has_Buffer (Value),
          Post => Accepted = (not Flyology.Buffers.Has_Buffer (Value));

   --  Request a normal server close after queued messages drain.
   --  @param Item WebSocket session
   procedure Close (Item : in out Session);

   --  Report owner-side failure or disconnect cancellation.
   --  @param Item WebSocket session
   --  @return True when Run requested producer cancellation
   function Cancelled (Item : Session) return Boolean;

   --  Lifecycle callback invoked by the sole connection owner. It may inspect
   --  the Exchange and enqueue through Session, but must not retain either.
   --  @param X Borrowed request exchange
   --  @param Item Request-scoped WebSocket session
   type Open_Handler is access procedure
     (X : in out Applications.Exchange; Item : in out Session);

   --  Lifecycle callback for one fully reassembled inbound message.
   --  @param X Borrowed request exchange
   --  @param Item Request-scoped WebSocket session
   --  @param Kind Text or binary message kind
   --  @param Data Complete message payload
   type Message_Handler is access procedure
     (X    : in out Applications.Exchange;
      Item : in out Session;
      Kind : WebSocket_Data_Kind;
      Data : Flyology.Bytes.Unbounded_Bytes);

   --  Lifecycle callback invoked once after a peer or server close.
   --  @param X Borrowed request exchange
   --  @param Item Request-scoped WebSocket session
   type Close_Handler is access procedure
     (X : in out Applications.Exchange; Item : in out Session);

   --  Upgrade, invoke lifecycle callbacks, serialize outgoing writes, and
   --  receive until either peer or application closes. A short receive quantum
   --  lets an idle peer coexist with mailbox producers without a second
   --  connection writer. The absolute Exchange deadline remains authoritative.
   --  @param X Request exchange
   --  @param Item WebSocket session
   --  @param Open Optional open callback
   --  @param Message Optional inbound-message callback
   --  @param Closed Optional close callback
   --  @param Protocol Optional selected subprotocol
   --  @param Origin_Policy Explicit browser-origin policy
   --  @param Allowed_Origin Exact origin for Require_Exact_Origin
   --  @param Max_Message Maximum retained/reassembled inbound message bytes
   --  @param Receive_Quantum Maximum idle receive interval
   --  @param Max_Outgoing_Burst Messages sent before servicing inbound frames
   --  @param Metric_Output Optional lifecycle metric sink
   procedure Run
     (X              : in out Applications.Exchange;
      Item           : in out Session;
      Open           : access procedure
        (X : in out Applications.Exchange; Item : in out Session) := null;
      Message        : access procedure
        (X    : in out Applications.Exchange;
         Item : in out Session;
         Kind : WebSocket_Data_Kind;
         Data : Flyology.Bytes.Unbounded_Bytes) := null;
      Closed         : access procedure
        (X : in out Applications.Exchange; Item : in out Session) := null;
      Protocol       : String := "";
      Origin_Policy  : WebSocket_Origin_Policy := Reject_Browser_Origins;
      Allowed_Origin : String := "";
      Max_Message    : Natural := Max_WebSocket_Frame;
      Receive_Quantum : Duration := 0.05;
      Max_Outgoing_Burst : Positive := 16;
      Metric_Output  : access Metrics.Sink'Class := null);

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
   package Buffer_Channels renames Flyology.Buffers.Channels;
   type Buffer_Channel_Access is access Buffer_Channels.Channel;

   Empty_Message : constant Outgoing_Message := (others => <>);
   package Message_Channels is new
     Flyology.Bounded_Channels (Outgoing_Message, Empty_Message);

   type Session
     (Capacity   : Positive := 32;
      Byte_Limit : Positive := Default_Session_Bytes;
      Budget     : access Outbound_Budget := null;
      Buffer_Pool : access Flyology.Buffers.Pool := null) is
     limited new Ada.Finalization.Limited_Controlled with record
      Outbox        : Message_Channels.Channel (Capacity);
      Buffer_Outbox : Buffer_Channel_Access :=
        (if Buffer_Pool = null
         then null
         else new Buffer_Channels.Channel (Buffer_Pool, Capacity));
      Stop          : Flyology.Cancellation.Token;
      Bytes         : aliased Retained_Bytes (Byte_Limit);
   end record;

   --  @exclude
   --  @param Item Session whose queued reservations are released
   overriding procedure Finalize (Item : in out Session);

end Flyology.HTTP.Server.WebSocket_Handlers;
