with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.Bytes;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Client.Authentication;
with Flyology.IO.Sockets;
with Interfaces.C;

procedure HTTP_Client_Authentication is
   package Client renames Flyology.HTTP.Client;
   package Authentication renames Flyology.HTTP.Client.Authentication;
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
      Result : constant String := Natural'Image (Value);
   begin
      return Result (Result'First + 1 .. Result'Last);
   end Decimal;

   generic
      Model : Flyology.Execution_Model;
   procedure Run_Lane;

   procedure Run_Lane is
      Listener      : Sockets.Socket_Type;
      Trap_Listener : Sockets.Socket_Type;
      Address       : Sockets.Endpoint;
      Trap_Address  : Sockets.Endpoint;

      protected Outcome is
         procedure Finish (Passed : Boolean);
         entry Wait (Passed : out Boolean);
      private
         Count : Natural := 0;
         OK   : Boolean := True;
      end Outcome;

      protected body Outcome is
         procedure Finish (Passed : Boolean) is
         begin
            OK := OK and Passed;
            Count := Count + 1;
         end Finish;

         entry Wait (Passed : out Boolean) when Count = 2 is
         begin
            Passed := OK;
         end Wait;
      end Outcome;
   begin
      Sockets.Create_Socket (Listener, Sockets.IPv4);
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint
           (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener);
      Address := Sockets.Get_Socket_Name (Listener);

      Sockets.Create_Socket (Trap_Listener, Sockets.IPv4);
      Sockets.Bind_Socket
        (Trap_Listener,
         Sockets.Network_Endpoint
           (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Trap_Listener);
      Trap_Address := Sockets.Get_Socket_Name (Trap_Listener);

      declare
         task Server_Task;
         task Client_Task is
            pragma Task_Info (Model);
         end Client_Task;

         task body Server_Task is
            Peer : Sockets.Socket_Type;
            Peer_Address : Sockets.Endpoint;
            Status : Sockets.Selector_Status;

            procedure Accept_Peer is
            begin
               Sockets.Accept_Socket
                 (Listener, Peer, Peer_Address, Timeout => 3.0,
                  Status => Status);
               pragma Assert (Status = Sockets.Completed);
            end Accept_Peer;

            function Read_Head return String is
               Buffer : Stream_Element_Array (1 .. 2_048);
               Last   : Stream_Element_Offset;
               Data   : Unbounded_String;
            begin
               loop
                  Sockets.Receive (Peer, Buffer, Last, Timeout => 3.0);
                  pragma Assert (Last >= Buffer'First);
                  for Index in Buffer'First .. Last loop
                     Append (Data, Character'Val (Buffer (Index)));
                  end loop;
                  exit when Ada.Strings.Fixed.Index
                    (To_String (Data), CRLF & CRLF) /= 0;
               end loop;
               return To_String (Data);
            end Read_Head;

            procedure Send (Value : String) is
            begin
               Sockets.Send_All (Peer, Bytes (Value), Timeout => 3.0);
            end Send;

            procedure Close_Peer is
            begin
               if Sockets.Is_Open (Peer) then
                  Sockets.Close_Socket (Peer);
               end if;
            exception
               when others => null;
            end Close_Peer;

            procedure Assert_Request
              (Target : String;
               Authorization : String;
               Expected : Boolean := True;
               Additional : String := "")
            is
               Wire : constant String := Read_Head;
               Field : constant String :=
                 "Authorization: " & Authorization & CRLF;
               Found : constant Natural :=
                 Ada.Strings.Fixed.Index (Wire, Field);
            begin
               pragma Assert
                 (Ada.Strings.Fixed.Index
                    (Wire, "GET " & Target & " HTTP/1.1" & CRLF) = 1);
               if Expected then
                  pragma Assert (Found /= 0);
                  pragma Assert
                    (Ada.Strings.Fixed.Index
                       (Wire, Field, From => Found + Field'Length) = 0);
               else
                  pragma Assert
                    (Ada.Strings.Fixed.Index (Wire, "Authorization:") = 0);
               end if;
               if Additional'Length > 0 then
                  pragma Assert
                    (Ada.Strings.Fixed.Index
                       (Wire, Additional & CRLF) /= 0);
               end if;
            end Assert_Request;

            procedure Reply_OK is
            begin
               Send
                 ("HTTP/1.1 200 OK" & CRLF & "Content-Length: 0" & CRLF &
                  "Connection: close" & CRLF & CRLF);
               Close_Peer;
            end Reply_OK;
         begin
            Accept_Peer;
            Assert_Request
              ("/bearer", "Bearer mF_9.B5f-4.1JqM==",
               Additional => "X-Before: preserved");
            Reply_OK;

            Accept_Peer;
            Assert_Request ("/invalid-bearer", "Bearer retained");
            Reply_OK;

            Accept_Peer;
            Assert_Request
              ("/basic", "Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==");
            Reply_OK;

            Accept_Peer;
            Assert_Request ("/basic-empty", "Basic Og==");
            Reply_OK;

            Accept_Peer;
            Assert_Request
              ("/basic-utf8", "Basic dGVzdDoxMjPCow==");
            Reply_OK;

            Accept_Peer;
            Assert_Request ("/invalid-basic", "Bearer keep");
            Reply_OK;

            Accept_Peer;
            Assert_Request
              ("/clear", "", Expected => False,
               Additional => "X-Retained: yes");
            Reply_OK;

            --  Same-origin redirects retain explicit credentials.
            Accept_Peer;
            Assert_Request ("/redirect", "Bearer same-origin");
            Send
              ("HTTP/1.1 302 Found" & CRLF & "Location: /redirect-final" &
               CRLF & "Content-Length: 0" & CRLF & CRLF);
            Assert_Request ("/redirect-final", "Bearer same-origin");
            Reply_OK;

            --  Cross-origin redirects are returned without contacting the
            --  other authority, so the credential cannot be forwarded.
            Accept_Peer;
            Assert_Request ("/cross-origin", "Bearer origin-only");
            Send
              ("HTTP/1.1 302 Found" & CRLF & "Location: http://127.0.0.1:" &
               Decimal (Natural (Trap_Address.Port)) & "/capture" & CRLF &
               "Content-Length: 0" & CRLF & "Connection: close" & CRLF &
               CRLF);
            Close_Peer;
            declare
               Unexpected : Sockets.Socket_Type;
               Unexpected_Address : Sockets.Endpoint;
            begin
               Sockets.Accept_Socket
                 (Trap_Listener, Unexpected, Unexpected_Address,
                  Timeout => 0.2, Status => Status);
               if Sockets.Is_Open (Unexpected) then
                  Sockets.Close_Socket (Unexpected);
               end if;
               pragma Assert (Status = Sockets.Expired);
            end;
            Outcome.Finish (True);
         exception
            when Error : others =>
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "authentication server: " &
                    Ada.Exceptions.Exception_Information (Error));
               Close_Peer;
               Outcome.Finish (False);
         end Server_Task;

         task body Client_Task is
            HTTP : aliased Client.Client (Capacity => 1);
            Origin : constant Flyology.HTTP.Origin :=
              Flyology.HTTP.Parse_Origin
                ("http://127.0.0.1:" & Decimal (Natural (Address.Port)));
            Passed : Boolean := True;

            procedure Execute_Empty (Value : Client.Request) is
               Reply : Client.Response := Client.Execute (HTTP, Value);
               Content : constant Flyology.Bytes.Unbounded_Bytes :=
                 Client.Read_All (Reply);
               pragma Unreferenced (Content);
            begin
               Passed := Passed and then Client.Status (Reply) in 200 | 302;
            end Execute_Empty;
         begin
            Client.Configure (HTTP, Origin);

            declare
               Request : Client.Request;
            begin
               Client.Set_Target (Request, "/bearer");
               Client.Add_Header (Request, "Authorization", "Old one");
               Client.Add_Header (Request, "X-Before", "preserved");
               Client.Add_Header (Request, "Authorization", "Old two");
               Authentication.Set_Bearer
                 (Request, "mF_9.B5f-4.1JqM==");
               Execute_Empty (Request);
            end;

            declare
               Request : Client.Request;
               Rejected : Boolean := False;
            begin
               Client.Set_Target (Request, "/invalid-bearer");
               Authentication.Set_Bearer (Request, "retained");
               begin
                  Authentication.Set_Bearer (Request, "bad=tail");
               exception
                  when Constraint_Error => Rejected := True;
               end;
               Passed := Passed and then Rejected;
               Execute_Empty (Request);
            end;

            declare
               Request : Client.Request;
            begin
               Client.Set_Target (Request, "/basic");
               Authentication.Set_Basic
                 (Request, "Aladdin", "open sesame");
               Execute_Empty (Request);
            end;

            declare
               Request : Client.Request;
            begin
               Client.Set_Target (Request, "/basic-empty");
               Authentication.Set_Basic (Request, "", "");
               Execute_Empty (Request);
            end;

            declare
               Request : Client.Request;
               Pound_UTF8 : constant String :=
                 Character'Val (16#C2#) & Character'Val (16#A3#);
            begin
               Client.Set_Target (Request, "/basic-utf8");
               Authentication.Set_Basic
                 (Request, "test", "123" & Pound_UTF8);
               Execute_Empty (Request);
            end;

            declare
               Request : Client.Request;
               Colon_Rejected : Boolean := False;
               Control_Rejected : Boolean := False;
            begin
               Client.Set_Target (Request, "/invalid-basic");
               Authentication.Set_Bearer (Request, "keep");
               begin
                  Authentication.Set_Basic (Request, "a:b", "password");
               exception
                  when Constraint_Error => Colon_Rejected := True;
               end;
               begin
                  Authentication.Set_Basic
                    (Request, "user", "bad" & Character'Val (10));
               exception
                  when Constraint_Error => Control_Rejected := True;
               end;
               Passed := Passed
                 and then Colon_Rejected and then Control_Rejected;
               Execute_Empty (Request);
            end;

            declare
               Request : Client.Request;
            begin
               Client.Set_Target (Request, "/clear");
               Client.Add_Header (Request, "Authorization", "First");
               Client.Add_Header (Request, "X-Retained", "yes");
               Client.Add_Header (Request, "Authorization", "Second");
               Authentication.Clear (Request);
               Execute_Empty (Request);
            end;

            declare
               Request : Client.Request;
            begin
               Client.Set_Target (Request, "/redirect");
               Client.Set_Redirects
                 (Request, Client.Default_Same_Origin_Redirects);
               Authentication.Set_Bearer (Request, "same-origin");
               Execute_Empty (Request);
            end;

            declare
               Request : Client.Request;
            begin
               Client.Set_Target (Request, "/cross-origin");
               Client.Set_Redirects
                 (Request, Client.Default_Same_Origin_Redirects);
               Authentication.Set_Bearer (Request, "origin-only");
               Execute_Empty (Request);
            end;

            Client.Shutdown (HTTP);
            declare
               Snapshot : constant Client.Client_Diagnostics :=
                 Client.Diagnostics (HTTP);
            begin
               Passed := Passed
                 and then Snapshot.Pending_Transports = 0
                 and then Snapshot.Active_Exchanges = 0
                 and then Snapshot.Reusable_Transports = 0
                 and then Snapshot.Closing_Transports = 0;
            end;
            Outcome.Finish (Passed);
         exception
            when Error : others =>
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "authentication client: " &
                    Ada.Exceptions.Exception_Information (Error));
               Outcome.Finish (False);
         end Client_Task;
      begin
         null;
      end;

      declare
         Passed : Boolean;
      begin
         Outcome.Wait (Passed);
         if Sockets.Is_Open (Listener) then
            Sockets.Close_Socket (Listener);
         end if;
         if Sockets.Is_Open (Trap_Listener) then
            Sockets.Close_Socket (Trap_Listener);
         end if;
         pragma Assert (Passed);
      end;
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
   Ada.Text_IO.Put_Line ("HTTP client authentication passed");
end HTTP_Client_Authentication;
