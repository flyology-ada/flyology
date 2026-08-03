with Ada.Strings.Unbounded;
with Flyology.Bounded_Channels;
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
      Data : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  Request-scoped WebSocket session. Producer tasks may enqueue messages
   --  but cannot access the connection. Exactly one handler calls Run, and
   --  the session must not outlive that handler's Exchange scope.
   --  @field Capacity Maximum queued outgoing messages
   type Session (Capacity : Positive := 32) is limited private;

   --  Enqueue with backpressure, or return Accepted false after close.
   --  Owner-thread lifecycle callbacks should use Try_Publish to avoid
   --  waiting on their own queue.
   --  @param Item WebSocket session
   --  @param Value Outgoing message
   --  @param Accepted Whether the message was queued
   procedure Publish
     (Item     : in out Session;
      Value    : Outgoing_Message;
      Accepted : out Boolean);

   --  Attempt to enqueue without waiting.
   --  @param Item WebSocket session
   --  @param Value Outgoing message
   --  @param Accepted Whether the message was queued
   procedure Try_Publish
     (Item     : in out Session;
      Value    : Outgoing_Message;
      Accepted : out Boolean);

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
      Data : String);

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
   --  @param Metric_Output Optional lifecycle metric sink
   procedure Run
     (X              : in out Applications.Exchange;
      Item           : in out Session;
      Open           : Open_Handler := null;
      Message        : Message_Handler := null;
      Closed         : Close_Handler := null;
      Protocol       : String := "";
      Origin_Policy  : WebSocket_Origin_Policy := Reject_Browser_Origins;
      Allowed_Origin : String := "";
      Max_Message    : Natural := Max_WebSocket_Frame;
      Receive_Quantum : Duration := 0.05;
      Metric_Output  : access Metrics.Sink'Class := null);

private
   package Message_Channels is new
     Flyology.Bounded_Channels (Outgoing_Message);

   type Session (Capacity : Positive := 32) is limited record
      Outbox : Message_Channels.Channel (Capacity);
      Stop   : Flyology.Cancellation.Token;
   end record;

end Flyology.HTTP.Server.WebSocket_Handlers;
