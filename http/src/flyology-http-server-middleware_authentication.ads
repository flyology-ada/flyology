with Ada.Strings.Unbounded;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Middleware;

--  Applies a caller-defined credential verifier to route authentication modes.
--  Credentials are never logged or retained by this package.
--  @formal App_Context Application-owned context
--  @formal Components Matching typed middleware package
--  @formal Authenticate Caller-defined credential verification hook
--  @formal Challenge Safe WWW-Authenticate challenge
generic
   type App_Context is limited private;
   with package Components is new
     Flyology.HTTP.Server.Middleware (App_Context);
   with procedure Authenticate
     (Scheme        : String;
      Credential    : String;
      Authenticated : out Boolean;
      Principal     : out Ada.Strings.Unbounded.Unbounded_String);
   Challenge : String := "Bearer";
package Flyology.HTTP.Server.Middleware_Authentication is

   --  Return the authorization field for an authentication hook. Callers must
   --  not include the result in logs or metrics.
   --  @param X Borrowed request exchange
   --  @return Authorization field or an empty string
   function Authorization
     (X : Flyology.HTTP.Server.Applications.Exchange) return String;

   --  Authentication middleware component.
   --  @param Context Typed application context
   --  @param X Borrowed request exchange
   --  @param Next Borrowed downstream continuation
   procedure Call
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange;
      Next    : in out Components.Next_Handler);

end Flyology.HTTP.Server.Middleware_Authentication;
