package body Flyology.HTTP.Server.TLS is

   overriding procedure Receive
     (Item    : in out Connection_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token) is
   begin
      Flyology.IO.TLS.Receive
        (Item.Channel.all, Data, Last, Timeout => Timeout, Token => Token);
   end Receive;

   overriding procedure Send_All
     (Item    : in out Connection_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token) is
   begin
      Flyology.IO.TLS.Send_All
        (Item.Channel.all, Data, Timeout => Timeout, Token => Token);
   end Send_All;

end Flyology.HTTP.Server.TLS;
