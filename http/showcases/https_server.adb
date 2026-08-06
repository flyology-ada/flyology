with Ada.Command_Line;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.TLS;
with Flyology.IO.Sockets;
with Flyology.IO.TLS;
with Flyology.IO.TLS.OpenSSL;

procedure HTTPS_Server is
   package HTTP renames Flyology.HTTP.Server;
   package Sockets renames Flyology.IO.Sockets;
   package TLS renames Flyology.IO.TLS;
   package OpenSSL renames Flyology.IO.TLS.OpenSSL;

   Port : constant Sockets.Port :=
     (if Ada.Command_Line.Argument_Count >= 1
      then Sockets.Port'Value (Ada.Command_Line.Argument (1)) else 18_443);
   Certificate : constant String :=
     (if Ada.Command_Line.Argument_Count >= 2
      then Ada.Command_Line.Argument (2)
      else "tests/fixtures/tls/server-cert.pem");
   Private_Key : constant String :=
     (if Ada.Command_Line.Argument_Count >= 3
      then Ada.Command_Line.Argument (3)
      else "tests/fixtures/tls/server-key.pem");
   Library_Directory : constant String :=
     (if Ada.Command_Line.Argument_Count >= 4
      then Ada.Command_Line.Argument (4) else "");

   Backend  : OpenSSL.OpenSSL_Provider;
   Listener : Sockets.Socket_Type;
begin
   OpenSSL.Initialize_Server
     (Backend, Certificate, Private_Key,
      Library_Directory => Library_Directory);
   Sockets.Create_Socket (Listener);
   Sockets.Set_Socket_Option
     (Listener,
      Sockets.Socket_Level,
      (Sockets.Reuse_Address, True));
   Sockets.Bind_Socket
     (Listener,
      Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port));
   Sockets.Listen_Socket (Listener, Length => 16);
   Ada.Text_IO.Put_Line
     ("READY https://127.0.0.1:"
      & Ada.Strings.Fixed.Trim
          (Sockets.Port'Image (Port), Ada.Strings.Both) & "/");
   Ada.Text_IO.Flush;

   declare
      task Worker is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Worker;

      task body Worker is
         Socket : Sockets.Socket_Type;
         Peer   : Sockets.Endpoint;
         Secure : aliased TLS.Connection;
      begin
         Flyology.IO.Sockets.Accept_Connection
           (Listener, Socket, Peer, Timeout => 30.0);
         TLS.Take (Backend, Socket, TLS.Server, "", Secure);
         TLS.Handshake (Secure, Timeout => 5.0);
         declare
            Channel : aliased HTTP.TLS.Connection_Transport (Secure'Access);
            Client  : HTTP.Connection (Channel'Access);
            Request : HTTP.Request;
            Closed  : Boolean;
         begin
            HTTP.Read_Request (Client, Request, Closed, Timeout => 5.0);
            if not Closed then
               HTTP.Respond
                 (Client, 200, "text/plain; charset=utf-8",
                  "hello over Flyology TLS" & ASCII.LF,
                  Close => True, Timeout => 5.0);
            end if;
         end;
         TLS.Shutdown (Secure, Timeout => 5.0);
         TLS.Close (Secure);
      exception
         when others =>
            if Sockets.Is_Open (Socket) then
               Sockets.Close_Socket (Socket);
            end if;
            raise;
      end Worker;
   begin
      null;
   end;

   Sockets.Close_Socket (Listener);
end HTTPS_Server;
