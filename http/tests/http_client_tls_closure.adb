with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.IO.Connections;
with Flyology.IO.Connections.TLS;
with Flyology.IO.Sockets;
with Flyology.IO.TLS;
with Flyology.IO.TLS.OpenSSL;
with Interfaces.C;

procedure HTTP_Client_TLS_Closure is
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

   type Body_Mode is (Fixed_Length, Chunked, Until_Close);
   type Closure_Mode is (Orderly, Abrupt);

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

   function Target
     (Framing : Body_Mode; Closure : Closure_Mode) return String is
     ("/" &
      (case Framing is
          when Fixed_Length => "fixed",
          when Chunked      => "chunked",
          when Until_Close  => "close") &
      "-" &
      (case Closure is
          when Orderly => "orderly",
          when Abrupt  => "abrupt"));

   function Response_Prefix (Framing : Body_Mode) return String is
     ((case Framing is
         when Fixed_Length =>
           "HTTP/1.1 200 OK" & CRLF &
           "Content-Length: 4" & CRLF &
           "Connection: close" & CRLF & CRLF & "A",
         when Chunked =>
           "HTTP/1.1 200 OK" & CRLF &
           "Transfer-Encoding: chunked" & CRLF &
           "Connection: close" & CRLF & CRLF & "4" & CRLF & "A",
         when Until_Close =>
           "HTTP/1.1 200 OK" & CRLF &
           "Connection: close" & CRLF & CRLF & "A"));

   protected type Outcome is
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

      entry Wait when Count = 2 is
      begin
         null;
      end Wait;

      function Passed return Boolean is (OK);
   end Outcome;

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
   procedure Run_Lane;

   procedure Run_Lane is
      Server_Backend : OpenSSL.OpenSSL_Provider;
      Client_Backend : aliased OpenSSL.OpenSSL_Provider;
      Listener       : Sockets.Socket_Type;
      Address        : Sockets.Endpoint;
      Result         : Outcome;
   begin
      OpenSSL.Initialize_Server
        (Server_Backend, Certificate, Private_Key,
         Library_Directory => Library_Directory);
      OpenSSL.Initialize_Client
        (Client_Backend, CA_File => Certificate,
         Library_Directory => Library_Directory);
      Sockets.Create_Socket (Listener);
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint
           (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener);
      Address := Sockets.Get_Socket_Name (Listener);

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
            for Framing in Body_Mode loop
               for Closure in Closure_Mode loop
                  Sockets.Accept_Socket
                    (Listener, Socket, Peer,
                     Timeout => 3.0, Status => Status);
                  pragma Assert (Status = Sockets.Completed);
                  Connections.Take (Manager, Socket, Channel);
                  Connection_TLS.Upgrade
                    (Channel, Server_Backend, TLS.Server, "",
                     Timeout => 3.0);
                  declare
                     Head : constant String := Receive_Head;
                  begin
                     pragma Assert
                       (Ada.Strings.Fixed.Index
                          (Head, "GET " & Target (Framing, Closure) &
                           " HTTP/1.1" & CRLF) = 1);
                  end;
                  Connections.Send_All
                    (Channel, Bytes (Response_Prefix (Framing)),
                     Timeout => 3.0);
                  if Closure = Orderly then
                     Connection_TLS.Shutdown (Channel, Timeout => 3.0);
                  end if;
                  Connections.Close (Channel);
               end loop;
            end loop;
            Close_If_Open (Listener);
            Result.Report (True);
         exception
            when Occurrence : others =>
               Ada.Text_IO.Put_Line
                 ("HTTP TLS closure server failed: " &
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
            Request : Client.Request;
         begin
            for Framing in Body_Mode loop
               for Closure in Closure_Mode loop
                  declare
                     Item      : aliased Client.Client (Capacity => 1);
                     Matched   : Boolean := False;
                     Collected : Unbounded_String;
                  begin
                     Client.Configure
                       (Item,
                        Flyology.HTTP.Parse_Origin
                          ("https://localhost:" &
                           Decimal (Natural (Address.Port))),
                        Client_Backend'Access);
                     Client.Set_Target (Request, Target (Framing, Closure));
                     declare
                        Reply : Client.Response := Client.Execute
                          (Item, Request, Timeout => 3.0);
                     begin
                        begin
                           loop
                              declare
                                 Buffer   : Stream_Element_Array (1 .. 1);
                                 Last     : Stream_Element_Offset;
                                 Finished : Boolean;
                              begin
                                 Client.Read_Body
                                   (Reply, Buffer, Last, Finished);
                                 if Last >= Buffer'First then
                                    Append
                                      (Collected,
                                       Character'Val
                                         (Buffer (Buffer'First)));
                                 end if;
                                 exit when Finished;
                              end;
                           end loop;
                           Matched := Framing = Until_Close
                             and then Closure = Orderly
                             and then To_String (Collected) = "A";
                        exception
                           when Flyology.HTTP.Protocol_Error =>
                              Matched := Closure = Orderly
                                and then Framing /= Until_Close
                                and then To_String (Collected) = "A";
                           when TLS.TLS_Error =>
                              Matched := Closure = Abrupt
                                and then To_String (Collected) = "A";
                        end;
                     end;
                     pragma Assert (Matched);
                     Client.Shutdown (Item);
                     declare
                        State : constant Client.Client_Diagnostics :=
                          Client.Diagnostics (Item);
                     begin
                        pragma Assert (State.Pending_Transports = 0);
                        pragma Assert (State.Active_Exchanges = 0);
                        pragma Assert (State.Reusable_Transports = 0);
                        pragma Assert (State.Closing_Transports = 0);
                        pragma Assert (State.Transports_Created = 1);
                        pragma Assert (State.Transports_Closed = 1);
                     end;
                  end;
               end loop;
            end loop;
            Result.Report (True);
         exception
            when Occurrence : others =>
               Ada.Text_IO.Put_Line
                 ("HTTP TLS closure client failed: " &
                  Ada.Exceptions.Exception_Information (Occurrence));
               Result.Report (False);
         end Client_Task;
      begin
         Result.Wait;
      end;
      pragma Assert (Result.Passed);
   end Run_Lane;

   procedure Run_Native is new Run_Lane (Flyology.Native_Task);
   procedure Run_Lightweight is new Run_Lane (Flyology.Lightweight_Task);
begin
   Run_Native;
   Run_Lightweight;
   declare
      Baseline : constant Interfaces.C.int := Open_FD_Count;
   begin
      Run_Native;
      Run_Lightweight;
      pragma Assert (Open_FD_Count = Baseline);
   end;
end HTTP_Client_TLS_Closure;
