with EWS.Dynamic;
with EWS.HTTP;
with EWS.Server;
with GNAT.Sockets;
with Servlet.Requests.EWS;
with Servlet.Responses.EWS;

--  ServletAda's EWS backend passes Tracing => True unconditionally. This
--  benchmark-local backend uses the same public ServletAda and EWS dispatch
--  APIs with tracing disabled, matching every other measured adapter.
package body Benchmark_Server_Init is
   Current : Container_Access;

   function Handle
     (Request : EWS.HTTP.Request_P) return EWS.Dynamic.Dynamic_Response'Class;

   function Handle
     (Request : EWS.HTTP.Request_P) return EWS.Dynamic.Dynamic_Response'Class
   is
      Incoming : Servlet.Requests.EWS.Request (Request);
      Outgoing : Servlet.Responses.EWS.Response (Request);
   begin
      Current.Service (Incoming, Outgoing);
      Outgoing.Build;
      return Outgoing.Get_Data;
   end Handle;

   overriding
   procedure Configure
     (Server : in out Container_Type;
      Config : in Servlet.Server.Configuration) is
   begin
      Server.Config := Config;
   end Configure;

   overriding
   procedure Start (Server : in out Container_Type) is
   begin
      Current := Server'Unchecked_Access;
      Servlet.Server.Container (Server).Start;
      EWS.Dynamic.Register_Default (Handle'Access);
      EWS.Server.Serve
        (Using_Port => GNAT.Sockets.Port_Type (Server.Config.Listening_Port),
         With_Stack => 1_000_000,
         Tracing    => False);
   end Start;
end Benchmark_Server_Init;
