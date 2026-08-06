with Ada.Real_Time;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Metrics;
with Flyology.HTTP.Server.Middleware;

--  Enforces bounded per-client, per-route token buckets.
--  @formal App_Context Application-owned context
--  @formal Components Matching typed middleware package
--  @formal Client_Key Explicit direct-peer or trusted-proxy key policy
--  @formal Capacity Maximum retained attacker-controlled keys
--  @formal Clock Monotonic clock, replaceable for deterministic tests
--  @formal Metric_Output Optional denial metric sink
generic
   type App_Context is limited private;
   with package Components is new
     Flyology.HTTP.Server.Middleware (App_Context);
   with function Client_Key
     (X : Flyology.HTTP.Server.Applications.Exchange) return String;
   Capacity : Positive := 1_024;
   with function Clock return Ada.Real_Time.Time is Ada.Real_Time.Clock;
   Metric_Output : access Metrics.Sink'Class := null;
package Flyology.HTTP.Server.Middleware_Rate_Limits is

   --  Token-bucket middleware. Burst capacity equals the configured route
   --  requests-per-second rate. Rejection is 429 with Retry-After.
   --  @param Context Typed application context
   --  @param X Borrowed request exchange
   --  @param Next Borrowed downstream continuation
   procedure Call
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange;
      Next    : in out Components.Next_Handler);

end Flyology.HTTP.Server.Middleware_Rate_Limits;
