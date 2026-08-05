--  Internal, proved timeout retry policy used by high-level WebSocket
--  handlers.
private package Flyology.WebSocket_Policy
  with Preelaborate,
       SPARK_Mode => On
is

   type Timeout_Action is (Retry_Receive, Propagate_Timeout);

   --  Retry a receive-quantum timeout only while the connection remains
   --  active and the enclosing request still has retry budget. A negative
   --  remaining value denotes the existing unlimited-deadline sentinel.
   function Classify_Timeout
     (Failed_Or_Terminal : Boolean;
      Remaining          : Duration) return Timeout_Action
   with
     Global         => null,
     Contract_Cases =>
       (Failed_Or_Terminal or else Remaining = 0.0 =>
          Classify_Timeout'Result = Propagate_Timeout,
        others =>
          Classify_Timeout'Result = Retry_Receive);

end Flyology.WebSocket_Policy;
