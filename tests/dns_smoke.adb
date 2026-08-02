with Ada.Streams;
with GNAT.Sockets;
with Gnatevl;
with Gnatevl.IO.DNS;
with Gnatevl.Wake_Sources;

procedure DNS_Smoke is
   package DNS renames Gnatevl.IO.DNS;
   package Sockets renames GNAT.Sockets;
   package Streams renames Ada.Streams;

   use type Streams.Stream_Element_Offset;
   use type Streams.Stream_Element;
   use type Sockets.Socket_Type;
   use type Sockets.Selector_Status;

   procedure Run (Model : Gnatevl.Execution_Model) is
      Cancel_Source : aliased Gnatevl.Wake_Sources.Source;

      protected Control is
         procedure Ready (Address : Sockets.Sock_Addr_Type);
         entry Get_Address (Address : out Sockets.Sock_Addr_Type);
         procedure Begin_Client;
         entry Await_Start;
         procedure Saw_Cancel_Query;
         entry Wait_Cancel_Query;
         procedure Missing_Query;
         function Missing_Queries return Natural;
         procedure A_Query;
         function A_Queries return Natural;
         procedure Finished (Passed : Boolean);
         entry Wait_Finished (Passed : out Boolean);
      private
         Is_Ready : Boolean := False;
         Can_Start : Boolean := False;
         Server   : Sockets.Sock_Addr_Type;
         Cancel_Seen : Boolean := False;
         Missing_Count : Natural := 0;
         A_Count : Natural := 0;
         Is_Finished : Boolean := False;
         All_OK : Boolean := False;
      end Control;

      protected body Control is
         procedure Ready (Address : Sockets.Sock_Addr_Type) is
         begin
            Server := Address;
            Is_Ready := True;
         end Ready;
         entry Get_Address (Address : out Sockets.Sock_Addr_Type)
           when Is_Ready
         is
         begin
            Address := Server;
         end Get_Address;
         procedure Begin_Client is
         begin
            Can_Start := True;
         end Begin_Client;
         entry Await_Start when Can_Start is
         begin
            null;
         end Await_Start;
         procedure Saw_Cancel_Query is
         begin
            Cancel_Seen := True;
         end Saw_Cancel_Query;
         entry Wait_Cancel_Query when Cancel_Seen is
         begin
            null;
         end Wait_Cancel_Query;
         procedure Missing_Query is
         begin
            Missing_Count := Missing_Count + 1;
         end Missing_Query;
         function Missing_Queries return Natural is (Missing_Count);
         procedure A_Query is
         begin
            A_Count := A_Count + 1;
         end A_Query;
         function A_Queries return Natural is (A_Count);
         procedure Finished (Passed : Boolean) is
         begin
            All_OK := Passed;
            Is_Finished := True;
         end Finished;
         entry Wait_Finished (Passed : out Boolean) when Is_Finished is
         begin
            Passed := All_OK;
         end Wait_Finished;
      end Control;

      task Fake_Server;

      task body Fake_Server is
         UDP, TCP : Sockets.Socket_Type;
         Peer     : Sockets.Sock_Addr_Type;
         Bound    : Sockets.Sock_Addr_Type;
         Query    : Streams.Stream_Element_Array (1 .. 512);
         Last     : Streams.Stream_Element_Offset;
         Retry_Count : Natural := 0;

         function Query_Name return String is
            Result : String (1 .. 253);
            Length : Natural := 0;
            Position : Streams.Stream_Element_Offset := 13;
            Label_Length : Natural;
         begin
            loop
               Label_Length := Natural (Query (Position));
               Position := Position + 1;
               exit when Label_Length = 0;
               if Length /= 0 then
                  Length := Length + 1;
                  Result (Length) := '.';
               end if;
               for Offset in 0 .. Label_Length - 1 loop
                  Length := Length + 1;
                  Result (Length) := Character'Val
                    (Query (Position + Streams.Stream_Element_Offset (Offset)));
               end loop;
               Position := Position + Streams.Stream_Element_Offset (Label_Length);
            end loop;
            return Result (1 .. Length);
         end Query_Name;

         procedure Put_U16
           (Buffer : in out Streams.Stream_Element_Array;
            Position : in out Streams.Stream_Element_Offset;
            Value : Natural) is
         begin
            Buffer (Position) := Streams.Stream_Element ((Value / 256) mod 256);
            Buffer (Position + 1) := Streams.Stream_Element (Value mod 256);
            Position := Position + 2;
         end Put_U16;

         procedure Put_U32
           (Buffer : in out Streams.Stream_Element_Array;
            Position : in out Streams.Stream_Element_Offset;
            Value : Natural) is
         begin
            Buffer (Position) := Streams.Stream_Element ((Value / 16#1000000#) mod 256);
            Buffer (Position + 1) := Streams.Stream_Element ((Value / 16#10000#) mod 256);
            Buffer (Position + 2) := Streams.Stream_Element ((Value / 256) mod 256);
            Buffer (Position + 3) := Streams.Stream_Element (Value mod 256);
            Position := Position + 4;
         end Put_U32;

         procedure Put_Name
           (Buffer : in out Streams.Stream_Element_Array;
            Position : in out Streams.Stream_Element_Offset;
            Name : String)
         is
            Start : Positive := Name'First;
            Stop  : Natural;
         begin
            while Start <= Name'Last loop
               Stop := Start;
               while Stop <= Name'Last and then Name (Stop) /= '.' loop
                  Stop := Stop + 1;
               end loop;
               Buffer (Position) := Streams.Stream_Element (Stop - Start);
               Position := Position + 1;
               for Index in Start .. Stop - 1 loop
                  Buffer (Position) := Streams.Stream_Element
                    (Character'Pos (Name (Index)));
                  Position := Position + 1;
               end loop;
               Start := Stop + 1;
            end loop;
            Buffer (Position) := 0;
            Position := Position + 1;
         end Put_Name;

         procedure Send_Response
           (Name       : String;
            IPv4       : String := "";
            IPv6       : String := "";
            CNAME      : String := "";
            NXDOMAIN   : Boolean := False;
            Truncated  : Boolean := False;
            Malformed  : Boolean := False;
            Socket     : Sockets.Socket_Type := Sockets.No_Socket)
         is
            Response : Streams.Stream_Element_Array (1 .. 512) := (others => 0);
            Position : Streams.Stream_Element_Offset := 1;
            Question_Last : Streams.Stream_Element_Offset := 13;
            Sent_Last : Streams.Stream_Element_Offset;
            Address : Sockets.Inet_Addr_Type;
            Destination : constant Sockets.Sock_Addr_Type := Peer;
         begin
            while Query (Question_Last) /= 0 loop
               Question_Last := Question_Last
                 + 1 + Streams.Stream_Element_Offset (Query (Question_Last));
            end loop;
            Question_Last := Question_Last + 4;
            Response (1 .. 2) := Query (1 .. 2);
            Position := 3;
            Put_U16
              (Response, Position,
               (if Truncated then 16#8380#
                elsif NXDOMAIN then 16#8183# else 16#8180#));
            Put_U16 (Response, Position, 1);
            Put_U16
              (Response, Position,
               (if Truncated or else NXDOMAIN then 0 else 1));
            Put_U16 (Response, Position, 0);
            Put_U16 (Response, Position, 0);
            Response (Position .. Position + Question_Last - 13) :=
              Query (13 .. Question_Last);
            Position := Position + Question_Last - 12;
            if not Truncated and then not NXDOMAIN then
               if Malformed then
                  Response (Position) := 16#C0#;
                  Response (Position + 1) := Streams.Stream_Element (Position - 1);
                  Position := Position + 2;
               else
                  Response (Position) := 16#C0#;
                  Response (Position + 1) := 12;
                  Position := Position + 2;
               end if;
               if CNAME'Length /= 0 then
                  Put_U16 (Response, Position, 5);
                  Put_U16 (Response, Position, 1);
                  Put_U32 (Response, Position, 60);
                  declare
                     Length_Position : constant Streams.Stream_Element_Offset := Position;
                     Data_Start : Streams.Stream_Element_Offset;
                  begin
                     Position := Position + 2;
                     Data_Start := Position;
                     Put_Name (Response, Position, CNAME);
                     Response (Length_Position) := 0;
                     Response (Length_Position + 1) :=
                       Streams.Stream_Element (Position - Data_Start);
                  end;
               else
                  Put_U16
                    (Response, Position,
                     (if IPv6'Length = 0 then 1 else 28));
                  Put_U16 (Response, Position, 1);
                  Put_U32 (Response, Position, 60);
                  if IPv6'Length = 0 then
                     Put_U16 (Response, Position, 4);
                     Address := Sockets.Inet_Addr (IPv4);
                     for Index in Address.Sin_V4'Range loop
                        Response (Position) :=
                          Streams.Stream_Element (Address.Sin_V4 (Index));
                        Position := Position + 1;
                     end loop;
                  else
                     Put_U16 (Response, Position, 16);
                     Address := Sockets.Inet_Addr (IPv6);
                     for Index in Address.Sin_V6'Range loop
                        Response (Position) :=
                          Streams.Stream_Element (Address.Sin_V6 (Index));
                        Position := Position + 1;
                     end loop;
                  end if;
               end if;
            end if;
            if Socket = Sockets.No_Socket then
               Sockets.Send_Socket
                 (UDP, Response (1 .. Position - 1), Sent_Last, Destination);
            else
               declare
                  Prefix : Streams.Stream_Element_Array (1 .. 2);
               begin
                  Prefix (1) := Streams.Stream_Element
                    ((Natural (Position - 1) / 256) mod 256);
                  Prefix (2) := Streams.Stream_Element
                    (Natural (Position - 1) mod 256);
                  Sockets.Send_Socket (Socket, Prefix, Sent_Last);
                  Sockets.Send_Socket
                    (Socket, Response (1 .. Position - 1), Sent_Last);
               end;
            end if;
            pragma Unreferenced (Name);
         end Send_Response;
      begin
         Sockets.Create_Socket
           (UDP, Sockets.Family_Inet, Sockets.Socket_Datagram);
         Sockets.Bind_Socket
           (UDP, Sockets.Network_Socket_Address
              (Sockets.Loopback_Inet_Addr, Sockets.Any_Port));
         Bound := Sockets.Get_Socket_Name (UDP);
         Sockets.Create_Socket
           (TCP, Sockets.Family_Inet, Sockets.Socket_Stream);
         Sockets.Set_Socket_Option
           (TCP, Sockets.Socket_Level,
            (Name => Sockets.Reuse_Address, Enabled => True));
         Sockets.Bind_Socket (TCP, Bound);
         Sockets.Listen_Socket (TCP);
         Control.Ready (Bound);
         loop
            Sockets.Receive_Socket (UDP, Query, Last, Peer);
            exit when Last = 4
              and then Character'Val (Query (1)) = 's'
              and then Character'Val (Query (2)) = 't'
              and then Character'Val (Query (3)) = 'o'
              and then Character'Val (Query (4)) = 'p';
            declare
               Name : constant String := Query_Name;
            begin
               if Name = "a.test" then
                  Control.A_Query;
                  Send_Response (Name, IPv4 => "192.0.2.1");
               elsif Name = "v6.test" then
                  Send_Response (Name, IPv6 => "2001:db8::5");
               elsif Name = "alias.test" then
                  Send_Response (Name, CNAME => "target.test");
               elsif Name = "target.test" then
                  Send_Response (Name, IPv4 => "203.0.113.7");
               elsif Name = "missing.test" then
                  Control.Missing_Query;
                  Send_Response (Name, NXDOMAIN => True);
               elsif Name = "malformed.test" then
                  Send_Response (Name, IPv4 => "192.0.2.2", Malformed => True);
                  Send_Response (Name, IPv4 => "192.0.2.2");
               elsif Name = "retry.test" then
                  Retry_Count := Retry_Count + 1;
                  if Retry_Count > 1 then
                     Send_Response (Name, IPv4 => "198.51.100.4");
                  end if;
               elsif Name = "tcp.test" then
                  Send_Response (Name, Truncated => True);
                  declare
                     Connection : Sockets.Socket_Type;
                     Address    : Sockets.Sock_Addr_Type;
                     Prefix     : Streams.Stream_Element_Array (1 .. 2);
                     TCP_Last   : Streams.Stream_Element_Offset;
                     Length     : Natural;
                     Status     : Sockets.Selector_Status;
                  begin
                     Sockets.Accept_Socket
                       (TCP, Connection, Address, Timeout => 1.0,
                        Status => Status);
                     if Status = Sockets.Completed then
                        Sockets.Set_Socket_Option
                          (Connection, Sockets.Socket_Level,
                           (Name => Sockets.Receive_Timeout,
                            Timeout => 1.0));
                        Sockets.Receive_Socket (Connection, Prefix, TCP_Last);
                        Length :=
                          Natural (Prefix (1)) * 256 + Natural (Prefix (2));
                        Sockets.Receive_Socket
                          (Connection,
                           Query
                             (1 .. Streams.Stream_Element_Offset (Length)),
                           TCP_Last);
                        Last := Streams.Stream_Element_Offset (Length);
                        Send_Response
                          (Name, IPv4 => "198.51.100.9", Socket => Connection);
                        Sockets.Close_Socket (Connection);
                     end if;
                  end;
               elsif Name = "cancel.test" then
                  Control.Saw_Cancel_Query;
               else
                  Send_Response (Name, NXDOMAIN => True);
               end if;
            end;
         end loop;
         Sockets.Close_Socket (UDP);
         Sockets.Close_Socket (TCP);
      end Fake_Server;

      task Client is
         pragma Task_Info (Model);
      end Client;

      task body Client is
         Server : Sockets.Sock_Addr_Type;
         Servers : DNS.Name_Server_Array (1 .. 1);
         OK : Boolean := True;
         Cancelled : Boolean := False;

         procedure Expect (Name, Address : String);
         procedure Expect (Name, Address : String) is
            Values : constant DNS.Address_Array := DNS.Resolve_Using
              (Name, Servers, DNS.IPv4_Only, Timeout => 1.0,
               Attempts => 2, Retry_Interval => 0.05);
         begin
            OK := OK and then Values'Length = 1
              and then Sockets.Image (Values (Values'First)) = Address;
         end Expect;

         procedure Expect_IPv6 (Name, Address : String) is
            Values : constant DNS.Address_Array := DNS.Resolve_Using
              (Name, Servers, DNS.IPv6_Only, Timeout => 1.0,
               Attempts => 2, Retry_Interval => 0.05);
         begin
            OK := OK and then Values'Length = 1
              and then Sockets.Image (Values (Values'First)) = Address;
         end Expect_IPv6;
      begin
         Control.Await_Start;
         Control.Get_Address (Server);
         Servers (1) := Server;
         DNS.Clear_Cache;
         declare
            Local : constant DNS.Address_Array := DNS.Resolve ("localhost");
            Numeric : constant DNS.Address_Array :=
              DNS.Resolve ("192.0.2.44", DNS.IPv4_Only);
         begin
            OK := OK and then Local'Length = 2
              and then Numeric'Length = 1
              and then Sockets.Image (Numeric (Numeric'First)) = "192.0.2.44";
         end;
         Expect ("a.test", "192.0.2.1");
         Expect ("a.test", "192.0.2.1");
         OK := OK and then Control.A_Queries = 1;
         Expect_IPv6 ("v6.test", "2001:db8::5");
         Expect ("alias.test", "203.0.113.7");
         Expect ("malformed.test", "192.0.2.2");
         Expect ("retry.test", "198.51.100.4");
         Expect ("tcp.test", "198.51.100.9");
         begin
            declare
               Ignored : constant DNS.Address_Array := DNS.Resolve_Using
                 ("missing.test", Servers, DNS.IPv4_Only, Timeout => 1.0);
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         exception
            when DNS.Name_Not_Found => null;
            when others => OK := False;
         end;
         begin
            declare
               Ignored : constant DNS.Address_Array := DNS.Resolve_Using
                 ("missing.test", Servers, DNS.IPv4_Only, Timeout => 1.0);
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         exception
            when DNS.Name_Not_Found => null;
            when others => OK := False;
         end;
         OK := OK and then Control.Missing_Queries = 1;
         begin
            declare
               Ignored : constant DNS.Address_Array := DNS.Resolve_Using
                 ("cancel.test", Servers, DNS.IPv4_Only, Timeout => 5.0,
                  Interrupt_1 => Gnatevl.Wake_Sources.Descriptor (Cancel_Source));
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         exception
            when DNS.Operation_Cancelled => Cancelled := True;
            when others => null;
         end;
         Control.Finished (OK and Cancelled);
      exception
         when others => Control.Finished (False);
      end Client;

      Address : Sockets.Sock_Addr_Type;
      Stopper : Sockets.Socket_Type;
      Stop_Data : constant Streams.Stream_Element_Array :=
        (1 => Character'Pos ('s'), 2 => Character'Pos ('t'),
         3 => Character'Pos ('o'), 4 => Character'Pos ('p'));
      Last : Streams.Stream_Element_Offset;
      Passed : Boolean;
   begin
      Gnatevl.Wake_Sources.Ensure (Cancel_Source);
      Control.Begin_Client;
      Control.Get_Address (Address);
      select
         Control.Wait_Cancel_Query;
      or
         delay 6.0;
      end select;
      --  Signal even after a timed coordination failure so a client that
      --  reached cancellation late can still unwind before scope finalization.
      Gnatevl.Wake_Sources.Signal (Cancel_Source);
      select
         Control.Wait_Finished (Passed);
      or
         delay 6.0;
         Passed := False;
      end select;
      Sockets.Create_Socket
        (Stopper, Sockets.Family_Inet, Sockets.Socket_Datagram);
      Sockets.Send_Socket (Stopper, Stop_Data, Last, Address);
      Sockets.Close_Socket (Stopper);
      pragma Assert (Passed);
   end Run;

begin
   Sockets.Initialize;
   Run (Gnatevl.Native_Thread);
   Run (Gnatevl.Event_Loop_Task);
   Sockets.Finalize;
end DNS_Smoke;
