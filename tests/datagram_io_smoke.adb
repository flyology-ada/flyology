with Ada.Streams;
with Flyology;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.Wake_Sources;

procedure Datagram_IO_Smoke is
   package Sockets renames Flyology.IO.Sockets;
   use Ada.Streams;
   use type Sockets.Address_Family;
   use type Sockets.ECN_Codepoint;
   use type Sockets.IPv4_Octets;
   use type Sockets.IPv6_Octets;
   use type Sockets.Port;

   function Same_Address (Left, Right : Sockets.IP_Address) return Boolean is
   begin
      return
        Left.Family = Right.Family
        and then (case Left.Family is
                    when Sockets.IPv4 => Left.V4 = Right.V4,
                    when Sockets.IPv6 => Left.V6 = Right.V6);
   end Same_Address;

   Client_IPv4 : constant Sockets.IP_Address (Sockets.IPv4) := Sockets.Loopback_IPv4;

   procedure Close_If_Open (Socket : in out Sockets.Socket_Type) is
   begin
      if Sockets.Is_Open (Socket) then
         Sockets.Close_Socket (Socket);
      end if;
   end Close_If_Open;

   procedure Run_Family (Family : Sockets.Address_Family) is
      Server, Client  : Sockets.Socket_Type;
      Server_Bound    : Sockets.Endpoint;
      Client_Bound    : Sockets.Endpoint;
      Destination     : Sockets.Endpoint;
      Selected_Source : Sockets.Endpoint;
      Request         : constant Stream_Element_Array := [16#C0#, 16#01#, 16#02#];
      Response        : constant Stream_Element_Array := [16#40#, 16#03#];

      protected Server_Result is
         procedure Report (Value : Boolean);
         entry Wait;
         function Passed return Boolean;
      private
         Done : Boolean := False;
         OK   : Boolean := False;
      end Server_Result;

      protected body Server_Result is
         procedure Report (Value : Boolean) is
         begin
            OK := Value;
            Done := True;
         end Report;

         entry Wait when Done is
         begin
            null;
         end Wait;

         function Passed return Boolean
         is (OK);
      end Server_Result;
   begin
      Sockets.Create_Socket (Server, Family, Sockets.Socket_Datagram);
      Sockets.Bind_Socket
        (Server,
         Sockets.Network_Endpoint
           ((if Family = Sockets.IPv4 then Sockets.Any_IPv4 else Sockets.Any_IPv6), Sockets.Any_Port));
      Server_Bound := Sockets.Get_Socket_Name (Server);
      Destination :=
        Sockets.Network_Endpoint
          ((if Family = Sockets.IPv4 then Sockets.Loopback_IPv4 else Sockets.Loopback_IPv6),
           Server_Bound.Port);

      Sockets.Create_Socket (Client, Family, Sockets.Socket_Datagram);
      Sockets.Bind_Socket
        (Client,
         Sockets.Network_Endpoint
           ((if Family = Sockets.IPv4 then Sockets.Any_IPv4 else Sockets.Any_IPv6), Sockets.Any_Port));
      Client_Bound := Sockets.Get_Socket_Name (Client);
      Selected_Source :=
        Sockets.Network_Endpoint
          ((if Family = Sockets.IPv4 then Client_IPv4 else Sockets.Loopback_IPv6), Client_Bound.Port);

      declare
         task Server_Task is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Server_Task;

         task body Server_Task is
            Incoming : Stream_Element_Array (Request'Range);
            Last     : Stream_Element_Offset;
            Sent     : Stream_Element_Offset;
            Metadata : Sockets.Datagram_Metadata;
         begin
            Sockets.Receive_Datagram (Server, Incoming, Last, Metadata, Timeout => 1.0);
            Sockets.Send_Datagram
              (Server,
               Response,
               Sent,
               Destination => Metadata.Source,
               Source      => Metadata.Destination,
               Timeout     => 1.0);
            Server_Result.Report
              (Last = Incoming'Last
               and then Incoming = Request
               and then Metadata.Source.Port = Client_Bound.Port
               and then Metadata.Destination.Port = Server_Bound.Port
               and then Metadata.Original_Length = Request'Length
               and then not Metadata.Truncated
               and then Metadata.ECN = Sockets.Not_ECT
               and then Sent = Response'Last);
         exception
            when others =>
               Server_Result.Report (False);
         end Server_Task;
      begin
         declare
            Incoming : Stream_Element_Array (Response'Range);
            Last     : Stream_Element_Offset;
            Sent     : Stream_Element_Offset;
            Metadata : Sockets.Datagram_Metadata;
         begin
            Sockets.Send_Datagram
              (Client, Request, Sent, Destination => Destination, Source => Selected_Source, Timeout => 1.0);
            Sockets.Receive_Datagram (Client, Incoming, Last, Metadata, Timeout => 1.0);
            pragma Assert (Sent = Request'Last);
            pragma Assert (Last = Incoming'Last);
            pragma Assert (Incoming = Response);
            pragma
              Assert
                (Same_Address
                   (Metadata.Source.Address,
                    (if Family = Sockets.IPv4 then Sockets.Loopback_IPv4 else Sockets.Loopback_IPv6)));
            pragma Assert (Metadata.Source.Port = Server_Bound.Port);
            pragma
              Assert
                (Same_Address
                   (Metadata.Destination.Address,
                    (if Family = Sockets.IPv4 then Client_IPv4 else Sockets.Loopback_IPv6)));
            pragma Assert (Metadata.Destination.Port = Client_Bound.Port);
            pragma Assert (Metadata.Original_Length = Response'Length);
            pragma Assert (not Metadata.Truncated);
            pragma Assert (Metadata.ECN = Sockets.Not_ECT);
         end;
         Server_Result.Wait;
         pragma Assert (Server_Result.Passed);
      end;

      declare
         Payload  : constant Stream_Element_Array := [1, 2, 3, 4, 5];
         Incoming : Stream_Element_Array (1 .. 3);
         Last     : Stream_Element_Offset;
         Metadata : Sockets.Datagram_Metadata;
      begin
         Sockets.Send_Datagram (Client, Payload, Last, Destination, Timeout => 1.0);
         pragma Assert (Last = Payload'Last);
         Sockets.Receive_Datagram (Server, Incoming, Last, Metadata, Timeout => 1.0);
         pragma Assert (Last = Incoming'Last);
         pragma Assert (Incoming = [1, 2, 3]);
         pragma Assert (Metadata.Original_Length = Payload'Length);
         pragma Assert (Metadata.Truncated);
         pragma
           Assert
             (Same_Address
                (Metadata.Destination.Address,
                 (if Family = Sockets.IPv4 then Sockets.Loopback_IPv4 else Sockets.Loopback_IPv6)));
      end;

      declare
         Empty    : Stream_Element_Array (1 .. 0);
         Incoming : Stream_Element_Array (1 .. 0);
         Last     : Stream_Element_Offset;
         Metadata : Sockets.Datagram_Metadata;
      begin
         Sockets.Send_Datagram (Client, Empty, Last, Destination, Timeout => 1.0);
         pragma Assert (Last = Empty'First - 1);
         Sockets.Receive_Datagram (Server, Incoming, Last, Metadata, Timeout => 1.0);
         pragma Assert (Last = Incoming'First - 1);
         pragma Assert (Metadata.Original_Length = 0);
         pragma Assert (not Metadata.Truncated);
      end;

      Sockets.Close_Socket (Server);
      Sockets.Close_Socket (Client);
   exception
      when others =>
         Close_If_Open (Server);
         Close_If_Open (Client);
         raise;
   end Run_Family;

   procedure Run_Deadline_And_Interruption is
      Socket                 : Sockets.Socket_Type;
      Wake                   : Flyology.Wake_Sources.Source;
      Data                   : Stream_Element_Array (1 .. 1);
      Last                   : Stream_Element_Offset;
      Metadata               : Sockets.Datagram_Metadata;
      Timed_Out, Interrupted : Boolean := False;
   begin
      Sockets.Create_Socket (Socket, Sockets.IPv4, Sockets.Socket_Datagram);
      Sockets.Bind_Socket (Socket, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
      begin
         Sockets.Receive_Datagram (Socket, Data, Last, Metadata, Timeout => 0.020);
      exception
         when Flyology.IO.Timeout_Error =>
            Timed_Out := True;
      end;
      pragma Assert (Timed_Out);

      Flyology.Wake_Sources.Ensure (Wake);
      Flyology.Wake_Sources.Signal (Wake);
      begin
         Sockets.Receive_Datagram
           (Socket,
            Data,
            Last,
            Metadata,
            Timeout    => 1.0,
            Interrupts => (1 => Flyology.Wake_Sources.Descriptor (Wake)));
      exception
         when Sockets.Operation_Interrupted =>
            Interrupted := True;
      end;
      pragma Assert (Interrupted);
      Sockets.Close_Socket (Socket);
   exception
      when others =>
         Close_If_Open (Socket);
         raise;
   end Run_Deadline_And_Interruption;

   procedure Run_Reuse_Port is
      First, Second, Moved_Second, Collision : Sockets.Socket_Type;
      Bound                                  : Sockets.Endpoint;
      Reuse                                  : constant Sockets.Option_Type :=
        (Name => Sockets.Reuse_Port, Enabled => True);
      Request                                : constant Stream_Element_Array := [16#C3#, 16#01#];
      Response                               : constant Stream_Element_Array := [16#43#, 16#02#];
      First_Received, Second_Received        : Boolean := False;
      Rejected                               : Boolean := False;
      Wake                                   : Flyology.Wake_Sources.Source;

      procedure Exchange_One (Listener : Sockets.Socket_Type) is
         Client     : Sockets.Socket_Type;
         Incoming   : Stream_Element_Array (Response'Range);
         Last, Sent : Stream_Element_Offset;
         Metadata   : Sockets.Datagram_Metadata;
      begin
         Sockets.Create_Socket (Client, Sockets.IPv4, Sockets.Socket_Datagram);
         Sockets.Bind_Socket (Client, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
         Sockets.Send_Datagram (Client, Request, Sent, Bound, Timeout => 1.0);
         pragma Assert (Sent = Request'Last);
         Sockets.Receive_Datagram (Listener, Incoming, Last, Metadata, Timeout => 1.0);
         pragma Assert (Last = Incoming'Last);
         pragma Assert (Incoming = Request);
         Sockets.Send_Datagram
           (Listener,
            Response,
            Sent,
            Destination => Metadata.Source,
            Source      => Metadata.Destination,
            Timeout     => 1.0);
         pragma Assert (Sent = Response'Last);
         Sockets.Receive_Datagram (Client, Incoming, Last, Metadata, Timeout => 1.0);
         pragma Assert (Last = Incoming'Last);
         pragma Assert (Incoming = Response);
         Sockets.Close_Socket (Client);
      exception
         when others =>
            Close_If_Open (Client);
            raise;
      end Exchange_One;
   begin
      Sockets.Create_Socket (First, Sockets.IPv4, Sockets.Socket_Datagram);
      Sockets.Bind_Socket (First, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Bound := Sockets.Get_Socket_Name (First);
      Sockets.Create_Socket (Collision, Sockets.IPv4, Sockets.Socket_Datagram);
      begin
         Sockets.Bind_Socket (Collision, Bound);
      exception
         when Sockets.Socket_Error =>
            Rejected := True;
      end;
      pragma Assert (Rejected);
      Sockets.Close_Socket (Collision);
      Sockets.Close_Socket (First);

      Sockets.Create_Socket (First, Sockets.IPv4, Sockets.Socket_Datagram);
      Sockets.Create_Socket (Second, Sockets.IPv4, Sockets.Socket_Datagram);
      Sockets.Set_Socket_Option (First, Reuse);
      Sockets.Set_Socket_Option (Second, Reuse);
      Sockets.Bind_Socket (First, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Bound := Sockets.Get_Socket_Name (First);
      Sockets.Bind_Socket (Second, Bound);
      Sockets.Move (Second, Moved_Second);

      Flyology.Wake_Sources.Ensure (Wake);
      Flyology.Wake_Sources.Signal (Wake);
      declare
         Incoming    : Stream_Element_Array (Request'Range);
         Last        : Stream_Element_Offset;
         Metadata    : Sockets.Datagram_Metadata;
         Interrupted : Boolean := False;
      begin
         begin
            Sockets.Receive_Datagram
              (Moved_Second,
               Incoming,
               Last,
               Metadata,
               Timeout    => 1.0,
               Interrupts => (1 => Flyology.Wake_Sources.Descriptor (Wake)));
         exception
            when Sockets.Operation_Interrupted =>
               Interrupted := True;
         end;
         pragma Assert (Interrupted);
      end;

      declare
         Client     : Sockets.Socket_Type;
         Incoming   : Stream_Element_Array (Response'Range);
         Last, Sent : Stream_Element_Offset;
         Metadata   : Sockets.Datagram_Metadata;
      begin
         Sockets.Create_Socket (Client, Sockets.IPv4, Sockets.Socket_Datagram);
         Sockets.Bind_Socket (Client, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
         Sockets.Send_Datagram (Client, Request, Sent, Bound, Timeout => 1.0);
         pragma Assert (Sent = Request'Last);
         begin
            Sockets.Receive_Datagram (First, Incoming, Last, Metadata, Timeout => 0.002);
            First_Received := True;
         exception
            when Flyology.IO.Timeout_Error =>
               Sockets.Receive_Datagram (Moved_Second, Incoming, Last, Metadata, Timeout => 1.0);
               Second_Received := True;
         end;
         pragma Assert (Last = Incoming'Last);
         pragma Assert (Incoming = Request);
         if First_Received then
            Sockets.Send_Datagram
              (First,
               Response,
               Sent,
               Destination => Metadata.Source,
               Source      => Metadata.Destination,
               Timeout     => 1.0);
         else
            Sockets.Send_Datagram
              (Moved_Second,
               Response,
               Sent,
               Destination => Metadata.Source,
               Source      => Metadata.Destination,
               Timeout     => 1.0);
         end if;
         pragma Assert (Sent = Response'Last);
         Sockets.Receive_Datagram (Client, Incoming, Last, Metadata, Timeout => 1.0);
         pragma Assert (Last = Incoming'Last);
         pragma Assert (Incoming = Response);
         Sockets.Close_Socket (Client);
      exception
         when others =>
            Close_If_Open (Client);
            raise;
      end;

      if First_Received then
         Sockets.Close_Socket (First);
         Exchange_One (Moved_Second);
         Second_Received := True;
      else
         Sockets.Close_Socket (Moved_Second);
         Exchange_One (First);
         First_Received := True;
      end if;
      pragma Assert (First_Received and then Second_Received);

      Sockets.Close_Socket (Moved_Second);
      Sockets.Close_Socket (First);
   exception
      when others =>
         Close_If_Open (Collision);
         Close_If_Open (Moved_Second);
         Close_If_Open (Second);
         Close_If_Open (First);
         raise;
   end Run_Reuse_Port;
begin
   Run_Family (Sockets.IPv4);
   Run_Family (Sockets.IPv6);
   Run_Deadline_And_Interruption;
   Run_Reuse_Port;
end Datagram_IO_Smoke;
