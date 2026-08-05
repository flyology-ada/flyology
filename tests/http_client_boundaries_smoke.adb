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
with Flyology.HTTP.Methods;
with Flyology.IO;
with Flyology.IO.Sockets;

procedure HTTP_Client_Boundaries_Smoke is
   package Client renames Flyology.HTTP.Client;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use type Sockets.Port;
   use type Sockets.Selector_Status;

   CRLF : constant String := Character'Val (13) & Character'Val (10);

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

   protected Coordination is
      procedure Publish (Value : Sockets.Port);
      procedure Finish (Passed : Boolean);
      entry Wait_Ready (Value : out Sockets.Port; Passed : out Boolean);
      entry Wait_Done (Passed : out Boolean);
   private
      Port_Value : Sockets.Port := Sockets.Any_Port;
      Ready      : Boolean := False;
      Done       : Boolean := False;
      OK         : Boolean := True;
   end Coordination;

   protected body Coordination is
      procedure Publish (Value : Sockets.Port) is
      begin
         Port_Value := Value;
         Ready := True;
      end Publish;

      procedure Finish (Passed : Boolean) is
      begin
         OK := OK and Passed;
         Done := True;
      end Finish;

      entry Wait_Ready
        (Value : out Sockets.Port; Passed : out Boolean)
        when Ready or Done
      is
      begin
         Value := Port_Value;
         Passed := OK;
      end Wait_Ready;

      entry Wait_Done (Passed : out Boolean) when Done is
      begin
         Passed := OK;
      end Wait_Done;
   end Coordination;

   task Raw_Server is
      pragma Task_Info (Flyology.Native_Task);
   end Raw_Server;

   task body Raw_Server is
      Listener : Sockets.Socket_Type;
      Peer     : Sockets.Socket_Type;
      Address  : Sockets.Endpoint;
      Status   : Sockets.Selector_Status;

      procedure Accept_Peer is
      begin
         Sockets.Accept_Socket
           (Listener, Peer, Address, Timeout => 2.0, Status => Status);
         pragma Assert (Status = Sockets.Completed);
      end Accept_Peer;

      function Receive_Head return String is
         Buffer : Stream_Element_Array (1 .. 2_048);
         Last   : Stream_Element_Offset;
         Result : Unbounded_String;
      begin
         loop
            Sockets.Receive (Peer, Buffer, Last, Timeout => 2.0);
            pragma Assert (Last >= Buffer'First);
            for Index in Buffer'First .. Last loop
               Append (Result, Character'Val (Buffer (Index)));
            end loop;
            exit when Ada.Strings.Fixed.Index
              (To_String (Result), CRLF & CRLF) /= 0;
         end loop;
         return To_String (Result);
      end Receive_Head;

      procedure Expect_Target (Target : String) is
         Head : constant String := Receive_Head;
      begin
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Head, " " & Target & " HTTP/1.1" & CRLF) /= 0);
      end Expect_Target;

      procedure Expect_Close is
         Buffer : Stream_Element_Array (1 .. 32);
         Last   : Stream_Element_Offset;
      begin
         loop
            Sockets.Receive (Peer, Buffer, Last, Timeout => 2.0);
            exit when Last < Buffer'First;
         end loop;
         Sockets.Close_Socket (Peer);
      end Expect_Close;

      procedure Send (Value : String) is
      begin
         Sockets.Send_All (Peer, Bytes (Value), Timeout => 2.0);
      end Send;

      procedure Send_Bytewise (Value : String) is
      begin
         for Index in Value'Range loop
            Send (Value (Index .. Index));
            delay 0.001;
         end loop;
      end Send_Bytewise;

      procedure Serve_Lane is
      begin
         Accept_Peer;
         Expect_Target ("/fragmented");
         Send_Bytewise
           ("HTTP/1.1 200 Split Fine" & CRLF &
            "X-Split: yes" & CRLF &
            "Transfer-Encoding: chunked" & CRLF &
            "Connection: close" & CRLF & CRLF &
            "1;note=yes" & CRLF & "A" & CRLF &
            "1" & CRLF & "B" & CRLF &
            "0" & CRLF & "X-End: yes" & CRLF & CRLF);
         Expect_Close;

         Accept_Peer;
         Expect_Target ("/head-timeout");
         Expect_Close;

         Accept_Peer;
         Expect_Target ("/body-timeout");
         Send
           ("HTTP/1.1 200 OK" & CRLF &
            "Content-Length: 4" & CRLF & CRLF & "a");
         Expect_Close;

         Accept_Peer;
         Expect_Target ("/body-cancel");
         Send
           ("HTTP/1.1 200 OK" & CRLF &
            "Transfer-Encoding: chunked" & CRLF & CRLF);
         Expect_Close;

         Accept_Peer;
         Expect_Target ("/head-method");
         Send
           ("HTTP/1.1 200 OK" & CRLF &
            "Content-Length: 42" & CRLF &
            "Connection: close" & CRLF & CRLF);
         Expect_Close;
      end Serve_Lane;
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint
           (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener);
      Coordination.Publish (Sockets.Get_Socket_Name (Listener).Port);
      Serve_Lane;
      Serve_Lane;
      Sockets.Close_Socket (Listener);
      Coordination.Finish (True);
   exception
      when Occurrence : others =>
         Ada.Text_IO.Put_Line
           ("HTTP boundary server failed: " &
            Ada.Exceptions.Exception_Information (Occurrence));
         if Sockets.Is_Open (Peer) then
            Sockets.Close_Socket (Peer);
         end if;
         if Sockets.Is_Open (Listener) then
            Sockets.Close_Socket (Listener);
         end if;
         Coordination.Finish (False);
   end Raw_Server;

   procedure Exercise (Port : Sockets.Port) is
      Origin : constant Flyology.HTTP.Origin := Flyology.HTTP.Parse_Origin
        ("http://127.0.0.1:" & Decimal (Natural (Port)));
      HTTP    : aliased Client.Client (Capacity => 1);
      Request : Client.Request;
   begin
      Client.Configure (HTTP, Origin);

      Client.Set_Target (Request, "/fragmented");
      declare
         Response : Client.Response :=
           Client.Execute (HTTP, Request, Timeout => 5.0);
      begin
         pragma Assert (Client.Reason_Phrase (Response) = "Split Fine");
         pragma Assert (Client.Header (Response, "X-Split") = "yes");
         pragma Assert
           (Flyology.Bytes.To_Byte_String (Client.Read_All (Response)) =
              "AB");
         pragma Assert (Client.Trailer (Response, "X-End") = "yes");
      end;

      Client.Set_Target (Request, "/head-timeout");
      declare
         Raised : Boolean := False;
      begin
         begin
            declare
               Unexpected : Client.Response :=
                 Client.Execute (HTTP, Request, Timeout => 0.05);
               pragma Unreferenced (Unexpected);
            begin
               null;
            end;
         exception
            when Flyology.IO.Timeout_Error =>
               Raised := True;
         end;
         pragma Assert (Raised);
      end;

      Client.Set_Target (Request, "/body-timeout");
      declare
         Response : Client.Response :=
           Client.Execute (HTTP, Request, Timeout => 0.05);
         Raised   : Boolean := False;
      begin
         begin
            declare
               Unexpected : constant Flyology.Bytes.Unbounded_Bytes :=
                 Client.Read_All (Response);
               pragma Unreferenced (Unexpected);
            begin
               null;
            end;
         exception
            when Flyology.IO.Timeout_Error =>
               Raised := True;
         end;
         pragma Assert (Raised);
      end;

      Client.Set_Target (Request, "/body-cancel");
      declare
         Response : Client.Response := Client.Execute (HTTP, Request);
         Token    : aliased Flyology.Cancellation.Token;
         Buffer   : Stream_Element_Array (1 .. 8);
         Last     : Stream_Element_Offset;
         Finished : Boolean;
         Raised   : Boolean := False;
      begin
         Token.Request;
         begin
            Client.Read_Body
              (Response, Buffer, Last, Finished, Token => Token'Access);
         exception
            when Flyology.Cancellation.Operation_Cancelled =>
               Raised := True;
         end;
         pragma Assert (Raised);
      end;

      Client.Set_Method (Request, Flyology.HTTP.Methods.HEAD);
      Client.Set_Target (Request, "/head-method");
      declare
         Response : constant Client.Response := Client.Execute (HTTP, Request);
      begin
         pragma Assert (Client.Body_Complete (Response));
         pragma Assert (Client.Header (Response, "Content-Length") = "42");
      end;
      Client.Shutdown (HTTP);
   end Exercise;

   Port      : Sockets.Port;
   Server_OK : Boolean;
begin
   Coordination.Wait_Ready (Port, Server_OK);
   pragma Assert (Server_OK and then Port /= Sockets.Any_Port);
   Exercise (Port);
   declare
      protected Result is
         procedure Finish (Passed : Boolean);
         entry Wait (Passed : out Boolean);
      private
         Done : Boolean := False;
         OK   : Boolean := False;
      end Result;

      protected body Result is
         procedure Finish (Passed : Boolean) is
         begin
            OK := Passed;
            Done := True;
         end Finish;

         entry Wait (Passed : out Boolean) when Done is
         begin
            Passed := OK;
         end Wait;
      end Result;

      task Lightweight_Caller is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Lightweight_Caller;

      task body Lightweight_Caller is
      begin
         Exercise (Port);
         Result.Finish (True);
      exception
         when Occurrence : others =>
            Ada.Text_IO.Put_Line
              ("lightweight HTTP boundaries failed: " &
               Ada.Exceptions.Exception_Information (Occurrence));
            Result.Finish (False);
      end Lightweight_Caller;

      pragma Unreferenced (Lightweight_Caller);
      Passed : Boolean;
   begin
      select
         Result.Wait (Passed);
      or
         delay 10.0;
         raise Program_Error with "lightweight HTTP boundaries did not finish";
      end select;
      pragma Assert (Passed);
   end;
   Coordination.Wait_Done (Server_OK);
   pragma Assert (Server_OK);
end HTTP_Client_Boundaries_Smoke;
