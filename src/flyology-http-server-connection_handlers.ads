with Flyology.Cancellation;

--  Runs persistent HTTP requests through one application callback.
--  @formal Handle Application request callback
generic
   --  Process one parsed request. Handle may respond, start an SSE stream, or
   --  accept a WebSocket upgrade through Item.
   --  @param Item HTTP connection for this request
   --  @param Value Parsed request
   with procedure Handle
     (Item  : in out Flyology.HTTP.Server.Connection;
      Value : Flyology.HTTP.Server.Request);

package Flyology.HTTP.Server.Connection_Handlers is

   --  Run requests until transport close or protocol upgrade. A callback that
   --  sends no response receives an automatic 204 response. Protocol errors
   --  receive a best-effort 400 response before propagation.
   --  @param Item HTTP connection
   --  @param Timeout Monotonic deadline interval for each complete request
   --  @param Token Optional cancellation source
   procedure Serve
     (Item    : in out Flyology.HTTP.Server.Connection;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null);

end Flyology.HTTP.Server.Connection_Handlers;
