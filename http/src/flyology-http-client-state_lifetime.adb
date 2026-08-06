separate (Flyology.HTTP.Client)
--  Keeps heap client state alive until both the controlled client and every
--  response reference have released it.
protected body State_Lifetime is
      procedure Retain_Response is
      begin
         if not Client_Live then
            raise Program_Error with "HTTP client is finalizing";
         end if;
         Responses := Responses + 1;
      end Retain_Response;

      procedure Release_Response (Final_Reference : out Boolean) is
      begin
         if Responses = 0 then
            raise Program_Error with "HTTP response state released twice";
         end if;
         Responses := Responses - 1;
         Final_Reference := not Client_Live and then Responses = 0;
      end Release_Response;

      procedure Release_Client (Final_Reference : out Boolean) is
      begin
         if not Client_Live then
            raise Program_Error with "HTTP client state released twice";
         end if;
         Client_Live := False;
         Final_Reference := Responses = 0;
      end Release_Client;
end State_Lifetime;
