with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Logging;
with Flyology.HTTP.Server.Middleware;

--  Records bounded request metadata and monotonic timing through a caller
--  sink.
--  @formal App_Context Application-owned context
--  @formal Components Matching typed middleware package
--  @formal Output Thread-safe application log sink
--  @formal Include_Target Opt-in original target logging
generic
   type App_Context is limited private;
   with package Components is new
     Flyology.HTTP.Server.Middleware (App_Context);
   Output         : not null access Logging.Sink'Class;
   Include_Target : Boolean := False;
package Flyology.HTTP.Server.Middleware_Logging is

   --  Access-log middleware component.
   --  @param Context Typed application context
   --  @param X Borrowed request exchange
   --  @param Next Borrowed downstream continuation
   procedure Call
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange;
      Next    : in out Components.Next_Handler);

end Flyology.HTTP.Server.Middleware_Logging;
