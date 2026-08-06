with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.CORS;
with Flyology.HTTP.Server.Middleware;

--  Applies route-selected explicit CORS policies.
--  @formal App_Context Application-owned context
--  @formal Components Matching typed middleware package
--  @formal Resolve Resolve a nonzero bounded route policy slot
generic
   type App_Context is limited private;
   with package Components is new
     Flyology.HTTP.Server.Middleware (App_Context);
   with function Resolve (Slot : Positive) return access constant CORS.Policy;
package Flyology.HTTP.Server.Middleware_CORS is

   --  CORS middleware component. Register it in the request-head stage so a
   --  preflight never accepts a request body.
   --  @param Context Typed application context
   --  @param X Borrowed request exchange
   --  @param Next Borrowed downstream continuation
   procedure Call
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange;
      Next    : in out Components.Next_Handler);

end Flyology.HTTP.Server.Middleware_CORS;
