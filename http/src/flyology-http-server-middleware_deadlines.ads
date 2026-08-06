with Ada.Real_Time;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Middleware;

--  Narrows, but never restarts or extends, an absolute request deadline.
--  @formal App_Context Application-owned context
--  @formal Components Matching typed middleware package
--  @formal Maximum Maximum remaining middleware interval
--  @formal Clock Monotonic clock, replaceable for deterministic tests
generic
   type App_Context is limited private;
   with package Components is new
     Flyology.HTTP.Server.Middleware (App_Context);
   Maximum : Duration;
   with function Clock return Ada.Real_Time.Time is Ada.Real_Time.Clock;
package Flyology.HTTP.Server.Middleware_Deadlines is

   --  Deadline-narrowing middleware component.
   --  @param Context Typed application context
   --  @param X Borrowed request exchange
   --  @param Next Borrowed downstream continuation
   procedure Call
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange;
      Next    : in out Components.Next_Handler);

end Flyology.HTTP.Server.Middleware_Deadlines;
