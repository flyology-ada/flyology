package body Flyology.HTTP.Server.WebSocket_Handlers.Lifecycle is

   procedure Run
     (X              : in out Applications.Exchange;
      Item           : in out Session;
      Protocol       : String := "";
      Origin_Policy  : WebSocket_Origin_Policy := Reject_Browser_Origins;
      Allowed_Origin : String := "";
      Max_Message    : Natural := Max_WebSocket_Frame;
      Receive_Quantum : Duration := 0.05;
      Max_Outgoing_Burst : Positive := 16;
      Metric_Output  : access Metrics.Sink'Class := null)
   is
      procedure Call_Open
        (Value_X : in out Applications.Exchange;
         Value_Item : in out Session) is
      begin
         Open (Value_X, Value_Item);
      end Call_Open;

      procedure Call_Message
        (Value_X    : in out Applications.Exchange;
         Value_Item : in out Session;
         Value_Kind : WebSocket_Data_Kind;
         Value_Data : String) is
      begin
         Message (Value_X, Value_Item, Value_Kind, Value_Data);
      end Call_Message;

      procedure Call_Closed
        (Value_X : in out Applications.Exchange;
         Value_Item : in out Session) is
      begin
         Closed (Value_X, Value_Item);
      end Call_Closed;
   begin
      WebSocket_Handlers.Run
        (X, Item, Call_Open'Access, Call_Message'Access,
         Call_Closed'Access, Protocol, Origin_Policy, Allowed_Origin,
         Max_Message, Receive_Quantum, Max_Outgoing_Burst, Metric_Output);
   end Run;

end Flyology.HTTP.Server.WebSocket_Handlers.Lifecycle;
