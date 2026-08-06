with Flyology.Cancellation;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.IO.TLS;

package body Flyology.HTTP.Server.Middleware_Errors is

   package App renames Flyology.HTTP.Server.Applications;
   use type App.Response_State;

   procedure Call
     (Context : in out App_Context;
      X       : in out App.Exchange;
      Next    : in out Components.Next_Handler)
   is
   begin
      Components.Call (Next, Context, X);
   exception
      when Error : Flyology.HTTP.Protocol_Error =>
         Log (Components.Protocol_Failure, Error, X);
         raise;
      when Error : Flyology.HTTP.Server.Payload_Too_Large |
           Flyology.HTTP.Server.Expectation_Failed =>
         Log (Components.Protocol_Failure, Error, X);
         raise;
      when Error : Flyology.IO.Timeout_Error =>
         Log (Components.Timeout_Failure, Error, X);
         raise;
      when Error : Flyology.Cancellation.Operation_Cancelled =>
         Log (Components.Cancellation_Failure, Error, X);
         raise;
      when Error : Flyology.HTTP.Server.Resource_Exhausted =>
         Log (Components.Resource_Failure, Error, X);
         raise;
      when Error : Flyology.IO.Device_Error |
           Flyology.IO.TLS.TLS_Error |
           Flyology.IO.Sockets.Socket_Error =>
         Log (Components.Transport_Failure, Error, X);
         raise;
      when Error : others =>
         declare
            Handled : Boolean := False;
         begin
            Log (Components.Application_Failure, Error, X);
            begin
               Map (Context, X, Error, Handled);
            exception
               when Mapping_Error : others =>
                  Log (Components.Application_Failure, Mapping_Error, X);
                  Handled := False;
            end;
            if not Handled then
               if X.Response = App.Not_Started
                 and then not X.Wire_Response_Started
               then
                  X.Respond
                    (500,
                     "application/problem+json",
                     "{""type"":""internal-server-error""," &
                     """status"":500," &
                     """detail"":""Internal server error""}",
                     Close => True);
               else
                  X.Mark_Failed;
               end if;
            end if;
         end;
   end Call;

end Flyology.HTTP.Server.Middleware_Errors;
