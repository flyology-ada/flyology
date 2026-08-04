with Ada.Real_Time;
with Flyology.Cancellation;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.IO.TLS;

package body Flyology.HTTP.Server.Middleware_Metrics is
   use type Ada.Real_Time.Time;

   package App renames Flyology.HTTP.Server.Applications;

   procedure Call
     (Context : in out App_Context;
      X       : in out App.Exchange;
      Next    : in out Components.Next_Handler)
   is
      Started  : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Is_Active : Boolean := False;

      procedure Finish is
      begin
         if Is_Active then
            Metrics.End_Request
              (Output.all,
               X.Request_Method,
               X.Route_Name,
               X.Response_Status,
               Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started),
               X.Request_Body_Bytes,
               X.Response_Bytes);
            Is_Active := False;
         end if;
      exception
         when others =>
            Is_Active := False;
      end Finish;

      procedure Event (Kind : Metrics.Event_Kind) is
      begin
         Metrics.Count (Output.all, Kind);
      exception
         when others =>
            null;
      end Event;
   begin
      begin
         Metrics.Begin_Request (Output.all);
         Is_Active := True;
      exception
         when others =>
            Is_Active := False;
      end;
      begin
         Next.Call (Context, X);
      exception
         when Flyology.HTTP.Protocol_Error =>
            Event (Metrics.Protocol);
            Finish;
            raise;
         when Flyology.IO.Timeout_Error =>
            Event (Metrics.Timeout);
            Finish;
            raise;
         when Flyology.Cancellation.Operation_Cancelled =>
            Event (Metrics.Cancellation);
            Finish;
            raise;
         when Flyology.HTTP.Server.Resource_Exhausted =>
            Event (Metrics.Ingress_Denial);
            Finish;
            raise;
         when Flyology.IO.Device_Error |
              Flyology.IO.TLS.TLS_Error |
              Flyology.IO.Sockets.Socket_Error =>
            Finish;
            raise;
         when others =>
            Finish;
            raise;
      end;
      Finish;
   end Call;

end Flyology.HTTP.Server.Middleware_Metrics;
