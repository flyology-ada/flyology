package body Flyology.WebSocket_Policy
  with SPARK_Mode => On
is

   function Classify_Timeout
     (Failed_Or_Terminal : Boolean;
      Remaining          : Duration) return Timeout_Action
   is
     (if Failed_Or_Terminal or else Remaining = 0.0
      then Propagate_Timeout
      else Retry_Receive);

end Flyology.WebSocket_Policy;
