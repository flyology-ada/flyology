procedure Flyology.WebSocket_Policy.Smoke is
begin
   --  An active connection may retry a finite receive quantum.
   pragma Assert
     (Classify_Timeout
        (Failed_Or_Terminal => False,
         Remaining          => 0.05) = Retry_Receive);

   --  The negative unlimited-deadline sentinel also retains retry budget.
   pragma Assert
     (Classify_Timeout
        (Failed_Or_Terminal => False,
         Remaining          => -1.0) = Retry_Receive);

   --  An exhausted request deadline is terminal for the handler.
   pragma Assert
     (Classify_Timeout
        (Failed_Or_Terminal => False,
         Remaining          => 0.0) = Propagate_Timeout);

   --  Control-write and other terminal failures propagate even when the
   --  request deadline still has time or is unlimited.
   pragma Assert
     (Classify_Timeout
        (Failed_Or_Terminal => True,
         Remaining          => 1.0) = Propagate_Timeout);
   pragma Assert
     (Classify_Timeout
        (Failed_Or_Terminal => True,
         Remaining          => -1.0) = Propagate_Timeout);
end Flyology.WebSocket_Policy.Smoke;
