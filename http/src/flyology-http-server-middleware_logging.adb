with Ada.Real_Time;

package body Flyology.HTTP.Server.Middleware_Logging is
   use type Ada.Real_Time.Time;

   package App renames Flyology.HTTP.Server.Applications;

   procedure Call
     (Context : in out App_Context;
      X       : in out App.Exchange;
      Next    : in out Components.Next_Handler)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;

      procedure Observe is
      begin
         Logging.Write
           (Output.all,
            X.Request_Method,
            X.Route_Name,
            (if Include_Target then X.Request_Target else ""),
            X.Response_Status,
            X.Request_ID,
            X.Peer,
            X.Request_Body_Bytes,
            X.Response_Bytes,
            Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started));
      exception
         when others =>
            null;
      end Observe;
   begin
      Next.Call (Context, X);
      Observe;
   exception
      when others =>
         Observe;
         raise;
   end Call;

end Flyology.HTTP.Server.Middleware_Logging;
