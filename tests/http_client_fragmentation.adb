with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.Bytes;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.IO.Connections.Testing;
with Flyology.IO.Sockets;

procedure HTTP_Client_Fragmentation is
   package Client renames Flyology.HTTP.Client;
   package Connection_Testing renames Flyology.IO.Connections.Testing;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use type Sockets.Selector_Status;

   CRLF : constant String := Character'Val (13) & Character'Val (10);
   Response_Wire : constant String :=
     "HTTP/1.1 200 Split Fine" & CRLF &
     "X-Split: yes" & CRLF &
     "Transfer-Encoding: chunked" & CRLF &
     "Connection: close" & CRLF & CRLF &
     "1;note=yes" & CRLF & "A" & CRLF &
     "1" & CRLF & "B" & CRLF &
     "0" & CRLF & "X-End: yes" & CRLF & CRLF;

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
      procedure Publish (Value : Sockets.Port);
      entry Wait_Ready (Value : out Sockets.Port);
      procedure Report (Passed : Boolean);
      entry Wait_Done;
      function Passed return Boolean;
   private
      Port_Value : Sockets.Port := Sockets.Any_Port;
      Ready      : Boolean := False;
      Count      : Natural := 0;
      OK         : Boolean := True;
   end Outcome;

   protected body Outcome is
      procedure Publish (Value : Sockets.Port) is
      begin
         Port_Value := Value;
         Ready := True;
      end Publish;

      entry Wait_Ready (Value : out Sockets.Port) when Ready is
      begin
         Value := Port_Value;
      end Wait_Ready;

      procedure Report (Passed : Boolean) is
      begin
         Count := Count + 1;
         OK := OK and Passed;
      end Report;

      entry Wait_Done when Count = 3 is
      begin
         null;
      end Wait_Done;

      function Passed return Boolean is (OK);
   end Outcome;

   Result : Outcome;

   task Raw_Server is
      pragma Task_Info (Flyology.Native_Task);
   end Raw_Server;

   task body Raw_Server is
      Listener : Sockets.Socket_Type;
      Peer     : Sockets.Socket_Type;
      Address  : Sockets.Endpoint;
      Status   : Sockets.Selector_Status;

      procedure Serve is
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
         Sockets.Send_All (Peer, Bytes (Response_Wire), Timeout => 3.0);
         loop
            Sockets.Receive (Peer, Buffer, Last, Timeout => 3.0);
            exit when Last < Buffer'First;
         end loop;
         Sockets.Close_Socket (Peer);
      end Serve;
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint
           (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener);
      Result.Publish (Sockets.Get_Socket_Name (Listener).Port);
      Serve;
      Serve;
      Sockets.Close_Socket (Listener);
      Result.Report (True);
   exception
      when Occurrence : others =>
         Ada.Text_IO.Put_Line
           ("HTTP fragmentation server failed: " &
            Ada.Exceptions.Exception_Information (Occurrence));
         if Sockets.Is_Open (Peer) then
            Sockets.Close_Socket (Peer);
         end if;
         if Sockets.Is_Open (Listener) then
            Sockets.Close_Socket (Listener);
         end if;
         Result.Report (False);
   end Raw_Server;

   procedure Run_Client;

   procedure Run_Client is
      Port    : Sockets.Port;
      HTTP    : aliased Client.Client (Capacity => 1);
      Request : Client.Request;
   begin
      Result.Wait_Ready (Port);
      Client.Configure
        (HTTP,
         Flyology.HTTP.Parse_Origin
           ("http://127.0.0.1:" & Decimal (Natural (Port))));
      Client.Set_Target (Request, "/fragmented");
      Connection_Testing.Set_Receive_Cap (1);
      declare
         Reply : Client.Response :=
           Client.Execute (HTTP, Request, Timeout => 3.0);
      begin
         pragma Assert (Client.Reason_Phrase (Reply) = "Split Fine");
         pragma Assert (Client.Header (Reply, "X-Split") = "yes");
         pragma Assert
           (Flyology.Bytes.To_Byte_String (Client.Read_All (Reply)) = "AB");
         pragma Assert (Client.Trailer (Reply, "X-End") = "yes");
      end;
      pragma Assert
        (Connection_Testing.Receive_Calls = Response_Wire'Length);
      Connection_Testing.Set_Receive_Cap (0);
      Client.Shutdown (HTTP);
      declare
         State : constant Client.Client_Diagnostics :=
           Client.Diagnostics (HTTP);
      begin
         pragma Assert (State.Transports_Created = 1);
         pragma Assert (State.Transports_Closed = 1);
         pragma Assert (State.Active_Exchanges = 0);
         pragma Assert (State.Reusable_Transports = 0);
      end;
      Result.Report (True);
   exception
      when Occurrence : others =>
         Connection_Testing.Set_Receive_Cap (0);
         Ada.Text_IO.Put_Line
           ("HTTP fragmentation client failed: " &
            Ada.Exceptions.Exception_Information (Occurrence));
         Result.Report (False);
   end Run_Client;

begin
   declare
      task Native_Client is
         pragma Task_Info (Flyology.Native_Task);
      end Native_Client;
      task body Native_Client is
      begin
         Run_Client;
      end Native_Client;
   begin
      null;
   end;
   declare
      task Lightweight_Client is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Lightweight_Client;
      task body Lightweight_Client is
      begin
         Run_Client;
      end Lightweight_Client;
   begin
      null;
   end;
   Result.Wait_Done;
   pragma Assert (Result.Passed);
end HTTP_Client_Fragmentation;
