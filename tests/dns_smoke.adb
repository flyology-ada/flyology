with Ada.Directories;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.IO.DNS;
with Flyology.IO.DNS.Testing;
with Flyology.IO.Files;
with Flyology.IO.Sockets;
with Flyology.Wake_Sources;

procedure DNS_Smoke is
   package DNS renames Flyology.IO.DNS;
   package Sockets renames Flyology.IO.Sockets;
   package Streams renames Ada.Streams;
   package Unbounded renames Ada.Strings.Unbounded;

   use type Streams.Stream_Element_Offset;
   use type Streams.Stream_Element;
   use type Sockets.Selector_Status;
   use type Flyology.IO.Files.File_Descriptor;

   function Run (Model : Flyology.Execution_Model) return Boolean is
      Cancel_Source : aliased Flyology.Wake_Sources.Source;
      --  Functional loopback exchanges must tolerate hosted-runner stalls.
      --  dns_resilience_smoke owns the deliberately narrow deadline checks.
      Operation_Timeout : constant Duration := 2.0;
      Attempt_Interval  : constant Duration := 0.5;
      Search_Name   : constant String (1 .. 60) := (others => 'r');
      Bare_Name     : constant String (1 .. 60) := (others => 'b');
      Search_Label  : constant String (1 .. 62) := (others => 's');
      Long_Search   : constant String :=
        Search_Label & "." & Search_Label & "."
        & Search_Label & "." & Search_Label;

      protected Control is
         procedure Ready (Address : Sockets.Endpoint);
         entry Get_Address (Address : out Sockets.Endpoint);
         procedure Primary_Failed;
         procedure Secondary_Ready (Address : Sockets.Endpoint);
         entry Get_Secondary (Address : out Sockets.Endpoint);
         procedure Secondary_Failed;
         procedure Begin_Client;
         entry Await_Start;
         procedure Saw_Cancel_Query;
         entry Wait_Cancel_Or_Finished
           (Client_Finished : out Boolean;
            Passed          : out Boolean);
         procedure Missing_Query;
         function Missing_Queries return Natural;
         procedure A_Query;
         function A_Queries return Natural;
         procedure Alias_Query;
         function Alias_Queries return Natural;
         procedure Chain_Query;
         function Chain_Queries return Natural;
         procedure TCP_Truncated_Query;
         function TCP_Truncated_Queries return Natural;
         procedure Recursive_Failure_Query;
         function Recursive_Failure_Queries return Natural;
         procedure Finished (Passed : Boolean);
         entry Wait_Finished (Passed : out Boolean);
      private
         Is_Ready : Boolean := False;
         Primary_Setup_Failed : Boolean := False;
         Can_Start : Boolean := False;
         Server   : Sockets.Endpoint;
         Secondary_Is_Ready : Boolean := False;
         Secondary_Setup_Failed : Boolean := False;
         Secondary : Sockets.Endpoint;
         Cancel_Seen : Boolean := False;
         Missing_Count : Natural := 0;
         A_Count : Natural := 0;
         Alias_Count : Natural := 0;
         Chain_Count : Natural := 0;
         TCP_Truncated_Count : Natural := 0;
         Recursive_Failure_Count : Natural := 0;
         Is_Finished : Boolean := False;
         All_OK : Boolean := False;
      end Control;

      function Config_Path
        (Server : Sockets.Endpoint;
         Suffix : String := "") return String is
      begin
         return "/tmp/flyology-dns-smoke-"
           & Ada.Strings.Fixed.Trim
             (Sockets.Port'Image (Server.Port), Ada.Strings.Both)
           & Suffix & ".conf";
      end Config_Path;

      procedure Close_Quietly (Socket : in out Sockets.Socket_Type) is
      begin
         if Sockets.Is_Open (Socket) then
            Sockets.Close_Socket (Socket);
         end if;
      exception
         when others => null;
      end Close_Quietly;

      procedure Write_Config
        (Server : Sockets.Endpoint;
         Search : String := "";
         Suffix : String := "")
      is
         File : Flyology.IO.Files.File_Descriptor :=
           Flyology.IO.Files.Invalid_File;
         Search_Directive : constant String :=
           (if Search'Length = 0 then ""
            else "search " & Search & ASCII.LF);
         Text : constant String :=
           ASCII.HT & "nameserver" & ASCII.HT
           & Sockets.Image (Server) & ASCII.HT & ASCII.LF
           & Search_Directive
           & ASCII.HT & "options" & ASCII.HT
           & "attempts:1 timeout:1" & ASCII.HT & ASCII.LF;
         Data : Streams.Stream_Element_Array
           (1 .. Streams.Stream_Element_Offset (Text'Length));
         Last : Streams.Stream_Element_Offset;
      begin
         for Index in Text'Range loop
            Data
              (Streams.Stream_Element_Offset (Index - Text'First + 1)) :=
                Character'Pos (Text (Index));
         end loop;
         File := Flyology.IO.Files.Open
           (Config_Path (Server, Suffix), Flyology.IO.Files.Write_Only,
            Create => True, Truncate => True);
         Flyology.IO.Files.Write_At (File, 0, Data, Last);
         Flyology.IO.Files.Close (File);
         pragma Assert (Last = Data'Last);
      exception
         when others =>
            if File /= Flyology.IO.Files.Invalid_File then
               Flyology.IO.Files.Close (File);
            end if;
            raise;
      end Write_Config;

      protected body Control is
         procedure Ready (Address : Sockets.Endpoint) is
         begin
            Server := Address;
            Is_Ready := True;
         end Ready;
         entry Get_Address (Address : out Sockets.Endpoint)
           when Is_Ready or else Primary_Setup_Failed
         is
         begin
            if Primary_Setup_Failed then
               raise Program_Error with "primary DNS server setup failed";
            end if;
            Address := Server;
         end Get_Address;
         procedure Primary_Failed is
         begin
            Primary_Setup_Failed := True;
         end Primary_Failed;
         procedure Secondary_Ready (Address : Sockets.Endpoint) is
         begin
            Secondary := Address;
            Secondary_Is_Ready := True;
         end Secondary_Ready;
         entry Get_Secondary (Address : out Sockets.Endpoint)
           when Secondary_Is_Ready or else Secondary_Setup_Failed
         is
         begin
            if Secondary_Setup_Failed then
               raise Program_Error with "secondary DNS server setup failed";
            end if;
            Address := Secondary;
         end Get_Secondary;
         procedure Secondary_Failed is
         begin
            Secondary_Setup_Failed := True;
         end Secondary_Failed;
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
         entry Wait_Cancel_Or_Finished
           (Client_Finished : out Boolean;
            Passed          : out Boolean)
           when Cancel_Seen or else Is_Finished
         is
         begin
            Client_Finished := Is_Finished;
            Passed := All_OK;
         end Wait_Cancel_Or_Finished;
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
         procedure Alias_Query is
         begin
            Alias_Count := Alias_Count + 1;
         end Alias_Query;
         function Alias_Queries return Natural is (Alias_Count);
         procedure Chain_Query is
         begin
            Chain_Count := Chain_Count + 1;
         end Chain_Query;
         function Chain_Queries return Natural is (Chain_Count);
         procedure TCP_Truncated_Query is
         begin
            TCP_Truncated_Count := TCP_Truncated_Count + 1;
         end TCP_Truncated_Query;
         function TCP_Truncated_Queries return Natural is
           (TCP_Truncated_Count);
         procedure Recursive_Failure_Query is
         begin
            Recursive_Failure_Count := Recursive_Failure_Count + 1;
         end Recursive_Failure_Query;
         function Recursive_Failure_Queries return Natural is
           (Recursive_Failure_Count);
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
         Collision : Sockets.Socket_Type;
         Peer     : Sockets.Endpoint;
         Bound    : Sockets.Endpoint;
         Query    : Streams.Stream_Element_Array (1 .. 512);
         Last     : Streams.Stream_Element_Offset;
         Retry_Count : Natural := 0;

         procedure Open_Server_Sockets is
         begin
            --  UDP and TCP have independent ephemeral-port allocation. Bind
            --  TCP first so its selected port is known to be free in the
            --  stream namespace, then retry if UDP already owns that number.
            --  The first synthetic conflict exercises this recovery instead
            --  of allowing a setup exception to become a test hang.
            for Attempt in 1 .. 16 loop
               begin
                  Sockets.Create_Socket
                    (TCP, Sockets.IPv4, Sockets.Socket_Stream);
                  Sockets.Set_Socket_Option
                    (TCP, Sockets.Socket_Level,
                     (Name => Sockets.Reuse_Address, Enabled => True));
                  Sockets.Bind_Socket
                    (TCP, Sockets.Network_Endpoint
                       (Sockets.Loopback_IPv4, Sockets.Any_Port));
                  Bound := Sockets.Get_Socket_Name (TCP);
                  Sockets.Listen_Socket (TCP);

                  if Attempt = 1 then
                     Sockets.Create_Socket
                       (Collision, Sockets.IPv4, Sockets.Socket_Datagram);
                     Sockets.Bind_Socket (Collision, Bound);
                  end if;
                  Sockets.Create_Socket
                    (UDP, Sockets.IPv4, Sockets.Socket_Datagram);
                  Sockets.Bind_Socket (UDP, Bound);
                  return;
               exception
                  when Sockets.Socket_Error =>
                     Close_Quietly (Collision);
                     Close_Quietly (UDP);
                     Close_Quietly (TCP);
                     if Attempt = 16 then
                        raise;
                     end if;
               end;
            end loop;
         end Open_Server_Sockets;

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

         function Query_Type return Natural is
            Position : Streams.Stream_Element_Offset := 13;
         begin
            while Query (Position) /= 0 loop
               Position := Position
                 + 1 + Streams.Stream_Element_Offset (Query (Position));
            end loop;
            Position := Position + 1;
            return Natural (Query (Position)) * 256
              + Natural (Query (Position + 1));
         end Query_Type;

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
            TTL        : Natural := 60;
            Socket     : access Sockets.Socket_Type := null)
         is
            Response : Streams.Stream_Element_Array (1 .. 512) := (others => 0);
            Position : Streams.Stream_Element_Offset := 1;
            Question_Last : Streams.Stream_Element_Offset := 13;
            Sent_Last : Streams.Stream_Element_Offset;
            Address : Sockets.IP_Address;
            Destination : constant Sockets.Endpoint := Peer;
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
                  Put_U32 (Response, Position, TTL);
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
                  Put_U32 (Response, Position, TTL);
                  if IPv6'Length = 0 then
                     Put_U16 (Response, Position, 4);
                     Address := Sockets.Parse_IP_Address (IPv4);
                     for Index in Address.V4'Range loop
                        Response (Position) :=
                          Streams.Stream_Element (Address.V4 (Index));
                        Position := Position + 1;
                     end loop;
                  else
                     Put_U16 (Response, Position, 16);
                     Address := Sockets.Parse_IP_Address (IPv6);
                     for Index in Address.V6'Range loop
                        Response (Position) :=
                          Streams.Stream_Element (Address.V6 (Index));
                        Position := Position + 1;
                     end loop;
                  end if;
               end if;
            end if;
            if Socket = null then
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
                  Sockets.Send_Socket (Socket.all, Prefix, Sent_Last);
                  Sockets.Send_Socket
                    (Socket.all, Response (1 .. Position - 1), Sent_Last);
               end;
            end if;
            pragma Unreferenced (Name);
         end Send_Response;
      begin
         Open_Server_Sockets;
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
                  Control.Alias_Query;
                  Send_Response (Name, CNAME => "target.test");
               elsif Name = "target.test" then
                  Send_Response (Name, IPv4 => "203.0.113.7");
               elsif Name = "chain-a.test" then
                  Control.Chain_Query;
                  Send_Response
                    (Name, CNAME => "chain-b.test", TTL => 5);
               elsif Name = "chain-b.test" then
                  Send_Response
                    (Name, CNAME => "chain-c.test", TTL => 1);
               elsif Name = "chain-c.test" then
                  Send_Response
                    (Name, IPv4 => "203.0.113.88", TTL => 100);
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
                     Connection : aliased Sockets.Socket_Type;
                     Address    : Sockets.Endpoint;
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
                          (Name, IPv4 => "198.51.100.9",
                           Socket => Connection'Access);
                        Sockets.Close_Socket (Connection);
                     end if;
                  end;
               elsif Name = "tcp-silent.test" then
                  Send_Response (Name, Truncated => True);
                  declare
                     Connection : aliased Sockets.Socket_Type;
                     Address    : Sockets.Endpoint;
                     Status     : Sockets.Selector_Status;
                  begin
                     Sockets.Accept_Socket
                       (TCP, Connection, Address, Timeout => 1.0,
                        Status => Status);
                     if Status = Sockets.Completed then
                        delay 0.15;
                        Sockets.Close_Socket (Connection);
                     end if;
                  end;
               elsif Name = "tcp-truncated.test" then
                  Control.TCP_Truncated_Query;
                  Send_Response (Name, Truncated => True);
                  declare
                     Connection : aliased Sockets.Socket_Type;
                     Address    : Sockets.Endpoint;
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
                          (Name, Truncated => True,
                           Socket => Connection'Access);
                        Sockets.Close_Socket (Connection);
                     end if;
                  end;
               elsif Name = "recursive-failure.test" then
                  Control.Recursive_Failure_Query;
                  Send_Response (Name, CNAME => "recursive-target.test");
               elsif Name = "recursive-target.test" then
                  Control.Recursive_Failure_Query;
                  Send_Response
                    (Name, IPv4 => "192.0.2.70", Malformed => True);
               elsif Name = "dual.test" then
                  if Query_Type = 1 then
                     Send_Response (Name, IPv4 => "192.0.2.66");
                  end if;
               elsif Name = "dual-malformed.test" then
                  if Query_Type = 28 then
                     Send_Response
                       (Name, IPv6 => "2001:db8::bad", Malformed => True);
                  else
                     Send_Response (Name, IPv4 => "192.0.2.67");
                  end if;
               elsif Name = "order.test" then
                  Send_Response (Name, IPv4 => "192.0.2.20");
               elsif Name = "config.test" then
                  Send_Response (Name, IPv4 => "192.0.2.53");
               elsif Name = Search_Name & ".valid.test" then
                  Send_Response (Name, IPv4 => "192.0.2.54");
               elsif Name = Bare_Name then
                  Send_Response (Name, IPv4 => "192.0.2.55");
               elsif Name = "entropy.test" then
                  if Query (1) = 16#12# and then Query (2) = 16#34# then
                     Send_Response (Name, IPv4 => "192.0.2.99");
                  else
                     Send_Response (Name, NXDOMAIN => True);
                  end if;
               elsif Name = "cancel.test" then
                  Control.Saw_Cancel_Query;
               else
                  Send_Response (Name, NXDOMAIN => True);
               end if;
            end;
         end loop;
         Sockets.Close_Socket (UDP);
         Sockets.Close_Socket (TCP);
      exception
         when Error : others =>
            Close_Quietly (Collision);
            Close_Quietly (UDP);
            Close_Quietly (TCP);
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "primary DNS test server failed: "
               & Ada.Exceptions.Exception_Information (Error));
            Control.Primary_Failed;
      end Fake_Server;

      --  A second endpoint gives cache-order and failover tests independent
      --  answers. It intentionally has no TCP listener: the primary's silent
      --  TCP fallback must expire within its attempt budget before this
      --  healthy UDP endpoint is tried.
      task Secondary_Server;

      task body Secondary_Server is
         UDP      : Sockets.Socket_Type;
         Peer     : Sockets.Endpoint;
         Bound    : Sockets.Endpoint;
         Query    : Streams.Stream_Element_Array (1 .. 512);
         Response : Streams.Stream_Element_Array (1 .. 512);
         Last     : Streams.Stream_Element_Offset;

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
                    (Query
                       (Position
                        + Streams.Stream_Element_Offset (Offset)));
               end loop;
               Position :=
                 Position + Streams.Stream_Element_Offset (Label_Length);
            end loop;
            return Result (1 .. Length);
         end Query_Name;

         procedure Put_U16
           (Position : in out Streams.Stream_Element_Offset;
            Value : Natural) is
         begin
            Response (Position) :=
              Streams.Stream_Element ((Value / 256) mod 256);
            Response (Position + 1) := Streams.Stream_Element (Value mod 256);
            Position := Position + 2;
         end Put_U16;

         procedure Put_U32
           (Position : in out Streams.Stream_Element_Offset;
            Value : Natural) is
         begin
            Response (Position) :=
              Streams.Stream_Element ((Value / 16#1000000#) mod 256);
            Response (Position + 1) :=
              Streams.Stream_Element ((Value / 16#10000#) mod 256);
            Response (Position + 2) :=
              Streams.Stream_Element ((Value / 256) mod 256);
            Response (Position + 3) := Streams.Stream_Element (Value mod 256);
            Position := Position + 4;
         end Put_U32;

         procedure Send_A (Address_Image : String) is
            Position : Streams.Stream_Element_Offset := 3;
            Question_Last : Streams.Stream_Element_Offset := 13;
            Sent_Last : Streams.Stream_Element_Offset;
            Address : constant Sockets.IP_Address :=
              Sockets.Parse_IP_Address (Address_Image);
         begin
            Response := (others => 0);
            while Query (Question_Last) /= 0 loop
               Question_Last := Question_Last
                 + 1 + Streams.Stream_Element_Offset (Query (Question_Last));
            end loop;
            Question_Last := Question_Last + 4;
            Response (1 .. 2) := Query (1 .. 2);
            Put_U16 (Position, 16#8180#);
            Put_U16 (Position, 1);
            Put_U16 (Position, 1);
            Put_U16 (Position, 0);
            Put_U16 (Position, 0);
            Response (Position .. Position + Question_Last - 13) :=
              Query (13 .. Question_Last);
            Position := Position + Question_Last - 12;
            Response (Position) := 16#C0#;
            Response (Position + 1) := 12;
            Position := Position + 2;
            Put_U16 (Position, 1);
            Put_U16 (Position, 1);
            Put_U32 (Position, 60);
            Put_U16 (Position, 4);
            for Index in Address.V4'Range loop
               Response (Position) :=
                 Streams.Stream_Element (Address.V4 (Index));
               Position := Position + 1;
            end loop;
            Sockets.Send_Socket
              (UDP, Response (1 .. Position - 1), Sent_Last, Peer);
         end Send_A;
      begin
         Sockets.Create_Socket
           (UDP, Sockets.IPv4, Sockets.Socket_Datagram);
         Sockets.Bind_Socket
           (UDP, Sockets.Network_Endpoint
              (Sockets.Loopback_IPv4, Sockets.Any_Port));
         Bound := Sockets.Get_Socket_Name (UDP);
         Control.Secondary_Ready (Bound);
         loop
            Sockets.Receive_Socket (UDP, Query, Last, Peer);
            exit when Last = 4
              and then Character'Val (Query (1)) = 's'
              and then Character'Val (Query (2)) = 't'
              and then Character'Val (Query (3)) = 'o'
              and then Character'Val (Query (4)) = 'p';
            if Query_Name = "order.test" then
               Send_A ("192.0.2.10");
            else
               Send_A ("198.51.100.77");
            end if;
         end loop;
         Sockets.Close_Socket (UDP);
      exception
         when Error : others =>
            Close_Quietly (UDP);
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "secondary DNS test server failed: "
               & Ada.Exceptions.Exception_Information (Error));
            Control.Secondary_Failed;
      end Secondary_Server;

      task Client is
         pragma Task_Info (Model);
      end Client;

      task body Client is
         Server : Sockets.Endpoint;
         Secondary : Sockets.Endpoint;
         Servers : DNS.Name_Server_Array (1 .. 1);
         OK : Boolean := True;
         Cancelled : Boolean := False;
         Stage : Unbounded.Unbounded_String :=
           Unbounded.To_Unbounded_String ("startup");

         procedure Set_Stage (Value : String) is
         begin
            Stage := Unbounded.To_Unbounded_String (Value);
         end Set_Stage;

         procedure Expect (Name, Address : String);
         procedure Expect (Name, Address : String) is
         begin
            Set_Stage ("IPv4 " & Name);
            declare
               Values : constant DNS.Address_Array := DNS.Resolve_Using
                 (Name, Servers, DNS.IPv4_Only,
                  Timeout => Operation_Timeout,
                  Attempts => 2, Retry_Interval => Attempt_Interval);
            begin
               OK := OK and then Values'Length = 1
                 and then Sockets.Image (Values (Values'First)) = Address;
            end;
         end Expect;

         procedure Expect_IPv6 (Name, Address : String) is
         begin
            Set_Stage ("IPv6 " & Name);
            declare
               Values : constant DNS.Address_Array := DNS.Resolve_Using
                 (Name, Servers, DNS.IPv6_Only,
                  Timeout => Operation_Timeout,
                  Attempts => 2, Retry_Interval => Attempt_Interval);
            begin
               OK := OK and then Values'Length = 1
                 and then Sockets.Image (Values (Values'First)) = Address;
            end;
         end Expect_IPv6;

         procedure Expect_Malformed (Name : String) is
            Raised : Boolean := False;
         begin
            Set_Stage ("malformed " & Name);
            begin
               declare
                  Ignored : constant DNS.Address_Array := DNS.Resolve_Using
                    (Name, Servers, DNS.IPv4_Only,
                     Timeout => Operation_Timeout,
                     Attempts => 1, Retry_Interval => Attempt_Interval);
                  pragma Unreferenced (Ignored);
               begin
                  null;
               end;
            exception
               when DNS.Malformed_Response => Raised := True;
               when others => null;
            end;
            OK := OK and Raised;
         end Expect_Malformed;
      begin
         Control.Await_Start;
         Control.Get_Address (Server);
         Control.Get_Secondary (Secondary);
         Servers (1) := Server;
         DNS.Clear_Cache;
         Set_Stage ("local and numeric bypass");
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
         Expect ("target.test", "203.0.113.7");
         Expect ("alias.test", "203.0.113.7");
         delay 1.1;
         Expect ("alias.test", "203.0.113.7");
         OK := OK and then Control.Alias_Queries = 1;
         Expect ("chain-a.test", "203.0.113.88");
         delay 1.1;
         Expect ("chain-a.test", "203.0.113.88");
         OK := OK and then Control.Chain_Queries = 2;
         Expect ("malformed.test", "192.0.2.2");
         Expect ("retry.test", "198.51.100.4");
         Expect ("tcp.test", "198.51.100.9");
         DNS.Testing.Reset_Receive_Waits;
         Expect_Malformed ("tcp-truncated.test");
         OK := OK
           and then Control.TCP_Truncated_Queries = 1
           and then DNS.Testing.Post_Close_Receive_Waits = 0;
         DNS.Testing.Reset_Receive_Waits;
         Expect_Malformed ("recursive-failure.test");
         OK := OK
           and then Control.Recursive_Failure_Queries = 2
           and then DNS.Testing.Post_Close_Receive_Waits = 0;
         Set_Stage ("server ordering");
         declare
            Ordered : constant DNS.Name_Server_Array := [Server, Secondary];
            Reversed : constant DNS.Name_Server_Array := [Secondary, Server];
            First : constant DNS.Address_Array := DNS.Resolve_Using
              ("order.test", Ordered, DNS.IPv4_Only,
               Timeout => Operation_Timeout,
               Attempts => 1, Retry_Interval => Attempt_Interval);
            Second : constant DNS.Address_Array := DNS.Resolve_Using
              ("order.test", Reversed, DNS.IPv4_Only,
               Timeout => Operation_Timeout,
               Attempts => 1, Retry_Interval => Attempt_Interval);
         begin
            OK := OK
              and then Sockets.Image (First (First'First)) = "192.0.2.20"
              and then Sockets.Image (Second (Second'First)) = "192.0.2.10";
         end;
         Set_Stage ("TCP failover");
         declare
            Failover : constant DNS.Name_Server_Array := [Server, Secondary];
            Values : constant DNS.Address_Array := DNS.Resolve_Using
              ("tcp-silent.test", Failover, DNS.IPv4_Only,
               Timeout => Operation_Timeout,
               Attempts => 1, Retry_Interval => Attempt_Interval);
         begin
            OK := OK and then Values'Length = 1
              and then Sockets.Image (Values (Values'First)) =
                "198.51.100.77";
         end;
         Set_Stage ("dual-family fallback");
         declare
            Values : constant DNS.Address_Array := DNS.Resolve_Using
              ("dual.test", Servers, DNS.Any_Family,
               Timeout => Operation_Timeout,
               Attempts => 1, Retry_Interval => Attempt_Interval);
         begin
            OK := OK and then Values'Length = 1
              and then Sockets.Image (Values (Values'First)) = "192.0.2.66";
         end;
         Set_Stage ("dual-family malformed fallback");
         declare
            Values : constant DNS.Address_Array := DNS.Resolve_Using
              ("dual-malformed.test", Servers, DNS.Any_Family,
               Timeout => Operation_Timeout,
               Attempts => 1, Retry_Interval => Attempt_Interval);
         begin
            OK := OK and then Values'Length = 1
              and then Sockets.Image (Values (Values'First)) = "192.0.2.67";
         end;
         Set_Stage ("resolver configuration");
         declare
            Values : constant DNS.Address_Array := DNS.Resolve
              ("config.test", DNS.IPv4_Only, Timeout => Operation_Timeout,
               Configuration_Path => Config_Path (Server));
         begin
            OK := OK and then Values'Length = 1
              and then Sockets.Image (Values (Values'First)) = "192.0.2.53";
         end;
         Set_Stage ("remaining search candidate");
         declare
            Values : constant DNS.Address_Array := DNS.Resolve
              (Search_Name, DNS.IPv4_Only, Timeout => Operation_Timeout,
               Configuration_Path => Config_Path (Server, "-remaining"));
         begin
            OK := OK and then Values'Length = 1
              and then Sockets.Image (Values (Values'First)) = "192.0.2.54";
         end;
         Set_Stage ("bare-name fallback");
         declare
            Values : constant DNS.Address_Array := DNS.Resolve
              (Bare_Name, DNS.IPv4_Only, Timeout => Operation_Timeout,
               Configuration_Path => Config_Path (Server, "-bare"));
         begin
            OK := OK and then Values'Length = 1
              and then Sockets.Image (Values (Values'First)) = "192.0.2.55";
         end;
         DNS.Testing.Use_Deterministic_Transaction_IDs (16#1234#);
         Set_Stage ("deterministic transaction ID");
         begin
            Expect ("entropy.test", "192.0.2.99");
            DNS.Testing.Use_OS_Transaction_IDs;
         exception
            when others =>
               DNS.Testing.Use_OS_Transaction_IDs;
               raise;
         end;
         begin
            Set_Stage ("negative cache fill");
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
            Set_Stage ("negative cache hit");
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
         Set_Stage ("cancellation");
         begin
            declare
               Ignored : constant DNS.Address_Array := DNS.Resolve_Using
                 ("cancel.test", Servers, DNS.IPv4_Only, Timeout => 5.0,
                  Interrupts =>
                    (1 => Flyology.Wake_Sources.Descriptor (Cancel_Source)));
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
         when Error : others =>
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "DNS " & Flyology.Execution_Model'Image (Model)
               & " client failed at " & Unbounded.To_String (Stage) & ": "
               & Ada.Exceptions.Exception_Information (Error));
            Control.Finished (False);
      end Client;

      Address : Sockets.Endpoint;
      Secondary_Address : Sockets.Endpoint;
      Stopper : Sockets.Socket_Type;
      Stop_Data : constant Streams.Stream_Element_Array :=
        (1 => Character'Pos ('s'), 2 => Character'Pos ('t'),
         3 => Character'Pos ('o'), 4 => Character'Pos ('p'));
      Last : Streams.Stream_Element_Offset;
      Passed : Boolean := False;
      Client_Finished : Boolean := False;
   begin
      Flyology.Wake_Sources.Ensure (Cancel_Source);
      Control.Get_Address (Address);
      Control.Get_Secondary (Secondary_Address);
      Write_Config (Address);
      Write_Config
        (Address, Long_Search & " valid.test", Suffix => "-remaining");
      Write_Config (Address, Long_Search, Suffix => "-bare");
      Control.Begin_Client;
      select
         Control.Wait_Cancel_Or_Finished
           (Client_Finished, Passed);
      or
         delay 6.0;
      end select;
      --  Signal even after a timed coordination failure so a client that
      --  reached cancellation late can still unwind before scope finalization.
      Flyology.Wake_Sources.Signal (Cancel_Source);
      if not Client_Finished then
         select
            Control.Wait_Finished (Passed);
         or
            delay 6.0;
            Passed := False;
         end select;
      end if;
      Sockets.Create_Socket
        (Stopper, Sockets.IPv4, Sockets.Socket_Datagram);
      Sockets.Send_Socket (Stopper, Stop_Data, Last, Address);
      Sockets.Send_Socket (Stopper, Stop_Data, Last, Secondary_Address);
      Sockets.Close_Socket (Stopper);
      if Ada.Directories.Exists (Config_Path (Address)) then
         Ada.Directories.Delete_File (Config_Path (Address));
      end if;
      if Ada.Directories.Exists (Config_Path (Address, "-remaining")) then
         Ada.Directories.Delete_File (Config_Path (Address, "-remaining"));
      end if;
      if Ada.Directories.Exists (Config_Path (Address, "-bare")) then
         Ada.Directories.Delete_File (Config_Path (Address, "-bare"));
      end if;
      return Passed;
   end Run;

begin
   declare
      Native_Passed : constant Boolean := Run (Flyology.Native_Task);
      Lightweight_Passed : constant Boolean :=
        Run (Flyology.Lightweight_Task);
   begin
      pragma Assert (Native_Passed, "native DNS lifecycle checks failed");
      pragma Assert
        (Lightweight_Passed, "lightweight DNS lifecycle checks failed");
   end;
end DNS_Smoke;
