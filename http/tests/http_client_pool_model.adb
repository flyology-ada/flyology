with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology.Bytes;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Methods;
with Flyology.IO;
with Flyology.IO.Sockets;
with Interfaces.C;

procedure HTTP_Client_Pool_Model is
   package Client renames Flyology.HTTP.Client;
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

   protected Coordination is
      procedure Publish
        (Value : Sockets.Port; Initial_FD_Count : Interfaces.C.int);
      entry Wait_Ready
        (Value : out Sockets.Port; Initial_FD_Count : out Interfaces.C.int);
      procedure Finish (Passed : Boolean);
      entry Wait_Done (Passed : out Boolean);
   private
      Port_Value : Sockets.Port := Sockets.Any_Port;
      Initial_FD_Count_Value : Interfaces.C.int := -1;
      Ready      : Boolean := False;
      Done       : Boolean := False;
      OK         : Boolean := True;
   end Coordination;

   protected body Coordination is
      procedure Publish
        (Value : Sockets.Port; Initial_FD_Count : Interfaces.C.int)
      is
      begin
         Port_Value := Value;
         Initial_FD_Count_Value := Initial_FD_Count;
         Ready := True;
      end Publish;

      entry Wait_Ready
        (Value : out Sockets.Port; Initial_FD_Count : out Interfaces.C.int)
        when Ready
      is
      begin
         Value := Port_Value;
         Initial_FD_Count := Initial_FD_Count_Value;
      end Wait_Ready;

      procedure Finish (Passed : Boolean) is
      begin
         OK := OK and Passed;
         Done := True;
      end Finish;

      entry Wait_Done (Passed : out Boolean) when Done is
      begin
         Passed := OK;
      end Wait_Done;
   end Coordination;

   task Raw_Server;

   task body Raw_Server is
      Listener : Sockets.Socket_Type;
      Peer     : Sockets.Socket_Type;
      Address  : Sockets.Endpoint;
      Status   : Sockets.Selector_Status;
      Initial_FD_Count : constant Interfaces.C.int := Open_FD_Count;

      procedure Accept_Peer is
      begin
         Sockets.Accept_Socket
           (Listener, Peer, Address, Timeout => 3.0, Status => Status);
         pragma Assert (Status = Sockets.Completed);
      end Accept_Peer;

      function Receive_Head return String is
         Buffer : Stream_Element_Array (1 .. 2_048);
         Last   : Stream_Element_Offset;
         Result : Unbounded_String;
      begin
         loop
            Sockets.Receive (Peer, Buffer, Last, Timeout => 3.0);
            pragma Assert (Last >= Buffer'First);
            for Index in Buffer'First .. Last loop
               Append (Result, Character'Val (Buffer (Index)));
            end loop;
            exit when Ada.Strings.Fixed.Index
              (To_String (Result), CRLF & CRLF) /= 0;
         end loop;
         return To_String (Result);
      end Receive_Head;

      procedure Expect (Target : String) is
         Head : constant String := Receive_Head;
      begin
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Head, "GET " & Target & " HTTP/1.1" & CRLF) = 1);
      end Expect;

      procedure Send (Value : String) is
      begin
         Sockets.Send_All (Peer, Bytes (Value), Timeout => 3.0);
      end Send;

      procedure Expect_Close is
         Buffer : Stream_Element_Array (1 .. 1);
         Last   : Stream_Element_Offset;
      begin
         Sockets.Receive (Peer, Buffer, Last, Timeout => 3.0);
         pragma Assert (Last < Buffer'First);
         Sockets.Close_Socket (Peer);
      end Expect_Close;
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint
           (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener);
      Coordination.Publish
        (Sockets.Get_Socket_Name (Listener).Port, Initial_FD_Count);

      Accept_Peer;
      Expect ("/stale-prime");
      Send ("HTTP/1.1 200 OK" & CRLF & "Content-Length: 0" & CRLF & CRLF);
      Sockets.Close_Socket (Peer);

      Accept_Peer;
      Expect ("/retry");
      Send
        ("HTTP/1.1 200 OK" & CRLF & "Content-Length: 2" & CRLF & CRLF &
         "ok");
      Expect ("/rotate");
      Send ("HTTP/1.1 204 No Content" & CRLF & CRLF);
      Expect_Close;

      Accept_Peer;
      Expect ("/post-prime");
      Send ("HTTP/1.1 204 No Content" & CRLF & CRLF);
      Sockets.Close_Socket (Peer);

      Accept_Peer;
      Expect ("/after-post");
      Send
        ("HTTP/1.1 204 No Content" & CRLF &
         "Connection: close" & CRLF & CRLF);
      Expect_Close;

      Accept_Peer;
      Expect ("/prune");
      Send ("HTTP/1.1 204 No Content" & CRLF & CRLF);
      Expect_Close;

      Accept_Peer;
      Expect ("/shutdown");
      Send ("HTTP/1.1 200 OK" & CRLF & "Content-Length: 4" & CRLF & CRLF);
      Expect_Close;

      Accept_Peer;
      Expect ("/http10-one");
      Send
        ("HTTP/1.0 200 OK" & CRLF &
         "Content-Length: 0" & CRLF &
         "Connection: keep-alive" & CRLF & CRLF);
      Expect ("/http10-two");
      Send
        ("HTTP/1.0 204 No Content" & CRLF &
         "Connection: close" & CRLF & CRLF);
      Expect_Close;

      Accept_Peer;
      Expect ("/idle-one");
      Send ("HTTP/1.1 204 No Content" & CRLF & CRLF);
      Expect_Close;
      Accept_Peer;
      Expect ("/idle-two");
      Send
        ("HTTP/1.1 204 No Content" & CRLF &
         "Connection: close" & CRLF & CRLF);
      Expect_Close;

      Accept_Peer;
      Expect ("/age-one");
      Send ("HTTP/1.1 204 No Content" & CRLF & CRLF);
      Expect_Close;
      Accept_Peer;
      Expect ("/age-two");
      Send
        ("HTTP/1.1 204 No Content" & CRLF &
         "Connection: close" & CRLF & CRLF);
      Expect_Close;

      Sockets.Close_Socket (Listener);
      Coordination.Finish (True);
   exception
      when Occurrence : others =>
         Ada.Text_IO.Put_Line
           ("HTTP pool model server failed: " &
            Ada.Exceptions.Exception_Information (Occurrence));
         if Sockets.Is_Open (Peer) then
            Sockets.Close_Socket (Peer);
         end if;
         if Sockets.Is_Open (Listener) then
            Sockets.Close_Socket (Listener);
         end if;
         Coordination.Finish (False);
   end Raw_Server;

   Port       : Sockets.Port;
   Server_OK  : Boolean;
   Baseline   : Interfaces.C.int;
begin
   Coordination.Wait_Ready (Port, Baseline);
   declare
      Origin : constant Flyology.HTTP.Origin := Flyology.HTTP.Parse_Origin
        ("http://127.0.0.1:" & Decimal (Natural (Port)));
      Item   : aliased Client.Client (Capacity => 1);
      Value  : Client.Request;

      procedure Execute_Empty (Target : String) is
      begin
         Client.Set_Target (Value, Target);
         declare
            Reply : constant Client.Response := Client.Execute (Item, Value);
            pragma Unreferenced (Reply);
         begin
            null;
         end;
      end Execute_Empty;
   begin
      Client.Configure
        (Item, Origin,
         (Max_Idle => 1,
          Idle_Timeout => 30.0,
          Max_Connection_Age => 300.0,
          Max_Requests_Per_Connection => 2));

      Execute_Empty ("/stale-prime");
      Client.Set_Target (Value, "/retry");
      declare
         Reply : Client.Response := Client.Execute (Item, Value);
      begin
         pragma Assert
           (Flyology.Bytes.To_Byte_String (Client.Read_All (Reply)) = "ok");
      end;
      Execute_Empty ("/rotate");
      declare
         State : constant Client.Client_Diagnostics :=
           Client.Diagnostics (Item);
      begin
         pragma Assert (State.Transports_Created = 2);
         pragma Assert (State.Transport_Reuses = 2);
         pragma Assert (State.Stale_Retries = 1);
         pragma Assert (State.Transports_Closed = 2);
         pragma Assert (State.Reusable_Transports = 0);
      end;

      Execute_Empty ("/post-prime");
      Client.Set_Target (Value, "/post-no-retry");
      Client.Set_Method (Value, Flyology.HTTP.Methods.POST);
      declare
         Failed : Boolean := False;
      begin
         begin
            declare
               Unexpected : Client.Response := Client.Execute (Item, Value);
               pragma Unreferenced (Unexpected);
            begin
               null;
            end;
         exception
            when Flyology.HTTP.Protocol_Error |
                 Flyology.IO.Device_Error |
                 Flyology.IO.Sockets.Socket_Error =>
               Failed := True;
         end;
         pragma Assert (Failed);
      end;
      declare
         State : constant Client.Client_Diagnostics :=
           Client.Diagnostics (Item);
      begin
         pragma Assert (State.Transports_Created = 3);
         pragma Assert (State.Transport_Reuses = 3);
         pragma Assert (State.Stale_Retries = 1);
         pragma Assert (State.Transports_Closed = 3);
      end;
      Client.Set_Method (Value, Flyology.HTTP.Methods.GET);
      Execute_Empty ("/after-post");

      Execute_Empty ("/prune");
      Client.Prune_Idle (Item);
      declare
         State : constant Client.Client_Diagnostics :=
           Client.Diagnostics (Item);
      begin
         pragma Assert (State.Transports_Created = 5);
         pragma Assert (State.Transports_Closed = 5);
         pragma Assert (State.Reusable_Transports = 0);
      end;

      Client.Set_Target (Value, "/shutdown");
      declare
         Reply : Client.Response := Client.Execute (Item, Value);
         Read_Closed : Boolean := False with Atomic;
         task Reader is
            entry Wait;
         end Reader;
         task body Reader is
         begin
            begin
               declare
                  Payload : constant Flyology.Bytes.Unbounded_Bytes :=
                    Client.Read_All (Reply);
                  pragma Unreferenced (Payload);
               begin
                  null;
               end;
            exception
               when Client.Client_Closed =>
                  Read_Closed := True;
            end;
            accept Wait;
         end Reader;
      begin
         delay 0.02;
         Client.Shutdown (Item, Timeout => 1.0);
         Reader.Wait;
         pragma Assert (Read_Closed);
      end;
      declare
         State : constant Client.Client_Diagnostics :=
           Client.Diagnostics (Item);
      begin
         pragma Assert (State.Active_Exchanges = 0);
         pragma Assert (State.Pending_Transports = 0);
         pragma Assert (State.Reusable_Transports = 0);
         pragma Assert (State.Closing_Transports = 0);
         pragma Assert (State.Transports_Closed = 6);
      end;
   end;

   declare
      Origin : constant Flyology.HTTP.Origin := Flyology.HTTP.Parse_Origin
        ("http://127.0.0.1:" & Decimal (Natural (Port)));
      Item   : aliased Client.Client (Capacity => 1);
      Value  : Client.Request;
   begin
      Client.Configure (Item, Origin);
      Client.Set_Target (Value, "/http10-one");
      declare
         Reply : constant Client.Response := Client.Execute (Item, Value);
         pragma Unreferenced (Reply);
      begin
         null;
      end;
      Client.Set_Target (Value, "/http10-two");
      declare
         Reply : constant Client.Response := Client.Execute (Item, Value);
         pragma Unreferenced (Reply);
      begin
         null;
      end;
      declare
         State : constant Client.Client_Diagnostics :=
           Client.Diagnostics (Item);
      begin
         pragma Assert (State.Transports_Created = 1);
         pragma Assert (State.Transport_Reuses = 1);
         pragma Assert (State.Transports_Closed = 1);
      end;
      Client.Shutdown (Item);
   end;

   declare
      Origin : constant Flyology.HTTP.Origin := Flyology.HTTP.Parse_Origin
        ("http://127.0.0.1:" & Decimal (Natural (Port)));
      Item   : aliased Client.Client (Capacity => 1);
      Value  : Client.Request;
   begin
      Client.Configure
        (Item, Origin,
         (Max_Idle => 1,
          Idle_Timeout => 0.0,
          Max_Connection_Age => -1.0,
          Max_Requests_Per_Connection => 0));
      Client.Set_Target (Value, "/idle-one");
      declare
         Reply : constant Client.Response := Client.Execute (Item, Value);
         pragma Unreferenced (Reply);
      begin
         null;
      end;
      Client.Set_Target (Value, "/idle-two");
      declare
         Reply : constant Client.Response := Client.Execute (Item, Value);
         pragma Unreferenced (Reply);
      begin
         null;
      end;
      declare
         State : constant Client.Client_Diagnostics :=
           Client.Diagnostics (Item);
      begin
         pragma Assert (State.Transports_Created = 2);
         pragma Assert (State.Transport_Reuses = 0);
         pragma Assert (State.Transports_Closed = 2);
      end;
      Client.Shutdown (Item);
   end;

   declare
      Origin : constant Flyology.HTTP.Origin := Flyology.HTTP.Parse_Origin
        ("http://127.0.0.1:" & Decimal (Natural (Port)));
      Item   : aliased Client.Client (Capacity => 1);
      Value  : Client.Request;
   begin
      Client.Configure
        (Item, Origin,
         (Max_Idle => 1,
          Idle_Timeout => 30.0,
          Max_Connection_Age => 0.0,
          Max_Requests_Per_Connection => 0));
      Client.Set_Target (Value, "/age-one");
      declare
         Reply : constant Client.Response := Client.Execute (Item, Value);
         pragma Unreferenced (Reply);
      begin
         null;
      end;
      Client.Set_Target (Value, "/age-two");
      declare
         Reply : constant Client.Response := Client.Execute (Item, Value);
         pragma Unreferenced (Reply);
      begin
         null;
      end;
      declare
         State : constant Client.Client_Diagnostics :=
           Client.Diagnostics (Item);
      begin
         pragma Assert (State.Transports_Created = 2);
         pragma Assert (State.Transport_Reuses = 0);
         pragma Assert (State.Transports_Closed = 2);
      end;
      Client.Shutdown (Item);
   end;

   Coordination.Wait_Done (Server_OK);
   pragma Assert (Server_OK);
   pragma Assert (Open_FD_Count = Baseline);
end HTTP_Client_Pool_Model;
