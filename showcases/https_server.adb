with Ada.Command_Line;
with Ada.Text_IO;
with GNAT.Sockets;
with Flyology;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.TLS;
with Flyology.IO.Sockets;
with Flyology.IO.TLS;
with Flyology.IO.TLS.OpenSSL;

procedure HTTPS_Server is
   package HTTP renames Flyology.HTTP.Server;
   package Sockets renames GNAT.Sockets;
   package TLS renames Flyology.IO.TLS;
   package OpenSSL renames Flyology.IO.TLS.OpenSSL;

   use type Sockets.Socket_Type;

   Port : constant Sockets.Port_Type :=
     (if Ada.Command_Line.Argument_Count >= 1
      then Sockets.Port_Type'Value (Ada.Command_Line.Argument (1)) else 18_443);
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
      (Family => Sockets.Family_Inet,
       Addr   => Sockets.Loopback_Inet_Addr,
       Port   => Port));
   Sockets.Listen_Socket (Listener, Length => 16);
   Ada.Text_IO.Put_Line
     ("READY https://127.0.0.1:" & Sockets.Port_Type'Image (Port) & "/");
   Ada.Text_IO.Flush;

   declare
      task Worker is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Worker;

      task body Worker is
         Socket : Sockets.Socket_Type := Sockets.No_Socket;
         Peer   : Sockets.Sock_Addr_Type;
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
            if Socket /= Sockets.No_Socket then
               Sockets.Close_Socket (Socket);
            end if;
            raise;
      end Worker;
   begin
      null;
   end;

   Sockets.Close_Socket (Listener);
end HTTPS_Server;
