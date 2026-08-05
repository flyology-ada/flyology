package body Flyology.HTTP.Server.WebSocket_Handlers.Lifecycle is

   procedure Run
     (X              : in out Applications.Exchange;
      Item           : in out Session;
      Protocol       : String := "";
      Origin_Policy  : WebSocket_Origin_Policy := Reject_Browser_Origins;
      Allowed_Origin : String := "";
      Max_Message    : Natural := Default_Max_WebSocket_Message;
      Receive_Quantum : Duration := 0.05;
      Max_Outgoing_Burst : Positive := 16;
      Metric_Output  : access Metrics.Sink'Class := null;
      Compression    : WebSocket_Compression_Mode :=
        No_WebSocket_Compression)
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
         Value_Data : Flyology.Bytes.Unbounded_Bytes) is
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
        (X                  => X,
         Item               => Item,
         Open               => Call_Open'Access,
         Message            => Call_Message'Access,
         Closed             => Call_Closed'Access,
         Protocol           => Protocol,
         Origin_Policy      => Origin_Policy,
         Allowed_Origin     => Allowed_Origin,
         Max_Message        => Max_Message,
         Receive_Quantum    => Receive_Quantum,
         Max_Outgoing_Burst => Max_Outgoing_Burst,
         Metric_Output      => Metric_Output,
         Compression        => Compression);
   end Run;

end Flyology.HTTP.Server.WebSocket_Handlers.Lifecycle;
