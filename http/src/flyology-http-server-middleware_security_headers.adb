package body Flyology.HTTP.Server.Middleware_Security_Headers is

   procedure Call
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange;
      Next    : in out Components.Next_Handler)
   is
   begin
      X.Add_Header ("X-Content-Type-Options", "nosniff");
      if Referrer_Policy /= "" then
         X.Add_Header ("Referrer-Policy", Referrer_Policy);
      end if;
      if Content_Security_Policy /= "" then
         X.Add_Header ("Content-Security-Policy", Content_Security_Policy);
      end if;
      if Permissions_Policy /= "" then
         X.Add_Header ("Permissions-Policy", Permissions_Policy);
      end if;
      if Frame_Options /= "" then
         X.Add_Header ("X-Frame-Options", Frame_Options);
      end if;
      if Enable_HSTS then
         X.Add_Header ("Strict-Transport-Security", HSTS_Value);
      end if;
      Next.Call (Context, X);
   end Call;

end Flyology.HTTP.Server.Middleware_Security_Headers;
