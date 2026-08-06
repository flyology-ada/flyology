with Ada.Exceptions;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Middleware;

--  Configures safe application exception handling for one middleware type.
--  Protocol, timeout, cancellation, resource, and transport failures are
--  logged distinctly and re-raised. Map may turn expected application
--  exceptions into a response. Unexpected exceptions become a generic
--  closing 500 before response start; partial responses are failed and closed.
--  @formal App_Context Application-owned context
--  @formal Components Matching typed middleware package
--  @formal Log Application-provided detailed error sink
--  @formal Map Application-provided expected exception mapper
generic
   --  Application context shared by middleware and endpoints.
   type App_Context is limited private;
   --  Typed middleware package for App_Context.
   with package Components is new
     Flyology.HTTP.Server.Middleware (App_Context);
   --  Application-provided detailed error sink.
   with procedure Log
     (Kind  : Components.Failure_Kind;
      Error : Ada.Exceptions.Exception_Occurrence;
      X     : in out Flyology.HTTP.Server.Applications.Exchange) is
     Components.No_Error_Log;
   --  Application-provided expected exception mapper.
   with procedure Map
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange;
      Error   : Ada.Exceptions.Exception_Occurrence;
      Handled : in out Boolean) is Components.No_Error_Map;
package Flyology.HTTP.Server.Middleware_Errors is

   --  Error-handling middleware component.
   --  @param Context Typed application context
   --  @param X Borrowed request exchange
   --  @param Next Borrowed downstream continuation
   procedure Call
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange;
      Next    : in out Components.Next_Handler);

end Flyology.HTTP.Server.Middleware_Errors;
