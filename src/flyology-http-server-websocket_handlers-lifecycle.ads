with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Metrics;

--  Accessibility-safe WebSocket lifecycle adapter for nested application
--  callbacks. Instantiate it in the callbacks' scope; Run is synchronous.
--  @formal Open Open lifecycle callback
--  @formal Message Inbound-message lifecycle callback
--  @formal Closed Close lifecycle callback
generic
   with procedure Open
     (X : in out Applications.Exchange; Item : in out Session);
   with procedure Message
     (X    : in out Applications.Exchange;
      Item : in out Session;
      Kind : WebSocket_Data_Kind;
      Data : String);
   with procedure Closed
     (X : in out Applications.Exchange; Item : in out Session);
package Flyology.HTTP.Server.WebSocket_Handlers.Lifecycle is

   --  Run the parent lifecycle API without storing callback access values.
   --  @param X Request exchange
   --  @param Item WebSocket session
   --  @param Protocol Optional selected subprotocol
   --  @param Origin_Policy Explicit browser-origin policy
   --  @param Allowed_Origin Exact required origin
   --  @param Max_Message Maximum retained inbound message bytes
   --  @param Receive_Quantum Maximum idle receive interval
   --  @param Max_Outgoing_Burst Messages before servicing inbound frames
   --  @param Metric_Output Optional lifecycle metric sink
   procedure Run
     (X              : in out Applications.Exchange;
      Item           : in out Session;
      Protocol       : String := "";
      Origin_Policy  : WebSocket_Origin_Policy := Reject_Browser_Origins;
      Allowed_Origin : String := "";
      Max_Message    : Natural := Max_WebSocket_Frame;
      Receive_Quantum : Duration := 0.05;
      Max_Outgoing_Burst : Positive := 16;
      Metric_Output  : access Metrics.Sink'Class := null);

end Flyology.HTTP.Server.WebSocket_Handlers.Lifecycle;
