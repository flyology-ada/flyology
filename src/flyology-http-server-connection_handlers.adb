with Ada.Real_Time;
with GNAT.Sockets;
with Flyology.IO;
with Flyology.IO.TLS;

package body Flyology.HTTP.Server.Connection_Handlers is

   procedure Serve
     (Item               : in out Flyology.HTTP.Server.Connection;
      Timeout            : Duration := 30.0;
      Max_Body           : Natural := Max_Request_Body;
      Max_Requests       : Natural := 1_000;
      Max_Connection_Age : Duration := 300.0;
      Token              : access Flyology.Cancellation.Token := null)
   is
      use type Ada.Real_Time.Time;

      Value      : Request;
      Closed     : Boolean;
      Count      : Natural := 0;
      Started    : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;

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

      procedure Best_Effort_Bad_Request is
      begin
         if Item.State = Reading_HTTP and then not Item.Response_Begun then
            begin
               Respond
                 (Item, 400, "text/plain; charset=utf-8",
                  "bad request" & Character'Val (10), Close => True,
                  Timeout => Time_Left, Token => Token);
            exception
               when others =>
                  null;
            end;
         end if;
      end Best_Effort_Bad_Request;
   begin
      while Item.State = Reading_HTTP loop
         if Max_Connection_Age >= 0.0 and then Time_Left <= 0.0 then
            return;
         end if;
         begin
            Read_Request
              (Item, Value, Closed, Time_Left, Max_Body, Token);
         exception
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
                 (Item, 204, "", "", Timeout => Time_Left, Token => Token);
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
