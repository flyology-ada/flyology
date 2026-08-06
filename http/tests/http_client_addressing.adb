with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.Bytes;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Client.Testing;
with Flyology.IO.Sockets;
with Interfaces.C;

procedure HTTP_Client_Addressing is
   package Client renames Flyology.HTTP.Client;
   package Client_Testing renames Flyology.HTTP.Client.Testing;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use type Interfaces.C.int;
   use type Sockets.Selector_Status;

   CRLF : constant String := Character'Val (13) & Character'Val (10);

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

   procedure Check_Serialized_Authorities is
   begin
      pragma Assert
        (Client_Testing.Serialized_Host
           (Flyology.HTTP.Parse_Origin ("http://example.test")) =
         "example.test");
      pragma Assert
        (Client_Testing.Serialized_Host
           (Flyology.HTTP.Parse_Origin ("https://example.test")) =
         "example.test");
      pragma Assert
        (Client_Testing.Serialized_Host
           (Flyology.HTTP.Parse_Origin ("http://example.test:8080")) =
         "example.test:8080");
      pragma Assert
        (Client_Testing.Serialized_Host
           (Flyology.HTTP.Parse_Origin ("http://[::1]")) = "[::1]");
      pragma Assert
        (Client_Testing.Serialized_Host
           (Flyology.HTTP.Parse_Origin ("http://[::1]:8080")) =
         "[::1]:8080");
   end Check_Serialized_Authorities;

   generic
      Model : Flyology.Execution_Model;
   procedure Run_Lane;

   procedure Run_Lane is
      IPv4_Listener : Sockets.Socket_Type;
      IPv6_Listener : Sockets.Socket_Type;
      IPv4_Address  : Sockets.Endpoint;
      IPv6_Address  : Sockets.Endpoint;
      Result        : Outcome;
   begin
      Sockets.Create_Socket (IPv4_Listener, Sockets.IPv4);
      Sockets.Bind_Socket
        (IPv4_Listener,
         Sockets.Network_Endpoint
           (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (IPv4_Listener);
      IPv4_Address := Sockets.Get_Socket_Name (IPv4_Listener);

      Sockets.Create_Socket (IPv6_Listener, Sockets.IPv6);
      Sockets.Bind_Socket
        (IPv6_Listener,
         Sockets.Network_Endpoint
           (Sockets.Loopback_IPv6, Sockets.Any_Port));
      Sockets.Listen_Socket (IPv6_Listener);
      IPv6_Address := Sockets.Get_Socket_Name (IPv6_Listener);

      declare
         task Server_Task;
         task Client_Task is
            pragma Task_Info (Model);
         end Client_Task;

         task body Server_Task is
            Peer    : Sockets.Socket_Type;
            Address : Sockets.Endpoint;
            Status  : Sockets.Selector_Status;

            procedure Serve
              (Listener : Sockets.Socket_Type;
               Target   : String;
               Host     : String)
            is
               Buffer : Stream_Element_Array (1 .. 2_048);
               Last   : Stream_Element_Offset;
               Head   : Unbounded_String;
            begin
               Sockets.Accept_Socket
                 (Listener, Peer, Address, Timeout => 3.0, Status => Status);
               pragma Assert (Status = Sockets.Completed);
               loop
                  Sockets.Receive (Peer, Buffer, Last, Timeout => 3.0);
                  pragma Assert (Last >= Buffer'First);
                  for Index in Buffer'First .. Last loop
                     Append (Head, Character'Val (Buffer (Index)));
                  end loop;
                  exit when Ada.Strings.Fixed.Index
                    (To_String (Head), CRLF & CRLF) /= 0;
               end loop;
               pragma Assert
                 (Ada.Strings.Fixed.Index
                    (To_String (Head),
                     "GET " & Target & " HTTP/1.1" & CRLF) = 1);
               pragma Assert
                 (Ada.Strings.Fixed.Index
                    (To_String (Head), "Host: " & Host & CRLF) /= 0);
               Sockets.Send_All
                 (Peer,
                  Bytes
                    ("HTTP/1.1 200 OK" & CRLF &
                     "Content-Length: 2" & CRLF &
                     "Connection: close" & CRLF & CRLF & "ok"),
                  Timeout => 3.0);
               Sockets.Close_Socket (Peer);
            end Serve;
         begin
            Serve
              (IPv4_Listener, "/ipv4",
               "127.0.0.1:" & Decimal (Natural (IPv4_Address.Port)));
            Serve
              (IPv4_Listener, "/fallback",
               "localhost:" & Decimal (Natural (IPv4_Address.Port)));
            Serve
              (IPv6_Listener, "/ipv6",
               "[::1]:" & Decimal (Natural (IPv6_Address.Port)));
            Close_If_Open (IPv4_Listener);
            Close_If_Open (IPv6_Listener);
            Result.Report (True);
         exception
            when Occurrence : others =>
               Ada.Text_IO.Put_Line
                 ("HTTP addressing server failed: " &
                  Ada.Exceptions.Exception_Information (Occurrence));
               Close_If_Open (Peer);
               Close_If_Open (IPv4_Listener);
               Close_If_Open (IPv6_Listener);
               Result.Report (False);
         end Server_Task;

         task body Client_Task is
            procedure Fetch (Origin_Text : String; Target : String) is
               HTTP    : aliased Client.Client (Capacity => 1);
               Request : Client.Request;
            begin
               Client.Configure
                 (HTTP, Flyology.HTTP.Parse_Origin (Origin_Text));
               Client.Set_Target (Request, Target);
               declare
                  Reply : Client.Response :=
                    Client.Execute (HTTP, Request, Timeout => 3.0);
               begin
                  pragma Assert
                    (Flyology.Bytes.To_Byte_String
                       (Client.Read_All (Reply)) = "ok");
               end;
               Client.Shutdown (HTTP);
               declare
                  State : constant Client.Client_Diagnostics :=
                    Client.Diagnostics (HTTP);
               begin
                  pragma Assert (State.Transports_Created = 1);
                  pragma Assert (State.Transports_Closed = 1);
                  pragma Assert (State.Pending_Transports = 0);
                  pragma Assert (State.Active_Exchanges = 0);
               end;
            end Fetch;

            procedure Exhaust_All_Addresses is
               Held_IPv6 : Sockets.Socket_Type;
               Held_IPv4 : Sockets.Socket_Type;
               Port      : Sockets.Port;
            begin
               Sockets.Create_Socket (Held_IPv6, Sockets.IPv6);
               Sockets.Bind_Socket
                 (Held_IPv6,
                  Sockets.Network_Endpoint
                    (Sockets.Loopback_IPv6, Sockets.Any_Port));
               Port := Sockets.Get_Socket_Name (Held_IPv6).Port;
               Sockets.Create_Socket (Held_IPv4, Sockets.IPv4);
               Sockets.Bind_Socket
                 (Held_IPv4,
                  Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port));
               --  No other task in this process can claim the paired loopback
               --  port between this close and the immediate client attempt.
               --  Closed endpoints produce deterministic refusal on both
               --  families instead of a platform-dependent listen timeout.
               Close_If_Open (Held_IPv4);
               Close_If_Open (Held_IPv6);
               declare
                  Baseline : constant Interfaces.C.int := Open_FD_Count;
               begin
                  declare
                     HTTP     : aliased Client.Client (Capacity => 1);
                     Request  : Client.Request;
                     Rejected : Boolean := False;
                  begin
                     Client.Configure
                       (HTTP,
                        Flyology.HTTP.Parse_Origin
                          ("http://localhost:" & Decimal (Natural (Port))));
                     begin
                        declare
                           Unexpected : Client.Response :=
                             Client.Execute (HTTP, Request, Timeout => 3.0);
                           pragma Unreferenced (Unexpected);
                        begin
                           null;
                        end;
                     exception
                        when Client.Connection_Error =>
                           Rejected := True;
                     end;
                     pragma Assert (Rejected);
                     declare
                        State : constant Client.Client_Diagnostics :=
                          Client.Diagnostics (HTTP);
                     begin
                        pragma Assert (State.Pending_Transports = 0);
                        pragma Assert (State.Active_Exchanges = 0);
                        pragma Assert (State.Reusable_Transports = 0);
                        pragma Assert (State.Closing_Transports = 0);
                        pragma Assert (State.Transports_Created = 0);
                        pragma Assert (State.Transports_Closed = 0);
                     end;
                     Client.Shutdown (HTTP);
                  end;
                  pragma Assert (Open_FD_Count = Baseline);
               end;
               Close_If_Open (Held_IPv4);
               Close_If_Open (Held_IPv6);
            exception
               when others =>
                  Close_If_Open (Held_IPv4);
                  Close_If_Open (Held_IPv6);
                  raise;
            end Exhaust_All_Addresses;
         begin
            Fetch
              ("http://127.0.0.1:" &
               Decimal (Natural (IPv4_Address.Port)), "/ipv4");
            Fetch
              ("http://localhost:" &
               Decimal (Natural (IPv4_Address.Port)), "/fallback");
            Fetch
              ("http://[::1]:" &
               Decimal (Natural (IPv6_Address.Port)), "/ipv6");
            Exhaust_All_Addresses;
            Result.Report (True);
         exception
            when Occurrence : others =>
               Ada.Text_IO.Put_Line
                 ("HTTP addressing client failed: " &
                  Ada.Exceptions.Exception_Information (Occurrence));
               Result.Report (False);
         end Client_Task;
      begin
         Result.Wait;
      end;
      pragma Assert (Result.Passed);
   exception
      when others =>
         Close_If_Open (IPv4_Listener);
         Close_If_Open (IPv6_Listener);
         raise;
   end Run_Lane;

   procedure Run_Native is new Run_Lane (Flyology.Native_Task);
   procedure Run_Lightweight is new Run_Lane (Flyology.Lightweight_Task);
begin
   Check_Serialized_Authorities;
   Run_Native;
   Run_Lightweight;
   declare
      Baseline : constant Interfaces.C.int := Open_FD_Count;
   begin
      Run_Native;
      Run_Lightweight;
      pragma Assert (Open_FD_Count = Baseline);
   end;
end HTTP_Client_Addressing;
