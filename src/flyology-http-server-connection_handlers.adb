package body Flyology.HTTP.Server.Connection_Handlers is

   procedure Serve
     (Item    : in out Flyology.HTTP.Server.Connection;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null)
   is
      Value  : Request;
      Closed : Boolean;
   begin
      while Item.State = Reading_HTTP loop
         begin
            Read_Request (Item, Value, Closed, Timeout, Token);
         exception
            when Protocol_Error =>
               if Item.State = Reading_HTTP
                 and then not Item.Response_Begun
               then
                  begin
                     Respond
                       (Item, 400, "text/plain; charset=utf-8",
                        "bad request" & Character'Val (10), Close => True,
                        Timeout => Timeout, Token => Token);
                  exception
                     when others =>
                        null;
                  end;
               end if;
               raise;
         end;
         exit when Closed;
         Handle (Item, Value);
         if Item.State = Reading_HTTP and then not Item.Response_Begun then
            Respond
              (Item, 204, "", "", Timeout => Timeout, Token => Token);
         end if;
         exit when Item.State /= Reading_HTTP or else Item.Request_Close;
      end loop;
   end Serve;

end Flyology.HTTP.Server.Connection_Handlers;
