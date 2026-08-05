with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.Bytes;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.IO;
with Flyology.IO.Connections;
with Flyology.IO.Connections.TLS;
with Flyology.IO.Sockets;
with Flyology.IO.TLS;
with Flyology.IO.TLS.OpenSSL;
with Interfaces.C;

procedure HTTP_Client_TLS_Smoke is
   package Client renames Flyology.HTTP.Client;
   package Connections renames Flyology.IO.Connections;
   package Connection_TLS renames Flyology.IO.Connections.TLS;
   package OpenSSL renames Flyology.IO.TLS.OpenSSL;
   package Sockets renames Flyology.IO.Sockets;
   package TLS renames Flyology.IO.TLS;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use type Interfaces.C.int;
   use type Sockets.Selector_Status;

   CRLF : constant String := Character'Val (13) & Character'Val (10);
   Certificate : constant String := "tests/fixtures/tls/server-cert.pem";
   Private_Key : constant String := "tests/fixtures/tls/server-key.pem";
   Library_Directory : constant String :=
     (if Ada.Environment_Variables.Exists ("FLYOLOGY_TEST_OPENSSL_DIR")
      then Ada.Environment_Variables.Value ("FLYOLOGY_TEST_OPENSSL_DIR")
      else "");

   function Open_FD_Count return Interfaces.C.int
     with Import, Convention => C,
          External_Name => "flyology_test_open_fd_count";

   function Bytes (Value : String) return Stream_Element_Array is
      Result : Stream_Element_Array
        (1 .. Stream_Element_Offset (Value'Length));
   begin
      for Offset in 0 .. Value'Length - 1 loop
         Result (Result'First + Stream_Element_Offset (Offset)) :=
           Stream_Element (Character'Pos (Value (Value'First + Offset)));
      end loop;
      return Result;
   end Bytes;

   function Decimal (Value : Natural) return String is
      Image : constant String := Natural'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Decimal;

   protected type Outcome (Expected : Positive) is
      procedure Report (Passed : Boolean);
      entry Wait;
      function Passed return Boolean;
   private
      Count : Natural := 0;
      OK    : Boolean := True;
   end Outcome;

   protected body Outcome is
      procedure Report (Passed : Boolean) is
      begin
         Count := Count + 1;
         OK := OK and Passed;
      end Report;
      entry Wait when Count = Expected is
      begin
         null;
      end Wait;
      function Passed return Boolean is (OK);
   end Outcome;

   procedure Open_Listener
     (Listener : in out Sockets.Socket_Type; Address : out Sockets.Endpoint) is
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint
           (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener);
      Address := Sockets.Get_Socket_Name (Listener);
   end Open_Listener;

   procedure Close_If_Open (Socket : in out Sockets.Socket_Type) is
   begin
      if Sockets.Is_Open (Socket) then
         Sockets.Close_Socket (Socket);
      end if;
   exception
      when others => null;
   end Close_If_Open;

   generic
      Model : Flyology.Execution_Model;
   procedure Run_Success;

   procedure Run_Success is
      Client_Backend : aliased OpenSSL.OpenSSL_Provider;
      Server_Backend : OpenSSL.OpenSSL_Provider;
      Listener       : Sockets.Socket_Type;
      Address        : Sockets.Endpoint;
      Result         : Outcome (2);
   begin
      OpenSSL.Initialize_Client
        (Client_Backend, CA_File => Certificate,
         Library_Directory => Library_Directory);
      OpenSSL.Initialize_Server
        (Server_Backend, Certificate, Private_Key,
         Library_Directory => Library_Directory);
      Open_Listener (Listener, Address);

      declare
         task Server_Task;
         task Client_Task is
            pragma Task_Info (Model);
         end Client_Task;

         task body Server_Task is
            Manager : aliased Connections.Server (Capacity => 1);
            Socket  : Sockets.Socket_Type;
            Peer    : Sockets.Endpoint;
            Status  : Sockets.Selector_Status;
            Channel : Connections.Connection;

            function Receive_Head return String is
               Buffer : Stream_Element_Array (1 .. 2_048);
               Last   : Stream_Element_Offset;
               Head   : Unbounded_String;
            begin
               loop
                  Connections.Receive
                    (Channel, Buffer, Last, Timeout => 3.0);
                  pragma Assert (Last >= Buffer'First);
                  for Index in Buffer'First .. Last loop
                     Append (Head, Character'Val (Buffer (Index)));
                  end loop;
                  exit when Ada.Strings.Fixed.Index
                    (To_String (Head), CRLF & CRLF) /= 0;
               end loop;
               return To_String (Head);
            end Receive_Head;
         begin
            Sockets.Accept_Socket
              (Listener, Socket, Peer, Timeout => 3.0, Status => Status);
            pragma Assert (Status = Sockets.Completed);
            Connections.Take (Manager, Socket, Channel);
            Connection_TLS.Upgrade
              (Channel, Server_Backend, TLS.Server, "", Timeout => 3.0);
            declare
               Head : constant String := Receive_Head;
            begin
               pragma Assert
                 (Ada.Strings.Fixed.Index
                    (Head, "GET /secure HTTP/1.1" & CRLF) = 1);
            end;
            Connections.Send_All
              (Channel,
               Bytes
                 ("HTTP/1.1 200 OK" & CRLF &
                  "Content-Length: 6" & CRLF & CRLF & "secure"),
               Timeout => 3.0);
            declare
               Head : constant String := Receive_Head;
            begin
               pragma Assert
                 (Ada.Strings.Fixed.Index
                    (Head, "GET /again HTTP/1.1" & CRLF) = 1);
            end;
            Connections.Send_All
              (Channel,
               Bytes
                 ("HTTP/1.1 200 OK" & CRLF &
                  "Content-Length: 2" & CRLF &
                  "Connection: close" & CRLF & CRLF & "ok"),
               Timeout => 3.0);
            begin
               Connection_TLS.Shutdown (Channel, Timeout => 3.0);
            exception
               when TLS.TLS_Error | Flyology.IO.Timeout_Error => null;
            end;
            Connections.Close (Channel);
            Close_If_Open (Listener);
            Result.Report (True);
         exception
            when Occurrence : others =>
               Ada.Text_IO.Put_Line
                 ("HTTP TLS server failed: " &
                  Ada.Exceptions.Exception_Information (Occurrence));
               begin
                  Connections.Close (Channel);
               exception
                  when others => null;
               end;
               Close_If_Open (Socket);
               Close_If_Open (Listener);
               Result.Report (False);
         end Server_Task;

         task body Client_Task is
            Item  : aliased Client.Client (Capacity => 1);
            Value : Client.Request;
         begin
            Client.Configure
              (Item,
               Flyology.HTTP.Parse_Origin
                 ("https://localhost:" & Decimal (Natural (Address.Port))),
               Client_Backend'Access);
            Client.Set_Target (Value, "/secure");
            declare
               Reply : Client.Response := Client.Execute (Item, Value);
            begin
               pragma Assert
                 (Flyology.Bytes.To_Byte_String (Client.Read_All (Reply)) =
                    "secure");
            end;
            Client.Set_Target (Value, "/again");
            declare
               Reply : Client.Response := Client.Execute (Item, Value);
            begin
               pragma Assert
                 (Flyology.Bytes.To_Byte_String (Client.Read_All (Reply)) =
                    "ok");
            end;
            declare
               State : constant Client.Client_Diagnostics :=
                 Client.Diagnostics (Item);
            begin
               pragma Assert (State.Transports_Created = 1);
               pragma Assert (State.Transport_Reuses = 1);
               pragma Assert (State.Transports_Closed = 1);
               pragma Assert (State.Active_Exchanges = 0);
            end;
            Client.Shutdown (Item);
            Result.Report (True);
         exception
            when Occurrence : others =>
               Ada.Text_IO.Put_Line
                 ("HTTP TLS client failed: " &
                  Ada.Exceptions.Exception_Information (Occurrence));
               Result.Report (False);
         end Client_Task;
      begin
         Result.Wait;
      end;
      pragma Assert (Result.Passed);
   end Run_Success;

   procedure Run_Hostname_Rejection is
      Client_Backend : aliased OpenSSL.OpenSSL_Provider;
      Server_Backend : OpenSSL.OpenSSL_Provider;
      Listener       : Sockets.Socket_Type;
      Address        : Sockets.Endpoint;
      Result         : Outcome (2);
   begin
      OpenSSL.Initialize_Client
        (Client_Backend, CA_File => Certificate,
         Library_Directory => Library_Directory);
      OpenSSL.Initialize_Server
        (Server_Backend, Certificate, Private_Key,
         Library_Directory => Library_Directory);
      Open_Listener (Listener, Address);
      declare
         task Server_Task;
         task Client_Task;
         task body Server_Task is
            Manager : aliased Connections.Server (Capacity => 1);
            Socket  : Sockets.Socket_Type;
            Peer    : Sockets.Endpoint;
            Status  : Sockets.Selector_Status;
            Channel : Connections.Connection;
            Failed  : Boolean := False;
         begin
            Sockets.Accept_Socket
              (Listener, Socket, Peer, Timeout => 3.0, Status => Status);
            Connections.Take (Manager, Socket, Channel);
            begin
               Connection_TLS.Upgrade
                 (Channel, Server_Backend, TLS.Server, "", Timeout => 3.0);
            exception
               when TLS.TLS_Error | Flyology.IO.Device_Error =>
                  Failed := True;
            end;
            Connections.Close (Channel);
            Close_If_Open (Listener);
            Result.Report (Failed);
         exception
            when others =>
               Result.Report (False);
         end Server_Task;

         task body Client_Task is
            Item     : aliased Client.Client;
            Value    : Client.Request;
            Rejected : Boolean := False;
         begin
            Client.Configure
              (Item,
               Flyology.HTTP.Parse_Origin
                 ("https://127.0.0.1:" & Decimal (Natural (Address.Port))),
               Client_Backend'Access);
            begin
               declare
                  Reply : Client.Response := Client.Execute (Item, Value);
                  pragma Unreferenced (Reply);
               begin
                  null;
               end;
            exception
               when TLS.TLS_Error =>
                  Rejected := True;
            end;
            declare
               State : constant Client.Client_Diagnostics :=
                 Client.Diagnostics (Item);
            begin
               pragma Assert (State.Pending_Transports = 0);
               pragma Assert (State.Active_Exchanges = 0);
            end;
            Client.Shutdown (Item);
            Result.Report (Rejected);
         exception
            when others =>
               Result.Report (False);
         end Client_Task;
      begin
         Result.Wait;
      end;
      pragma Assert (Result.Passed);
   end Run_Hostname_Rejection;

   procedure Run_Handshake_Interruption (Cancel : Boolean) is
      Client_Backend : aliased OpenSSL.OpenSSL_Provider;
      Listener       : Sockets.Socket_Type;
      Address        : Sockets.Endpoint;
      Token          : aliased Flyology.Cancellation.Token;
      Result         : Outcome (2);
      protected Accepted is
         procedure Report;
         entry Wait;
      private
         Done : Boolean := False;
      end Accepted;
      protected body Accepted is
         procedure Report is
         begin
            Done := True;
         end Report;
         entry Wait when Done is
         begin
            null;
         end Wait;
      end Accepted;
   begin
      OpenSSL.Initialize_Client
        (Client_Backend, CA_File => Certificate,
         Library_Directory => Library_Directory);
      Open_Listener (Listener, Address);
      declare
         task Silent_Server;
         task Client_Task;
         task body Silent_Server is
            Socket : Sockets.Socket_Type;
            Peer   : Sockets.Endpoint;
            Status : Sockets.Selector_Status;
         begin
            Sockets.Accept_Socket
              (Listener, Socket, Peer, Timeout => 3.0, Status => Status);
            pragma Assert (Status = Sockets.Completed);
            Accepted.Report;
            delay 0.20;
            Close_If_Open (Socket);
            Close_If_Open (Listener);
            Result.Report (True);
         exception
            when others =>
               Close_If_Open (Socket);
               Close_If_Open (Listener);
               Result.Report (False);
         end Silent_Server;

         task body Client_Task is
            Item   : aliased Client.Client;
            Value  : Client.Request;
            Raised : Boolean := False;
         begin
            Client.Configure
              (Item,
               Flyology.HTTP.Parse_Origin
                 ("https://localhost:" & Decimal (Natural (Address.Port))),
               Client_Backend'Access);
            begin
               declare
                  Reply : Client.Response := Client.Execute
                    (Item, Value,
                     Timeout => (if Cancel then -1.0 else 0.05),
                     Token => (if Cancel then Token'Access else null));
                  pragma Unreferenced (Reply);
               begin
                  null;
               end;
            exception
               when Flyology.IO.Timeout_Error =>
                  Raised := not Cancel;
               when Flyology.Cancellation.Operation_Cancelled =>
                  Raised := Cancel;
            end;
            Client.Shutdown (Item);
            Result.Report (Raised);
         exception
            when Occurrence : others =>
               Ada.Text_IO.Put_Line
                 ("HTTP TLS interruption client failed: " &
                  Ada.Exceptions.Exception_Information (Occurrence));
               Result.Report (False);
         end Client_Task;
      begin
         select
            Accepted.Wait;
         or
            delay 3.0;
         end select;
         if Cancel then
            Token.Request;
         end if;
         Result.Wait;
      end;
      pragma Assert (Result.Passed);
   end Run_Handshake_Interruption;

   procedure Run_Shutdown_During_Handshake is
      Client_Backend : aliased OpenSSL.OpenSSL_Provider;
      Listener       : Sockets.Socket_Type;
      Address        : Sockets.Endpoint;
      Item           : aliased Client.Client;
      Value          : Client.Request;
      Result         : Outcome (2);
      protected Accepted is
         procedure Report;
         entry Wait;
      private
         Done : Boolean := False;
      end Accepted;
      protected body Accepted is
         procedure Report is
         begin
            Done := True;
         end Report;
         entry Wait when Done is
         begin
            null;
         end Wait;
      end Accepted;
   begin
      OpenSSL.Initialize_Client
        (Client_Backend, CA_File => Certificate,
         Library_Directory => Library_Directory);
      Open_Listener (Listener, Address);
      Client.Configure
        (Item,
         Flyology.HTTP.Parse_Origin
           ("https://localhost:" & Decimal (Natural (Address.Port))),
         Client_Backend'Access);
      declare
         task Silent_Server;
         task Client_Task;
         task body Silent_Server is
            Socket : Sockets.Socket_Type;
            Peer   : Sockets.Endpoint;
            Status : Sockets.Selector_Status;
         begin
            Sockets.Accept_Socket
              (Listener, Socket, Peer, Timeout => 3.0, Status => Status);
            pragma Assert (Status = Sockets.Completed);
            Accepted.Report;
            declare
               Buffer : Stream_Element_Array (1 .. 1);
               Last   : Stream_Element_Offset;
            begin
               loop
                  Sockets.Receive (Socket, Buffer, Last, Timeout => 3.0);
                  exit when Last < Buffer'First;
               end loop;
            end;
            Close_If_Open (Socket);
            Close_If_Open (Listener);
            Result.Report (True);
         exception
            when others =>
               Close_If_Open (Socket);
               Close_If_Open (Listener);
               Result.Report (False);
         end Silent_Server;

         task body Client_Task is
            Closed : Boolean := False;
         begin
            begin
               declare
                  Reply : Client.Response := Client.Execute
                    (Item, Value, Timeout => -1.0);
                  pragma Unreferenced (Reply);
               begin
                  null;
               end;
            exception
               when Client.Client_Closed =>
                  Closed := True;
            end;
            Result.Report (Closed);
         exception
            when others =>
               Result.Report (False);
         end Client_Task;
      begin
         Accepted.Wait;
         Client.Shutdown (Item, Timeout => 1.0);
         Result.Wait;
      end;
      pragma Assert (Result.Passed);
      declare
         State : constant Client.Client_Diagnostics :=
           Client.Diagnostics (Item);
      begin
         pragma Assert (State.Pending_Transports = 0);
         pragma Assert (State.Active_Exchanges = 0);
         pragma Assert (State.Closing_Transports = 0);
      end;
   end Run_Shutdown_During_Handshake;

   procedure Run_Native is new Run_Success (Flyology.Native_Task);
   procedure Run_Lightweight is new Run_Success (Flyology.Lightweight_Task);
begin
   --  Warm lazy DNS, event-loop, and OpenSSL process state before measuring
   --  per-campaign descriptor restoration.
   Run_Native;
   Run_Lightweight;
   declare
      Baseline : constant Interfaces.C.int := Open_FD_Count;
   begin
      Run_Native;
      Run_Lightweight;
      Run_Hostname_Rejection;
      Run_Handshake_Interruption (Cancel => False);
      Run_Handshake_Interruption (Cancel => True);
      Run_Shutdown_During_Handshake;
      pragma Assert (Open_FD_Count = Baseline);
   end;
end HTTP_Client_TLS_Smoke;
