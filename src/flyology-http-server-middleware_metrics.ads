with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Metrics;
with Flyology.HTTP.Server.Middleware;

--  Records request metrics through an application-neutral sink.
--  @formal App_Context Application-owned context
--  @formal Components Matching typed middleware package
--  @formal Output Thread-safe metric sink
generic
   type App_Context is limited private;
   with package Components is new
     Flyology.HTTP.Server.Middleware (App_Context);
   Output : not null access Metrics.Sink'Class;
package Flyology.HTTP.Server.Middleware_Metrics is

   --  Metrics middleware component.
   --  @param Context Typed application context
   --  @param X Borrowed request exchange
   --  @param Next Borrowed downstream continuation
   procedure Call
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange;
      Next    : in out Components.Next_Handler);

end Flyology.HTTP.Server.Middleware_Metrics;
