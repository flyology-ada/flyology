with Ada.Real_Time;
with GNAT.Sockets;
with Flyology.IO;
with Flyology.IO.TLS;

package body Flyology.HTTP.Server.Connection_Handlers is

   procedure Serve
     (Item               : in out Flyology.HTTP.Server.Connection;
      Timeout            : Duration := 30.0;
      Max_Body           : Natural := Max_Request_Body;
      Buffer_Body        : Boolean := True;
      Max_Requests       : Natural := 1_000;
      Max_Connection_Age : Duration := 300.0;
      Token              : access Flyology.Cancellation.Token := null)
   is
      use type Ada.Real_Time.Time;

      Value      : Request;
      Closed     : Boolean;
      Count      : Natural := 0;
      Started    : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Request_Started : Ada.Real_Time.Time := Started;
      Request_Budget  : Duration := Timeout;

      function Time_Left return Duration is
         Elapsed : constant Duration := Ada.Real_Time.To_Duration
           (Ada.Real_Time.Clock - Started);
      begin
         if Max_Connection_Age < 0.0 then
            return Timeout;
         elsif Elapsed >= Max_Connection_Age then
            return 0.0;
         elsif Timeout < 0.0 then
            return Max_Connection_Age - Elapsed;
         else
            return Duration'Min (Timeout, Max_Connection_Age - Elapsed);
         end if;
      end Time_Left;

      function Request_Time_Left return Duration is
         Elapsed : constant Duration := Ada.Real_Time.To_Duration
           (Ada.Real_Time.Clock - Request_Started);
      begin
         if Request_Budget < 0.0 then
            return -1.0;
         elsif Elapsed >= Request_Budget then
            return 0.0;
         else
            return Request_Budget - Elapsed;
         end if;
      end Request_Time_Left;

      procedure Best_Effort
        (Status : Positive; Message : String; Retry : Boolean := False) is
      begin
         if Item.State = Reading_HTTP
           and then not Item.Response_Begun
           and then Request_Time_Left /= 0.0
         then
            begin
               Respond
                 (Item, Status, "text/plain; charset=utf-8",
                  Message & Character'Val (10),
                  Extra_Headers =>
                    (if Retry then "Retry-After: 1" & Character'Val (13)
                       & Character'Val (10) else ""),
                  Close => True, Timeout => Request_Time_Left, Token => Token);
            exception
               when others => null;
            end;
         end if;
      end Best_Effort;

      procedure Best_Effort_Bad_Request is
      begin
         Best_Effort (400, "bad request");
      end Best_Effort_Bad_Request;

      procedure Best_Effort_Overloaded is
      begin
         Best_Effort (503, "server ingress budget exhausted", Retry => True);
      end Best_Effort_Overloaded;
   begin
      while Item.State = Reading_HTTP loop
         if Max_Connection_Age >= 0.0 and then Time_Left <= 0.0 then
            return;
         end if;
         Request_Started := Ada.Real_Time.Clock;
         Request_Budget := Time_Left;
         begin
            if Buffer_Body then
               Read_Request
                 (Item, Value, Closed, Time_Left, Max_Body, Token);
            else
               Read_Request_Head
                 (Item, Value, Closed, Time_Left, Max_Body, Token);
            end if;
         exception
            when Payload_Too_Large =>
               Best_Effort (413, "request content is too large");
               return;
            when Expectation_Failed =>
               Best_Effort (417, "request expectation failed");
               return;
            when Resource_Exhausted =>
               Best_Effort_Overloaded;
               return;
            when Protocol_Error =>
               Best_Effort_Bad_Request;
               return;
            when Flyology.IO.Timeout_Error |
                 Flyology.IO.Device_Error |
                 Flyology.IO.TLS.TLS_Error |
                 GNAT.Sockets.Socket_Error =>
               return;
         end;
         exit when Closed;
         Count := Count + 1;
         if (Max_Requests > 0 and then Count >= Max_Requests)
           or else (Max_Connection_Age >= 0.0 and then Time_Left <= 0.0)
         then
            Item.Request_Close := True;
         end if;
         begin
            Handle (Item, Value);
         exception
            when Payload_Too_Large =>
               Best_Effort (413, "request content is too large");
               return;
            when Resource_Exhausted =>
               Best_Effort_Overloaded;
               return;
            when Protocol_Error =>
               Best_Effort_Bad_Request;
               return;
            when Flyology.IO.Timeout_Error |
                 Flyology.IO.Device_Error |
                 Flyology.IO.TLS.TLS_Error |
                 GNAT.Sockets.Socket_Error =>
               return;
         end;
         if Item.State = Reading_HTTP and then not Item.Response_Begun then
            begin
               Respond
                 (Item, 204, "", "", Timeout => Request_Time_Left,
                  Token => Token);
            exception
               when Flyology.IO.Timeout_Error |
                    Flyology.IO.Device_Error |
                    Flyology.IO.TLS.TLS_Error |
                    GNAT.Sockets.Socket_Error =>
                  return;
            end;
         end if;
         exit when Item.State /= Reading_HTTP or else Item.Request_Close;
      end loop;
   end Serve;

end Flyology.HTTP.Server.Connection_Handlers;
