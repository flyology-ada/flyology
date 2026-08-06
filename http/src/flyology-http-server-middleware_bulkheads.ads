with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Metrics;
with Flyology.HTTP.Server.Middleware;

--  Enforces nonblocking global and route concurrency limits.
--  @formal App_Context Application-owned context
--  @formal Components Matching typed middleware package
--  @formal Global_Limit Global active request bound; zero is unlimited
--  @formal Route_Capacity Maximum distinct route counters
--  @formal Metric_Output Optional denial metric sink
generic
   type App_Context is limited private;
   with package Components is new
     Flyology.HTTP.Server.Middleware (App_Context);
   Global_Limit   : Natural := 0;
   Route_Capacity : Positive := 128;
   Metric_Output  : access Metrics.Sink'Class := null;
package Flyology.HTTP.Server.Middleware_Bulkheads is

   --  Nonblocking bulkhead middleware. Rejection is 503 with Retry-After.
   --  @param Context Typed application context
   --  @param X Borrowed request exchange
   --  @param Next Borrowed downstream continuation
   procedure Call
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange;
      Next    : in out Components.Next_Handler);

end Flyology.HTTP.Server.Middleware_Bulkheads;
