with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Middleware;

--  Installs bounded request identifiers before application work.
--  @formal App_Context Application-owned context
--  @formal Components Matching typed middleware package
--  @formal Trust_Inbound Whether valid inbound identifiers may be accepted
--  @formal Header_Name Request and response header name
generic
   type App_Context is limited private;
   with package Components is new
     Flyology.HTTP.Server.Middleware (App_Context);
   Trust_Inbound : Boolean := False;
   Header_Name   : String := "X-Request-ID";
package Flyology.HTTP.Server.Middleware_Request_IDs is

   --  Report whether Value is a bounded request identifier containing only
   --  ASCII letters, digits, dot, underscore, and hyphen.
   --  @param Value Candidate identifier
   --  @return True when Value is safe for a response header
   function Valid (Value : String) return Boolean;

   --  Request-ID middleware component.
   --  @param Context Typed application context
   --  @param X Borrowed request exchange
   --  @param Next Borrowed downstream continuation
   procedure Call
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange;
      Next    : in out Components.Next_Handler);

end Flyology.HTTP.Server.Middleware_Request_IDs;
