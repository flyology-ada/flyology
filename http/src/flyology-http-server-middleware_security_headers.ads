with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Middleware;

--  Adds an explicitly configured baseline of browser response protections.
--  Empty policy strings omit their fields. HSTS is disabled by default and
--  must only be enabled for an application intentionally deployed over TLS.
--  @formal App_Context Application-owned context
--  @formal Components Matching typed middleware package
--  @formal Content_Security_Policy Configured CSP or empty
--  @formal Permissions_Policy Configured Permissions-Policy or empty
--  @formal Referrer_Policy Configured Referrer-Policy or empty
--  @formal Frame_Options Configured X-Frame-Options or empty
--  @formal Enable_HSTS Whether to emit Strict-Transport-Security
--  @formal HSTS_Value Configured Strict-Transport-Security value
generic
   type App_Context is limited private;
   with package Components is new
     Flyology.HTTP.Server.Middleware (App_Context);
   Content_Security_Policy : String := "";
   Permissions_Policy      : String := "";
   Referrer_Policy         : String := "strict-origin-when-cross-origin";
   Frame_Options           : String := "SAMEORIGIN";
   Enable_HSTS             : Boolean := False;
   HSTS_Value              : String := "max-age=31536000";
package Flyology.HTTP.Server.Middleware_Security_Headers is

   --  Security-header middleware component.
   --  @param Context Typed application context
   --  @param X Borrowed request exchange
   --  @param Next Borrowed downstream continuation
   procedure Call
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange;
      Next    : in out Components.Next_Handler);

end Flyology.HTTP.Server.Middleware_Security_Headers;
