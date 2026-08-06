with Flyology.IO.Sockets;

--  Defines an application-provided access-log sink boundary.
package Flyology.HTTP.Server.Logging is

   --  Thread-safe application log sink. Implementations must not retain
   --  borrowed strings and should not raise from Write.
   type Sink is limited interface;

   --  Observe one completed request. Target is empty unless an application
   --  explicitly enabled target logging; no credentials, cookies,
   --  authorization field, or body are supplied.
   --  @param Item Log sink
   --  @param Method Request method
   --  @param Route Stable normalized route name
   --  @param Target Optional request target
   --  @param Status Final status or zero
   --  @param Request_ID Validated request identifier
   --  @param Peer Connected peer
   --  @param Request_Bytes Decoded request body bytes
   --  @param Response_Bytes Response payload bytes
   --  @param Elapsed Monotonic elapsed seconds
   procedure Write
     (Item           : in out Sink;
      Method         : String;
      Route          : String;
      Target         : String;
      Status         : Natural;
      Request_ID     : String;
      Peer           : Flyology.IO.Sockets.Endpoint;
      Request_Bytes  : Natural;
      Response_Bytes : Natural;
      Elapsed        : Duration) is abstract;

end Flyology.HTTP.Server.Logging;
