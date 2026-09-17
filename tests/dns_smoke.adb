with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.Cancellation;
with Flyology.IO.DNS;
with Flyology.IO.DNS.Testing;
with Flyology.IO.Files;
with Flyology.IO.Sockets;
with Flyology.Operations;
with Flyology.Operations.Drivers;
with Flyology.Wake_Sources;
with Interfaces.C;

procedure DNS_Smoke is
   function Interface_Index (Name : Interfaces.C.char_array) return Interfaces.C.unsigned
   with Import, Convention => C, External_Name => "if_nametoindex";

   package DNS renames Flyology.IO.DNS;
   package Sockets renames Flyology.IO.Sockets;
   package Streams renames Ada.Streams;
   package Unbounded renames Ada.Strings.Unbounded;
   package Operations renames Flyology.Operations;
   package Drivers renames Flyology.Operations.Drivers;

   use type Streams.Stream_Element_Offset;
   use type Streams.Stream_Element;
   use type Ada.Real_Time.Time;
   use type Sockets.Selector_Status;
   use type Flyology.IO.Files.File_Descriptor;
   use type Operations.Driver_Event;
   use type Operations.Terminal_Outcome;
   use type Interfaces.C.unsigned;
   use type Sockets.Scope_ID;
   use type Sockets.Address_Family;
   use type Sockets.Port;

   type Parent_Phase is (Starting_DNS, Waiting_For_DNS, Cancelling_DNS);
   type DNS_Parent (Owner : not null access Operations.Completion_Set'Class) is
     new Operations.Operation (Owner)
   with record
      Child  : DNS.Resolve_Operation (Owner);
      Server : Sockets.Endpoint := Sockets.No_Endpoint;
      Phase  : Parent_Phase := Starting_DNS;
      Failed : Boolean := False;
   end record;

   overriding
   procedure Drive (Item : in out DNS_Parent; Event : Operations.Driver_Event);

   overriding
   procedure Request_Cancellation (Item : in out DNS_Parent);

   overriding
   procedure Drive (Item : in out DNS_Parent; Event : Operations.Driver_Event) is
   begin
      if Event = Operations.Start_Operation then
         Item.Phase := Waiting_For_DNS;
         DNS.Resolve_Using
           ("cancel.test",
            (1 => Item.Server),
            DNS.IPv4_Only,
            Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (2.0),
            Attempts       => 1,
            Retry_Interval => 1.0,
            Operation      => Item.Child);
         Operations.Continue_After (Item, Item.Child);
      elsif Event = Operations.Dependency_Changed then
         begin
            declare
               Ignored : constant DNS.Address_Array := DNS.Finish (Item.Child);
               pragma Unreferenced (Ignored);
            begin
               Item.Failed := Item.Phase /= Cancelling_DNS;
            end;
         exception
            when DNS.Operation_Cancelled =>
               Item.Failed := Item.Phase /= Cancelling_DNS;
            when others =>
               Item.Failed := True;
         end;
         Operations.Release (Item.Child);
         Drivers.Complete (Item, (if Item.Failed then Operations.Failed else Operations.Cancelled));
      else
         Item.Failed := True;
         Drivers.Complete (Item, Operations.Failed);
      end if;
   end Drive;

   overriding
   procedure Request_Cancellation (Item : in out DNS_Parent) is
   begin
      Item.Phase := Cancelling_DNS;
      Operations.Cancel (Item.Child);
   exception
      when others =>
         Item.Failed := True;
         Drivers.Complete (Item, Operations.Failed);
   end Request_Cancellation;

   procedure Start_Parent (Item : in out DNS_Parent; Server : Sockets.Endpoint) is
   begin
      Item.Server := Server;
      Item.Phase := Starting_DNS;
      Item.Failed := False;
      Drivers.Start (Item);
      Operations.Drive (Operations.Operation'Class (Item), Operations.Start_Operation);
   end Start_Parent;

   function Run (Model : Flyology.Execution_Model) return Boolean is
      Cancel_Source     : aliased Flyology.Wake_Sources.Source;
      --  Functional loopback exchanges must tolerate hosted-runner stalls.
      --  dns_resilience_smoke owns the deliberately narrow deadline checks.
      Operation_Timeout : constant Duration := 2.0;
      Attempt_Interval  : constant Duration := 0.5;
      Search_Name       : constant String (1 .. 60) := (others => 'r');
      Bare_Name         : constant String (1 .. 60) := (others => 'b');
      NDots_Name        : constant String := "ndots-once.test";
      NDots_Mixed_Name  : constant String := "ndots-mixed.test";
      NDots_Reverse_Name : constant String := "ndots-reverse.test";
      NDots_Suffix      : constant String := "candidate.test";
      Search_Label      : constant String (1 .. 62) := (others => 's');
      Invalid_Label     : constant String (1 .. 64) := (others => 'i');
      Long_Search       : constant String :=
        Search_Label & "." & Search_Label & "." & Search_Label & "." & Search_Label;

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
         entry Wait_Cancel_Or_Finished (Client_Finished : out Boolean; Passed : out Boolean);
         procedure Missing_Query;
         function Missing_Queries return Natural;
         procedure NDots_Query (Bare : Boolean);
         function NDots_Bare_Queries return Natural;
         function NDots_Search_Queries return Natural;
         procedure NDots_Mixed_Search_Query;
         function NDots_Mixed_Search_Queries return Natural;
         procedure A_Query;
         function A_Queries return Natural;
         procedure Alias_Query;
         function Alias_Queries return Natural;
         procedure Chain_Query;
         function Chain_Queries return Natural;
         procedure TCP_Truncated_Query;
         function TCP_Truncated_Queries return Natural;
         procedure TCP_Restart_Checked (Closed : Boolean);
         function TCP_Restart_Checks return Natural;
         function TCP_Restarts_Closed return Boolean;
         procedure Recursive_Failure_Query;
         function Recursive_Failure_Queries return Natural;
         procedure Finished (Passed : Boolean);
         entry Wait_Finished (Passed : out Boolean);
      private
         Is_Ready                : Boolean := False;
         Primary_Setup_Failed    : Boolean := False;
         Can_Start               : Boolean := False;
         Server                  : Sockets.Endpoint;
         Secondary_Is_Ready      : Boolean := False;
         Secondary_Setup_Failed  : Boolean := False;
         Secondary               : Sockets.Endpoint;
         Cancel_Seen             : Boolean := False;
         Missing_Count           : Natural := 0;
         NDots_Bare_Count        : Natural := 0;
         NDots_Search_Count      : Natural := 0;
         NDots_Mixed_Search_Count : Natural := 0;
         A_Count                 : Natural := 0;
         Alias_Count             : Natural := 0;
         Chain_Count             : Natural := 0;
         TCP_Truncated_Count     : Natural := 0;
         TCP_Restart_Count       : Natural := 0;
         TCP_Restart_Closed      : Boolean := True;
         Recursive_Failure_Count : Natural := 0;
         Is_Finished             : Boolean := False;
         All_OK                  : Boolean := False;
      end Control;

      function Config_Path (Server : Sockets.Endpoint; Suffix : String := "") return String is
      begin
         return
           Ada.Environment_Variables.Value ("TMPDIR", "/tmp")
           & "/flyology-dns-smoke-"
           & Ada.Strings.Fixed.Trim (Sockets.Port'Image (Server.Port), Ada.Strings.Both)
           & Suffix
           & ".conf";
      end Config_Path;

      procedure Close_Quietly (Socket : in out Sockets.Socket_Type) is
      begin
         if Sockets.Is_Open (Socket) then
            Sockets.Close_Socket (Socket);
         end if;
      exception
         when others =>
            null;
      end Close_Quietly;

      procedure Write_Config
        (Server      : Sockets.Endpoint;
         Search      : String := "";
         Suffix      : String := "";
         Server_Text : String := "") is
         File             : Flyology.IO.Files.File_Descriptor := Flyology.IO.Files.Invalid_File;
         Search_Directive : constant String :=
           (if Search'Length = 0 then "" else "search " & Search & ASCII.LF);
         Text             : constant String :=
           ASCII.HT
           & "nameserver"
           & ASCII.HT
           & (if Server_Text'Length = 0 then Sockets.Image (Server) else Server_Text)
           & ASCII.HT
           & ASCII.LF
           & Search_Directive
           & ASCII.HT
           & "options"
           & ASCII.HT
           & "attempts:1 timeout:1"
           & ASCII.HT
           & ASCII.LF;
         Data             : Streams.Stream_Element_Array (1 .. Streams.Stream_Element_Offset (Text'Length));
         Last             : Streams.Stream_Element_Offset;
      begin
         for Index in Text'Range loop
            Data (Streams.Stream_Element_Offset (Index - Text'First + 1)) := Character'Pos (Text (Index));
         end loop;
         File :=
           Flyology.IO.Files.Open
             (Config_Path (Server, Suffix), Flyology.IO.Files.Write_Only, Create => True, Truncate => True);
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
         entry Get_Address (Address : out Sockets.Endpoint) when Is_Ready or else Primary_Setup_Failed is
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
         entry Wait_Cancel_Or_Finished (Client_Finished : out Boolean; Passed : out Boolean)
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
         function Missing_Queries return Natural
         is (Missing_Count);
         procedure NDots_Query (Bare : Boolean) is
         begin
            if Bare then
               NDots_Bare_Count := NDots_Bare_Count + 1;
            else
               NDots_Search_Count := NDots_Search_Count + 1;
            end if;
         end NDots_Query;
         function NDots_Bare_Queries return Natural
         is (NDots_Bare_Count);
         function NDots_Search_Queries return Natural
         is (NDots_Search_Count);
         procedure NDots_Mixed_Search_Query is
         begin
            NDots_Mixed_Search_Count := NDots_Mixed_Search_Count + 1;
         end NDots_Mixed_Search_Query;
         function NDots_Mixed_Search_Queries return Natural
         is (NDots_Mixed_Search_Count);
         procedure A_Query is
         begin
            A_Count := A_Count + 1;
         end A_Query;
         function A_Queries return Natural
         is (A_Count);
         procedure Alias_Query is
         begin
            Alias_Count := Alias_Count + 1;
         end Alias_Query;
         function Alias_Queries return Natural
         is (Alias_Count);
         procedure Chain_Query is
         begin
            Chain_Count := Chain_Count + 1;
         end Chain_Query;
         function Chain_Queries return Natural
         is (Chain_Count);
         procedure TCP_Truncated_Query is
         begin
            TCP_Truncated_Count := TCP_Truncated_Count + 1;
         end TCP_Truncated_Query;
         function TCP_Truncated_Queries return Natural
         is (TCP_Truncated_Count);
         procedure TCP_Restart_Checked (Closed : Boolean) is
         begin
            TCP_Restart_Count := TCP_Restart_Count + 1;
            TCP_Restart_Closed := TCP_Restart_Closed and Closed;
         end TCP_Restart_Checked;
         function TCP_Restart_Checks return Natural
         is (TCP_Restart_Count);
         function TCP_Restarts_Closed return Boolean
         is (TCP_Restart_Closed);
         procedure Recursive_Failure_Query is
         begin
            Recursive_Failure_Count := Recursive_Failure_Count + 1;
         end Recursive_Failure_Query;
         function Recursive_Failure_Queries return Natural
         is (Recursive_Failure_Count);
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
         UDP, TCP           : Sockets.Socket_Type;
         Collision          : Sockets.Socket_Type;
         Peer               : Sockets.Endpoint;
         Bound              : Sockets.Endpoint;
         Query              : Streams.Stream_Element_Array (1 .. 512);
         Last               : Streams.Stream_Element_Offset;
         Retry_Count        : Natural := 0;
         Scoped_Retry_Count : Natural := 0;
         Bad_Length_Count   : Natural := 0;
         Bad_Message_Count  : Natural := 0;
         Restart_Connection : aliased Sockets.Socket_Type;

         procedure Open_Server_Sockets is
         begin
            --  UDP and TCP have independent ephemeral-port allocation. Bind
            --  TCP first so its selected port is known to be free in the
            --  stream namespace, then retry if UDP already owns that number.
            --  The first synthetic conflict exercises this recovery instead
            --  of allowing a setup exception to become a test hang.
            for Attempt in 1 .. 16 loop
               begin
                  Sockets.Create_Socket (TCP, Sockets.IPv4, Sockets.Socket_Stream);
                  Sockets.Set_Socket_Option
                    (TCP, Sockets.Socket_Level, (Name => Sockets.Reuse_Address, Enabled => True));
                  Sockets.Bind_Socket
                    (TCP, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
                  Bound := Sockets.Get_Socket_Name (TCP);
                  Sockets.Listen_Socket (TCP);

                  if Attempt = 1 then
                     Sockets.Create_Socket (Collision, Sockets.IPv4, Sockets.Socket_Datagram);
                     Sockets.Bind_Socket (Collision, Bound);
                  end if;
                  Sockets.Create_Socket (UDP, Sockets.IPv4, Sockets.Socket_Datagram);
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
            Result       : String (1 .. 253);
            Length       : Natural := 0;
            Position     : Streams.Stream_Element_Offset := 13;
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
                  Result (Length) :=
                    Character'Val (Query (Position + Streams.Stream_Element_Offset (Offset)));
               end loop;
               Position := Position + Streams.Stream_Element_Offset (Label_Length);
            end loop;
            return Result (1 .. Length);
         end Query_Name;

         function Query_Type return Natural is
            Position : Streams.Stream_Element_Offset := 13;
         begin
            while Query (Position) /= 0 loop
               Position := Position + 1 + Streams.Stream_Element_Offset (Query (Position));
            end loop;
            Position := Position + 1;
            return Natural (Query (Position)) * 256 + Natural (Query (Position + 1));
         end Query_Type;

         procedure Put_U16
           (Buffer   : in out Streams.Stream_Element_Array;
            Position : in out Streams.Stream_Element_Offset;
            Value    : Natural) is
         begin
            Buffer (Position) := Streams.Stream_Element ((Value / 256) mod 256);
            Buffer (Position + 1) := Streams.Stream_Element (Value mod 256);
            Position := Position + 2;
         end Put_U16;

         procedure Put_U32
           (Buffer   : in out Streams.Stream_Element_Array;
            Position : in out Streams.Stream_Element_Offset;
            Value    : Natural) is
         begin
            Buffer (Position) := Streams.Stream_Element ((Value / 16#1000000#) mod 256);
            Buffer (Position + 1) := Streams.Stream_Element ((Value / 16#10000#) mod 256);
            Buffer (Position + 2) := Streams.Stream_Element ((Value / 256) mod 256);
            Buffer (Position + 3) := Streams.Stream_Element (Value mod 256);
            Position := Position + 4;
         end Put_U32;

         procedure Put_Name
           (Buffer   : in out Streams.Stream_Element_Array;
            Position : in out Streams.Stream_Element_Offset;
            Name     : String)
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
                  Buffer (Position) := Streams.Stream_Element (Character'Pos (Name (Index)));
                  Position := Position + 1;
               end loop;
               Start := Stop + 1;
            end loop;
            Buffer (Position) := 0;
            Position := Position + 1;
         end Put_Name;

         procedure Send_TCP_All (Socket : Sockets.Socket_Type; Data : Streams.Stream_Element_Array) is
            Next      : Streams.Stream_Element_Offset := Data'First;
            Sent_Last : Streams.Stream_Element_Offset;
         begin
            while Next <= Data'Last loop
               Sockets.Send_Socket (Socket, Data (Next .. Data'Last), Sent_Last);
               if Sent_Last < Next then
                  raise Program_Error with "TCP DNS fixture send made no progress";
               end if;
               Next := Sent_Last + 1;
            end loop;
         end Send_TCP_All;

         procedure Send_Response
           (Name             : String;
            IPv4             : String := "";
            IPv6             : String := "";
            CNAME            : String := "";
            NXDOMAIN         : Boolean := False;
            Server_Failure   : Boolean := False;
            Truncated        : Boolean := False;
            Malformed        : Boolean := False;
            Extra_Answers    : Natural := 0;
            Bad_Extra_Length : Boolean := False;
            Bad_Extra_CNAME  : Boolean := False;
            Late_CNAME       : String := "";
            TTL              : Natural := 60;
            Socket           : access Sockets.Socket_Type := null;
            Datagram         : access Sockets.Socket_Type := null)
         is
            Response      : Streams.Stream_Element_Array (1 .. 2_048) := (others => 0);
            Position      : Streams.Stream_Element_Offset := 1;
            Question_Last : Streams.Stream_Element_Offset := 13;
            Sent_Last     : Streams.Stream_Element_Offset;
            Address       : Sockets.IP_Address;
            Destination   : constant Sockets.Endpoint := Peer;

            procedure Append_Answers is
               Length_Position : Streams.Stream_Element_Offset;
               Data_Start      : Streams.Stream_Element_Offset;
            begin
               for Index in 1 .. Extra_Answers loop
                  if Late_CNAME'Length > 0 and then Index < Extra_Answers then
                     Put_Name (Response, Position, Late_CNAME);
                  else
                     Response (Position) := 16#C0#;
                     Response (Position + 1) := 12;
                     Position := Position + 2;
                  end if;
                  if (Late_CNAME'Length > 0 or else Bad_Extra_CNAME) and then Index = Extra_Answers then
                     Put_U16 (Response, Position, 5);
                  else
                     Put_U16 (Response, Position, 1);
                  end if;
                  Put_U16 (Response, Position, 1);
                  Put_U32 (Response, Position, TTL);
                  if Late_CNAME'Length > 0 and then Index = Extra_Answers then
                     Length_Position := Position;
                     Position := Position + 2;
                     Data_Start := Position;
                     Put_Name (Response, Position, Late_CNAME);
                     Response (Length_Position) := 0;
                     Response (Length_Position + 1) := Streams.Stream_Element (Position - Data_Start);
                  elsif Bad_Extra_CNAME and then Index = Extra_Answers then
                     Put_U16 (Response, Position, 2);
                     Response (Position .. Position + 1) := (16#FF#, 16#FF#);
                     Position := Position + 2;
                  else
                     Put_U16
                       (Response, Position,
                        (if Bad_Extra_Length and then Index = Extra_Answers then 16 else 4));
                     Response (Position .. Position + 3) := (192, 0, 2, 200);
                     Position := Position + 4;
                  end if;
               end loop;
            end Append_Answers;
         begin
            while Query (Question_Last) /= 0 loop
               Question_Last := Question_Last + 1 + Streams.Stream_Element_Offset (Query (Question_Last));
            end loop;
            Question_Last := Question_Last + 4;
            Response (1 .. 2) := Query (1 .. 2);
            Position := 3;
            Put_U16
              (Response,
               Position,
               (if Truncated then 16#8380#
                elsif NXDOMAIN then 16#8183#
                elsif Server_Failure then 16#8182#
                else 16#8180#));
            Put_U16 (Response, Position, 1);
            Put_U16
              (Response,
               Position,
               (if Truncated or else NXDOMAIN or else Server_Failure then 0 else 1 + Extra_Answers));
            Put_U16 (Response, Position, 0);
            Put_U16 (Response, Position, 0);
            Response (Position .. Position + Question_Last - 13) := Query (13 .. Question_Last);
            Position := Position + Question_Last - 12;
            if not Truncated and then not NXDOMAIN and then not Server_Failure then
               if Late_CNAME'Length > 0 then
                  Put_Name (Response, Position, Late_CNAME);
               elsif Malformed then
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
                     Data_Start      : Streams.Stream_Element_Offset;
                  begin
                     Position := Position + 2;
                     Data_Start := Position;
                     Put_Name (Response, Position, CNAME);
                     Response (Length_Position) := 0;
                     Response (Length_Position + 1) := Streams.Stream_Element (Position - Data_Start);
                  end;
               else
                  Put_U16 (Response, Position, (if IPv6'Length = 0 then 1 else 28));
                  Put_U16 (Response, Position, 1);
                  Put_U32 (Response, Position, TTL);
                  if IPv6'Length = 0 then
                     Put_U16 (Response, Position, 4);
                     Address := Sockets.Parse_IP_Address (IPv4);
                     for Index in Address.V4'Range loop
                        Response (Position) := Streams.Stream_Element (Address.V4 (Index));
                        Position := Position + 1;
                     end loop;
                  else
                     Put_U16 (Response, Position, 16);
                     Address := Sockets.Parse_IP_Address (IPv6);
                     for Index in Address.V6'Range loop
                        Response (Position) := Streams.Stream_Element (Address.V6 (Index));
                        Position := Position + 1;
                     end loop;
                  end if;
               end if;
            end if;
            Append_Answers;
            if Socket = null then
               if Datagram = null then
                  Sockets.Send_Socket (UDP, Response (1 .. Position - 1), Sent_Last, Destination);
               else
                  Sockets.Send_Socket (Datagram.all, Response (1 .. Position - 1), Sent_Last, Destination);
               end if;
            else
               declare
                  Prefix : Streams.Stream_Element_Array (1 .. 2);
               begin
                  Prefix (1) := Streams.Stream_Element ((Natural (Position - 1) / 256) mod 256);
                  Prefix (2) := Streams.Stream_Element (Natural (Position - 1) mod 256);
                  Send_TCP_All (Socket.all, Prefix);
                  Send_TCP_All (Socket.all, Response (1 .. Position - 1));
               end;
            end if;
            pragma Unreferenced (Name);
         end Send_Response;
      begin
         Open_Server_Sockets;
         Control.Ready (Bound);
         loop
            Sockets.Receive_Socket (UDP, Query, Last, Peer);
            exit when
              Last = 4
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
               elsif Name = "many-answers.test" then
                  Send_Response (Name, IPv4 => "192.0.2.10", Extra_Answers => 32);
               elsif Name = "bad-surplus.test" then
                  Send_Response
                    (Name, IPv4 => "192.0.2.13", Extra_Answers => 32, Bad_Extra_Length => True);
               elsif Name = "late-alias.test" then
                  Send_Response
                    (Name, IPv4 => "192.0.2.25", Extra_Answers => 32, Late_CNAME => "target-late.test");
               elsif Name = "bad-surplus-cname.test" then
                  Send_Response
                    (Name, IPv4 => "192.0.2.14", Extra_Answers => 32, Bad_Extra_CNAME => True);
               elsif Name = "default-deadline.test" then
                  delay 0.05;
                  Send_Response (Name, IPv4 => "192.0.2.179");
               elsif Name = "v6.test" then
                  Send_Response (Name, IPv6 => "2001:db8::5");
               elsif Name = "alias.test" then
                  Control.Alias_Query;
                  Send_Response (Name, CNAME => "target.test");
               elsif Name = "target.test" then
                  Send_Response (Name, IPv4 => "203.0.113.7");
               elsif Name = "chain-a.test" then
                  Control.Chain_Query;
                  Send_Response (Name, CNAME => "chain-b.test", TTL => 5);
               elsif Name = "chain-b.test" then
                  Send_Response (Name, CNAME => "chain-c.test", TTL => 1);
               elsif Name = "chain-c.test" then
                  Send_Response (Name, IPv4 => "203.0.113.88", TTL => 100);
               elsif Name = "missing.test" then
                  Control.Missing_Query;
                  Send_Response (Name, NXDOMAIN => True);
               elsif Name = "malformed.test" then
                  Send_Response (Name, IPv4 => "192.0.2.2", Malformed => True);
                  Send_Response (Name, IPv4 => "192.0.2.2");
               elsif Name = "off-path.test" then
                  declare
                     Spoof : aliased Sockets.Socket_Type;
                  begin
                     Sockets.Create_Socket (Spoof, Sockets.IPv4, Sockets.Socket_Datagram);
                     Sockets.Bind_Socket
                       (Spoof, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
                     Send_Response (Name, IPv4 => "192.0.2.250", Datagram => Spoof'Access);
                     Sockets.Close_Socket (Spoof);
                  end;
                  Send_Response (Name, IPv4 => "192.0.2.3");
               elsif Name = "retry.test" then
                  Retry_Count := Retry_Count + 1;
                  if Retry_Count > 1 then
                     Send_Response (Name, IPv4 => "198.51.100.4");
                  end if;
               elsif Name = "scoped-retry.test" then
                  Scoped_Retry_Count := Scoped_Retry_Count + 1;
                  if Scoped_Retry_Count > 1 then
                     Send_Response (Name, IPv4 => "198.51.100.178");
                  end if;
               elsif Name in "tcp.test" | "many-tcp.test" then
                  Send_Response (Name, Truncated => True);
                  declare
                     Connection : aliased Sockets.Socket_Type;
                     Address    : Sockets.Endpoint;
                     Prefix     : Streams.Stream_Element_Array (1 .. 2);
                     TCP_Last   : Streams.Stream_Element_Offset;
                     Length     : Natural;
                     Status     : Sockets.Selector_Status;
                  begin
                     Sockets.Accept_Socket (TCP, Connection, Address, Timeout => 1.0, Status => Status);
                     if Status = Sockets.Completed then
                        Sockets.Set_Socket_Option
                          (Connection,
                           Sockets.Socket_Level,
                           (Name => Sockets.Receive_Timeout, Timeout => 1.0));
                        Sockets.Receive_Socket (Connection, Prefix, TCP_Last);
                        Length := Natural (Prefix (1)) * 256 + Natural (Prefix (2));
                        Sockets.Receive_Socket
                          (Connection, Query (1 .. Streams.Stream_Element_Offset (Length)), TCP_Last);
                        Last := Streams.Stream_Element_Offset (Length);
                        Send_Response
                          (Name,
                           IPv4          => "198.51.100.9",
                           Extra_Answers => (if Name = "many-tcp.test" then 32 else 0),
                           Socket        => Connection'Access);
                        Sockets.Close_Socket (Connection);
                     end if;
                  end;
               elsif Name in "tcp-bad-length.test" | "tcp-bad-message.test" then
                  if Name = "tcp-bad-length.test" then
                     Bad_Length_Count := Bad_Length_Count + 1;
                  else
                     Bad_Message_Count := Bad_Message_Count + 1;
                  end if;
                  if (if Name = "tcp-bad-length.test" then Bad_Length_Count else Bad_Message_Count) mod 2 = 1
                  then
                     Send_Response (Name, Truncated => True);
                     declare
                        Address  : Sockets.Endpoint;
                        Prefix   : Streams.Stream_Element_Array (1 .. 2);
                        TCP_Last : Streams.Stream_Element_Offset;
                        Length   : Natural;
                        Status   : Sockets.Selector_Status;

                        procedure Read_Exactly (Data : out Streams.Stream_Element_Array) is
                           Next : Streams.Stream_Element_Offset := Data'First;
                        begin
                           while Next <= Data'Last loop
                              Sockets.Receive_Socket (Restart_Connection, Data (Next .. Data'Last), TCP_Last);
                              if TCP_Last < Next then
                                 raise Program_Error with "TCP restart fixture closed during query";
                              end if;
                              Next := TCP_Last + 1;
                           end loop;
                        end Read_Exactly;
                     begin
                        Sockets.Accept_Socket
                          (TCP, Restart_Connection, Address, Timeout => 1.0, Status => Status);
                        if Status /= Sockets.Completed then
                           raise Program_Error with "TCP restart fixture was not connected";
                        end if;
                        Sockets.Set_Socket_Option
                          (Restart_Connection,
                           Sockets.Socket_Level,
                           (Name => Sockets.Receive_Timeout, Timeout => 1.0));
                        Read_Exactly (Prefix);
                        Length := Natural (Prefix (1)) * 256 + Natural (Prefix (2));
                        if Length < 12 or else Length > Query'Length then
                           raise Program_Error with "TCP restart fixture query has invalid length";
                        end if;
                        Read_Exactly (Query (1 .. Streams.Stream_Element_Offset (Length)));
                        Last := Streams.Stream_Element_Offset (Length);
                        if Name = "tcp-bad-length.test" then
                           Send_TCP_All (Restart_Connection, (1 => 0, 2 => 1));
                        else
                           Send_Response
                             (Name,
                              IPv4      => "192.0.2.180",
                              Malformed => True,
                              Socket    => Restart_Connection'Access);
                        end if;
                     end;
                  else
                     --  The next UDP attempt must arrive after closing the
                     --  abandoned TCP connection, before resolution ends.
                     declare
                        Probe    : Streams.Stream_Element_Array (1 .. 1);
                        TCP_Last : Streams.Stream_Element_Offset;
                        Closed   : Boolean := False;
                     begin
                        begin
                           Sockets.Set_Socket_Option
                             (Restart_Connection,
                              Sockets.Socket_Level,
                              (Name => Sockets.Receive_Timeout, Timeout => 0.2));
                           Sockets.Receive_Socket (Restart_Connection, Probe, TCP_Last);
                           Closed := TCP_Last < Probe'First;
                        exception
                           when Sockets.Socket_Error =>
                              null;
                        end;
                        Control.TCP_Restart_Checked (Closed);
                        Sockets.Close_Socket (Restart_Connection);
                     end;
                     Send_Response (Name, IPv4 => "192.0.2.180");
                  end if;
               elsif Name = "tcp-silent.test" then
                  Send_Response (Name, Truncated => True);
                  declare
                     Connection : aliased Sockets.Socket_Type;
                     Address    : Sockets.Endpoint;
                     Status     : Sockets.Selector_Status;
                  begin
                     Sockets.Accept_Socket (TCP, Connection, Address, Timeout => 1.0, Status => Status);
                     if Status = Sockets.Completed then
                        delay 0.15;
                        Sockets.Close_Socket (Connection);
                     end if;
                  end;
               elsif Name in "tcp-truncated.test" | "scoped-tcp-truncated.test" then
                  if Name = "tcp-truncated.test" then
                     Control.TCP_Truncated_Query;
                  end if;
                  Send_Response (Name, Truncated => True);
                  declare
                     Connection : aliased Sockets.Socket_Type;
                     Address    : Sockets.Endpoint;
                     Prefix     : Streams.Stream_Element_Array (1 .. 2);
                     TCP_Last   : Streams.Stream_Element_Offset;
                     Length     : Natural;
                     Status     : Sockets.Selector_Status;
                  begin
                     Sockets.Accept_Socket (TCP, Connection, Address, Timeout => 1.0, Status => Status);
                     if Status = Sockets.Completed then
                        Sockets.Set_Socket_Option
                          (Connection,
                           Sockets.Socket_Level,
                           (Name => Sockets.Receive_Timeout, Timeout => 1.0));
                        Sockets.Receive_Socket (Connection, Prefix, TCP_Last);
                        Length := Natural (Prefix (1)) * 256 + Natural (Prefix (2));
                        Sockets.Receive_Socket
                          (Connection, Query (1 .. Streams.Stream_Element_Offset (Length)), TCP_Last);
                        Last := Streams.Stream_Element_Offset (Length);
                        Send_Response (Name, Truncated => True, Socket => Connection'Access);
                        Sockets.Close_Socket (Connection);
                     end if;
                  end;
               elsif Name = "recursive-failure.test" then
                  Control.Recursive_Failure_Query;
                  Send_Response (Name, CNAME => "recursive-target.test");
               elsif Name = "recursive-target.test" then
                  Control.Recursive_Failure_Query;
                  Send_Response (Name, IPv4 => "192.0.2.70", Malformed => True);
               elsif Name = "dual.test" then
                  if Query_Type = 1 then
                     Send_Response (Name, IPv4 => "192.0.2.66");
                  end if;
               elsif Name = "dual-malformed.test" then
                  if Query_Type = 28 then
                     Send_Response (Name, IPv6 => "2001:db8::bad", Malformed => True);
                  else
                     Send_Response (Name, IPv4 => "192.0.2.67");
                  end if;
               elsif Name = "order.test" then
                  Send_Response (Name, IPv4 => "192.0.2.20");
               elsif Name = "config.test" then
                  Send_Response (Name, IPv4 => "192.0.2.53");
               elsif Name = NDots_Name or else Name = NDots_Name & "." & NDots_Suffix then
                  Control.NDots_Query (Bare => Name = NDots_Name);
                  Send_Response (Name, Server_Failure => True);
               elsif Name = NDots_Mixed_Name then
                  Send_Response (Name, Server_Failure => True);
               elsif Name = NDots_Mixed_Name & "." & NDots_Suffix then
                  Control.NDots_Mixed_Search_Query;
                  Send_Response (Name, NXDOMAIN => True);
               elsif Name = NDots_Reverse_Name then
                  Send_Response (Name, NXDOMAIN => True);
               elsif Name = NDots_Reverse_Name & "." & NDots_Suffix then
                  Control.NDots_Mixed_Search_Query;
                  Send_Response (Name, Server_Failure => True);
               elsif Name = Search_Name & ".valid.test" then
                  Send_Response (Name, IPv4 => "192.0.2.54");
               elsif Name = Search_Name & ".bad" then
                  Send_Response (Name, IPv4 => "192.0.2.56");
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
         Close_Quietly (Restart_Connection);
         Sockets.Close_Socket (UDP);
         Sockets.Close_Socket (TCP);
      exception
         when Error : others =>
            Close_Quietly (Collision);
            Close_Quietly (UDP);
            Close_Quietly (TCP);
            Close_Quietly (Restart_Connection);
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "primary DNS test server failed: " & Ada.Exceptions.Exception_Information (Error));
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
            Result       : String (1 .. 253);
            Length       : Natural := 0;
            Position     : Streams.Stream_Element_Offset := 13;
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
                  Result (Length) :=
                    Character'Val (Query (Position + Streams.Stream_Element_Offset (Offset)));
               end loop;
               Position := Position + Streams.Stream_Element_Offset (Label_Length);
            end loop;
            return Result (1 .. Length);
         end Query_Name;

         procedure Put_U16 (Position : in out Streams.Stream_Element_Offset; Value : Natural) is
         begin
            Response (Position) := Streams.Stream_Element ((Value / 256) mod 256);
            Response (Position + 1) := Streams.Stream_Element (Value mod 256);
            Position := Position + 2;
         end Put_U16;

         procedure Put_U32 (Position : in out Streams.Stream_Element_Offset; Value : Natural) is
         begin
            Response (Position) := Streams.Stream_Element ((Value / 16#1000000#) mod 256);
            Response (Position + 1) := Streams.Stream_Element ((Value / 16#10000#) mod 256);
            Response (Position + 2) := Streams.Stream_Element ((Value / 256) mod 256);
            Response (Position + 3) := Streams.Stream_Element (Value mod 256);
            Position := Position + 4;
         end Put_U32;

         procedure Send_A (Address_Image : String) is
            Position      : Streams.Stream_Element_Offset := 3;
            Question_Last : Streams.Stream_Element_Offset := 13;
            Sent_Last     : Streams.Stream_Element_Offset;
            Address       : constant Sockets.IP_Address := Sockets.Parse_IP_Address (Address_Image);
         begin
            Response := (others => 0);
            while Query (Question_Last) /= 0 loop
               Question_Last := Question_Last + 1 + Streams.Stream_Element_Offset (Query (Question_Last));
            end loop;
            Question_Last := Question_Last + 4;
            Response (1 .. 2) := Query (1 .. 2);
            Put_U16 (Position, 16#8180#);
            Put_U16 (Position, 1);
            Put_U16 (Position, 1);
            Put_U16 (Position, 0);
            Put_U16 (Position, 0);
            Response (Position .. Position + Question_Last - 13) := Query (13 .. Question_Last);
            Position := Position + Question_Last - 12;
            Response (Position) := 16#C0#;
            Response (Position + 1) := 12;
            Position := Position + 2;
            Put_U16 (Position, 1);
            Put_U16 (Position, 1);
            Put_U32 (Position, 60);
            Put_U16 (Position, 4);
            for Index in Address.V4'Range loop
               Response (Position) := Streams.Stream_Element (Address.V4 (Index));
               Position := Position + 1;
            end loop;
            Sockets.Send_Socket (UDP, Response (1 .. Position - 1), Sent_Last, Peer);
         end Send_A;
      begin
         Sockets.Create_Socket (UDP, Sockets.IPv4, Sockets.Socket_Datagram);
         Sockets.Bind_Socket (UDP, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
         Bound := Sockets.Get_Socket_Name (UDP);
         Control.Secondary_Ready (Bound);
         loop
            Sockets.Receive_Socket (UDP, Query, Last, Peer);
            exit when
              Last = 4
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
               "secondary DNS test server failed: " & Ada.Exceptions.Exception_Information (Error));
            Control.Secondary_Failed;
      end Secondary_Server;

      task Client is
         pragma Task_Info (Model);
      end Client;

      task body Client is
         Server    : Sockets.Endpoint;
         Secondary : Sockets.Endpoint;
         Servers   : DNS.Name_Server_Array (1 .. 1);
         OK        : Boolean := True;
         Cancelled : Boolean := False;
         Stage     : Unbounded.Unbounded_String := Unbounded.To_Unbounded_String ("startup");

         procedure Set_Stage (Value : String) is
         begin
            Stage := Unbounded.To_Unbounded_String (Value);
         end Set_Stage;

         procedure Expect (Name, Address : String);
         procedure Expect (Name, Address : String) is
         begin
            Set_Stage ("IPv4 " & Name);
            declare
               Values : constant DNS.Address_Array :=
                 DNS.Resolve_Using
                   (Name,
                    Servers,
                    DNS.IPv4_Only,
                    Timeout        => Operation_Timeout,
                    Attempts       => 2,
                    Retry_Interval => Attempt_Interval);
            begin
               OK := OK and then Values'Length = 1 and then Sockets.Image (Values (Values'First)) = Address;
            end;
         end Expect;

         procedure Expect_Many (Name, First_Address : String) is
         begin
            Set_Stage ("many records " & Name);
            declare
               Values : constant DNS.Address_Array :=
                 DNS.Resolve_Using
                   (Name,
                    Servers,
                    DNS.IPv4_Only,
                    Timeout        => Operation_Timeout,
                    Attempts       => 1,
                    Retry_Interval => Attempt_Interval);
            begin
               OK :=
                 OK
                 and then Values'Length = 16
                 and then Sockets.Image (Values (Values'First)) = First_Address;
            end;
         end Expect_Many;

         procedure Expect_IPv6 (Name, Address : String) is
         begin
            Set_Stage ("IPv6 " & Name);
            declare
               Values : constant DNS.Address_Array :=
                 DNS.Resolve_Using
                   (Name,
                    Servers,
                    DNS.IPv6_Only,
                    Timeout        => Operation_Timeout,
                    Attempts       => 2,
                    Retry_Interval => Attempt_Interval);
            begin
               OK := OK and then Values'Length = 1 and then Sockets.Image (Values (Values'First)) = Address;
            end;
         end Expect_IPv6;

         procedure Expect_Malformed (Name : String) is
            Raised : Boolean := False;
         begin
            Set_Stage ("malformed " & Name);
            begin
               declare
                  Ignored : constant DNS.Address_Array :=
                    DNS.Resolve_Using
                      (Name,
                       Servers,
                       DNS.IPv4_Only,
                       Timeout        => Operation_Timeout,
                       Attempts       => 1,
                       Retry_Interval => Attempt_Interval);
                  pragma Unreferenced (Ignored);
               begin
                  null;
               end;
            exception
               when DNS.Malformed_Response =>
                  Raised := True;
               when others =>
                  null;
            end;
            OK := OK and Raised;
         end Expect_Malformed;

         procedure Run_Scoped_Checks is
            function Ref (Item : Operations.Operation'Class) return Operations.Operation_Reference
            renames Operations.Reference;

            procedure Expect_TCP_Restart (Name : String) is
               Set       : aliased Operations.Completion_Set (2);
               Operation : DNS.Resolve_Operation :=
                 DNS.Resolve_Using
                   (Set'Access,
                    Name,
                    Servers,
                    DNS.IPv4_Only,
                    Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Operation_Timeout),
                    Attempts       => 2,
                    Retry_Interval => Attempt_Interval);
            begin
               Set_Stage ("scoped TCP restart " & Name);
               Operations.Wait_All (Set);
               declare
                  Values : constant DNS.Address_Array := DNS.Finish (Operation);
               begin
                  OK :=
                    OK
                    and then Values'Length = 1
                    and then Sockets.Image (Values (Values'First)) = "192.0.2.180";
               end;
            end Expect_TCP_Restart;
         begin
            Set_Stage ("scoped default deadline");
            DNS.Clear_Cache;
            declare
               Set       : aliased Operations.Completion_Set (2);
               Operation : DNS.Resolve_Operation :=
                 DNS.Resolve_Using
                   (Set'Access,
                    "default-deadline.test",
                    Servers,
                    DNS.IPv4_Only,
                    Attempts       => 1,
                    Retry_Interval => Attempt_Interval);
            begin
               Operations.Wait_All (Set);
               declare
                  Values : constant DNS.Address_Array := DNS.Finish (Operation);
               begin
                  OK :=
                    OK
                    and then Values'Length = 1
                    and then Sockets.Image (Values (Values'First)) = "192.0.2.179";
               end;
            end;

            Set_Stage ("scoped many UDP answers");
            DNS.Clear_Cache;
            declare
               Set       : aliased Operations.Completion_Set (2);
               Operation : DNS.Resolve_Operation :=
                 DNS.Resolve_Using
                   (Set'Access,
                    "many-answers.test",
                    Servers,
                    DNS.IPv4_Only,
                    Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Operation_Timeout),
                    Attempts => 1);
            begin
               Operations.Wait_All (Set);
               declare
                  Values : constant DNS.Address_Array := DNS.Finish (Operation);
               begin
                  OK :=
                    OK
                    and then Values'Length = 16
                    and then Sockets.Image (Values (Values'First)) = "192.0.2.10";
               end;
            end;

            Set_Stage ("scoped malformed surplus");
            DNS.Clear_Cache;
            declare
               Set       : aliased Operations.Completion_Set (2);
               Operation : DNS.Resolve_Operation :=
                 DNS.Resolve_Using
                   (Set'Access,
                    "bad-surplus.test",
                    Servers,
                    DNS.IPv4_Only,
                    Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Operation_Timeout),
                    Attempts => 1);
               Raised    : Boolean := False;
            begin
               Operations.Wait_All (Set);
               begin
                  declare
                     Ignored : constant DNS.Address_Array := DNS.Finish (Operation);
                     pragma Unreferenced (Ignored);
                  begin
                     null;
                  end;
               exception
                  when DNS.Malformed_Response =>
                     Raised := True;
               end;
               OK := OK and Raised;
            end;

            Set_Stage ("scoped UDP and hidden child");
            DNS.Clear_Cache;
            declare
               Set       : aliased Operations.Completion_Set (4);
               Operation : aliased DNS.Resolve_Operation :=
                 DNS.Resolve_Using
                   (Set'Access,
                    "a.test",
                    Servers,
                    DNS.IPv4_Only,
                    Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Operation_Timeout),
                    Attempts       => 1,
                    Retry_Interval => Attempt_Interval);
               Gate      : Operations.Gate_Operation := Operations.Wait_All (Set'Access, [Ref (Operation)]);
               Batch     : Operations.Completion_Batch (Set.Capacity);
               Matched   : Operations.Completion_Batch (Set.Capacity);
            begin
               while not Operations.Is_Terminal (Operation) loop
                  Operations.Wait_Some (Set, Batch);
                  for Index in 1 .. Batch.Count loop
                     OK :=
                       OK
                       and then Natural (Batch.Ids (Index))
                                in Operations.Id (Operation) | Operations.Id (Gate);
                  end loop;
               end loop;
               Operations.Wait_All (Set);
               Operations.Finish (Gate, Matched);
               declare
                  Values : constant DNS.Address_Array := DNS.Finish (Operation);
               begin
                  OK :=
                    OK
                    and then Values'Length = 1
                    and then Sockets.Image (Values (Values'First)) = "192.0.2.1";
               end;
            end;

            Set_Stage ("scoped attempt retry");
            DNS.Clear_Cache;
            declare
               Set       : aliased Operations.Completion_Set (2);
               Operation : DNS.Resolve_Operation :=
                 DNS.Resolve_Using
                   (Set'Access,
                    "scoped-retry.test",
                    Servers,
                    DNS.IPv4_Only,
                    Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Operation_Timeout),
                    Attempts       => 2,
                    Retry_Interval => Attempt_Interval);
            begin
               Operations.Wait_All (Set);
               declare
                  Values : constant DNS.Address_Array := DNS.Finish (Operation);
               begin
                  OK :=
                    OK
                    and then Values'Length = 1
                    and then Sockets.Image (Values (Values'First)) = "198.51.100.178";
               end;
            end;

            Set_Stage ("scoped TCP fallback");
            DNS.Clear_Cache;
            declare
               Set       : aliased Operations.Completion_Set (2);
               Operation : DNS.Resolve_Operation :=
                 DNS.Resolve_Using
                   (Set'Access,
                    "tcp.test",
                    Servers,
                    DNS.IPv4_Only,
                    Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Operation_Timeout),
                    Attempts       => 1,
                    Retry_Interval => Attempt_Interval);
            begin
               Operations.Wait_All (Set);
               declare
                  Values : constant DNS.Address_Array := DNS.Finish (Operation);
               begin
                  OK :=
                    OK
                    and then Values'Length = 1
                    and then Sockets.Image (Values (Values'First)) = "198.51.100.9";
               end;
            end;

            Expect_TCP_Restart ("tcp-bad-length.test");
            Expect_TCP_Restart ("tcp-bad-message.test");
            OK := OK and then Control.TCP_Restart_Checks = 2 and then Control.TCP_Restarts_Closed;

            Set_Stage ("scoped malformed retry");
            DNS.Clear_Cache;
            declare
               Set       : aliased Operations.Completion_Set (2);
               Operation : DNS.Resolve_Operation :=
                 DNS.Resolve_Using
                   (Set'Access,
                    "malformed.test",
                    Servers,
                    DNS.IPv4_Only,
                    Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Operation_Timeout),
                    Attempts       => 1,
                    Retry_Interval => Attempt_Interval);
            begin
               Operations.Wait_All (Set);
               declare
                  Values : constant DNS.Address_Array := DNS.Finish (Operation);
               begin
                  OK :=
                    OK
                    and then Values'Length = 1
                    and then Sockets.Image (Values (Values'First)) = "192.0.2.2";
               end;
            end;

            Set_Stage ("scoped off-path datagram");
            DNS.Clear_Cache;
            declare
               Set       : aliased Operations.Completion_Set (2);
               Operation : DNS.Resolve_Operation :=
                 DNS.Resolve_Using
                   (Set'Access,
                    "off-path.test",
                    Servers,
                    DNS.IPv4_Only,
                    Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Operation_Timeout),
                    Attempts       => 1,
                    Retry_Interval => Attempt_Interval);
            begin
               Operations.Wait_All (Set);
               declare
                  Values : constant DNS.Address_Array := DNS.Finish (Operation);
               begin
                  OK :=
                    OK
                    and then Values'Length = 1
                    and then Sockets.Image (Values (Values'First)) = "192.0.2.3";
               end;
            end;

            Set_Stage ("scoped truncated TCP response");
            DNS.Clear_Cache;
            declare
               Set       : aliased Operations.Completion_Set (2);
               Operation : DNS.Resolve_Operation :=
                 DNS.Resolve_Using
                   (Set'Access,
                    "scoped-tcp-truncated.test",
                    Servers,
                    DNS.IPv4_Only,
                    Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Operation_Timeout),
                    Attempts       => 1,
                    Retry_Interval => Attempt_Interval);
               Raised    : Boolean := False;
            begin
               Operations.Wait_All (Set);
               begin
                  declare
                     Ignored : constant DNS.Address_Array := DNS.Finish (Operation);
                     pragma Unreferenced (Ignored);
                  begin
                     null;
                  end;
               exception
                  when DNS.Malformed_Response =>
                     Raised := True;
               end;
               OK := OK and Raised;
            end;

            Set_Stage ("scoped configuration snapshot");
            DNS.Clear_Cache;
            declare
               Configuration : aliased constant DNS.Resolver_Configuration :=
                 DNS.Load_Configuration (Config_Path (Server));
               Set           : aliased Operations.Completion_Set (2);
               Operation     : DNS.Resolve_Operation :=
                 DNS.Resolve
                   (Set'Access,
                    "config.test",
                    Configuration'Access,
                    DNS.IPv4_Only,
                    Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Operation_Timeout));
            begin
               Operations.Wait_All (Set);
               declare
                  Values : constant DNS.Address_Array := DNS.Finish (Operation);
               begin
                  OK :=
                    OK
                    and then Values'Length = 1
                    and then Sockets.Image (Values (Values'First)) = "192.0.2.53";
               end;
            end;

            Set_Stage ("scoped ndots candidate order");
            DNS.Clear_Cache;
            declare
               Bare_Before   : constant Natural := Control.NDots_Bare_Queries;
               Search_Before : constant Natural := Control.NDots_Search_Queries;
               Configuration : aliased constant DNS.Resolver_Configuration :=
                 DNS.Load_Configuration (Config_Path (Server, "-ndots"));
               Set           : aliased Operations.Completion_Set (2);
               Operation     : DNS.Resolve_Operation :=
                 DNS.Resolve
                   (Set'Access,
                    NDots_Name,
                    Configuration'Access,
                    DNS.IPv4_Only,
                    Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Operation_Timeout));
               Server_Failed : Boolean := False;
            begin
               Operations.Wait_All (Set);
               begin
                  declare
                     Ignored : constant DNS.Address_Array := DNS.Finish (Operation);
                     pragma Unreferenced (Ignored);
                  begin
                     null;
                  end;
               exception
                  when DNS.Name_Server_Failure =>
                     Server_Failed := True;
               end;
               OK :=
                 OK
                 and then Server_Failed
                 and then Control.NDots_Bare_Queries = Bare_Before + 1
                 and then Control.NDots_Search_Queries = Search_Before + 1;
            end;

            Set_Stage ("scoped ndots mixed failures");
            DNS.Clear_Cache;
            declare
               Search_Before : constant Natural := Control.NDots_Mixed_Search_Queries;
               Configuration : aliased constant DNS.Resolver_Configuration :=
                 DNS.Load_Configuration (Config_Path (Server, "-ndots"));
               Set           : aliased Operations.Completion_Set (2);
               Operation     : DNS.Resolve_Operation :=
                 DNS.Resolve
                   (Set'Access,
                    NDots_Mixed_Name,
                    Configuration'Access,
                    DNS.IPv4_Only,
                    Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Operation_Timeout));
               Server_Failed : Boolean := False;
            begin
               Operations.Wait_All (Set);
               begin
                  declare
                     Ignored : constant DNS.Address_Array := DNS.Finish (Operation);
                     pragma Unreferenced (Ignored);
                  begin
                     null;
                  end;
               exception
                  when DNS.Name_Server_Failure =>
                     Server_Failed := True;
               end;
               OK :=
                 OK and then Server_Failed and then Control.NDots_Mixed_Search_Queries = Search_Before + 1;
            end;

            Set_Stage ("scoped ndots reverse failures");
            DNS.Clear_Cache;
            declare
               Search_Before : constant Natural := Control.NDots_Mixed_Search_Queries;
               Configuration : aliased constant DNS.Resolver_Configuration :=
                 DNS.Load_Configuration (Config_Path (Server, "-ndots"));
               Set           : aliased Operations.Completion_Set (2);
               Operation     : DNS.Resolve_Operation :=
                 DNS.Resolve
                   (Set'Access,
                    NDots_Reverse_Name,
                    Configuration'Access,
                    DNS.IPv4_Only,
                    Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Operation_Timeout));
               Not_Found     : Boolean := False;
            begin
               Operations.Wait_All (Set);
               begin
                  declare
                     Ignored : constant DNS.Address_Array := DNS.Finish (Operation);
                     pragma Unreferenced (Ignored);
                  begin
                     null;
                  end;
               exception
                  when DNS.Name_Not_Found =>
                     Not_Found := True;
               end;
               OK := OK and then Not_Found and then Control.NDots_Mixed_Search_Queries = Search_Before + 1;
            end;

            Set_Stage ("scoped invalid search domains");
            DNS.Clear_Cache;
            declare
               Configuration : aliased constant DNS.Resolver_Configuration :=
                 DNS.Load_Configuration (Config_Path (Server, "-invalid-search"));
               Set           : aliased Operations.Completion_Set (2);
               Operation     : DNS.Resolve_Operation :=
                 DNS.Resolve
                   (Set'Access,
                    Search_Name,
                    Configuration'Access,
                    DNS.IPv4_Only,
                    Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Operation_Timeout));
            begin
               Operations.Wait_All (Set);
               declare
                  Values : constant DNS.Address_Array := DNS.Finish (Operation);
               begin
                  OK :=
                    OK
                    and then Values'Length = 1
                    and then Sockets.Image (Values (Values'First)) = "192.0.2.54";
               end;
            end;

            Set_Stage ("scoped gates");
            declare
               Set       : aliased Operations.Completion_Set (6);
               One       : aliased DNS.Resolve_Operation :=
                 DNS.Resolve_Using (Set'Access, "192.0.2.1", Servers, DNS.IPv4_Only);
               Two       : aliased DNS.Resolve_Operation :=
                 DNS.Resolve_Using (Set'Access, "192.0.2.2", Servers, DNS.IPv4_Only);
               Three     : aliased DNS.Resolve_Operation :=
                 DNS.Resolve_Using (Set'Access, "192.0.2.3", Servers, DNS.IPv4_Only);
               Some_Gate : Operations.Gate_Operation :=
                 Operations.Wait_Some (Set'Access, [Ref (One), Ref (Two)], Required => 1);
               All_Gate  : Operations.Gate_Operation :=
                 Operations.Wait_All (Set'Access, [Ref (One), Ref (Two)]);
               Success   : Operations.Gate_Operation :=
                 Operations.Wait_For_Success (Set'Access, [Ref (Two), Ref (Three)]);
               Matched   : Operations.Completion_Batch (Set.Capacity);
            begin
               Operations.Wait_All (Set);
               Operations.Finish (Some_Gate, Matched);
               Operations.Finish (All_Gate, Matched);
               Operations.Finish (Success, Matched);
               declare
                  First  : constant DNS.Address_Array := DNS.Finish (One);
                  Second : constant DNS.Address_Array := DNS.Finish (Two);
                  Third  : constant DNS.Address_Array := DNS.Finish (Three);
               begin
                  OK := OK and then First'Length = 1 and then Second'Length = 1 and then Third'Length = 1;
               end;
            end;

            Set_Stage ("scoped token cancellation");
            declare
               Stop      : aliased Flyology.Cancellation.Token;
               Set       : aliased Operations.Completion_Set (2);
               Operation : DNS.Resolve_Operation :=
                 DNS.Resolve_Using
                   (Set'Access,
                    "cancel.test",
                    Servers,
                    DNS.IPv4_Only,
                    Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (2.0),
                    Attempts       => 1,
                    Retry_Interval => 1.0,
                    Token          => Stop'Access);
               Raised    : Boolean := False;
            begin
               delay 0.02;
               Stop.Request;
               Operations.Wait_All (Set);
               begin
                  declare
                     Ignored : constant DNS.Address_Array := DNS.Finish (Operation);
                     pragma Unreferenced (Ignored);
                  begin
                     null;
                  end;
               exception
                  when DNS.Operation_Cancelled =>
                     Raised := True;
               end;
               OK := OK and Raised;
            end;

            Set_Stage ("scoped already-requested token");
            declare
               Stop      : aliased Flyology.Cancellation.Token;
               Set       : aliased Operations.Completion_Set (1);
               Operation : DNS.Resolve_Operation (Set'Access);
               Raised    : Boolean := False;
            begin
               Stop.Request;
               DNS.Resolve_Using
                 ("cancel.test",
                  Servers,
                  DNS.IPv4_Only,
                  Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (2.0),
                  Attempts       => 1,
                  Retry_Interval => 1.0,
                  Token          => Stop'Access,
                  Operation      => Operation);
               begin
                  declare
                     Ignored : constant DNS.Address_Array := DNS.Finish (Operation);
                     pragma Unreferenced (Ignored);
                  begin
                     null;
                  end;
               exception
                  when DNS.Operation_Cancelled =>
                     Raised := True;
               end;
               OK := OK and then Raised and then Operations.Pending_Count (Set) = 0;
            end;

            Set_Stage ("scoped explicit cancellation");
            declare
               Set       : aliased Operations.Completion_Set (2);
               Operation : DNS.Resolve_Operation :=
                 DNS.Resolve_Using
                   (Set'Access,
                    "cancel.test",
                    Servers,
                    DNS.IPv4_Only,
                    Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (2.0),
                    Attempts       => 1,
                    Retry_Interval => 1.0);
               Raised    : Boolean := False;
            begin
               delay 0.02;
               Operations.Cancel (Operation);
               Operations.Wait_All (Set);
               begin
                  declare
                     Ignored : constant DNS.Address_Array := DNS.Finish (Operation);
                     pragma Unreferenced (Ignored);
                  begin
                     null;
                  end;
               exception
                  when DNS.Operation_Cancelled =>
                     Raised := True;
               end;
               OK := OK and Raised;
            end;

            Set_Stage ("scoped deadline");
            declare
               Set       : aliased Operations.Completion_Set (2);
               Operation : DNS.Resolve_Operation :=
                 DNS.Resolve_Using
                   (Set'Access,
                    "cancel.test",
                    Servers,
                    DNS.IPv4_Only,
                    Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (0.05),
                    Attempts       => 1,
                    Retry_Interval => 1.0);
               Raised    : Boolean := False;
            begin
               Operations.Wait_All (Set);
               begin
                  declare
                     Ignored : constant DNS.Address_Array := DNS.Finish (Operation);
                     pragma Unreferenced (Ignored);
                  begin
                     null;
                  end;
               exception
                  when Flyology.IO.Timeout_Error =>
                     Raised := True;
               end;
               OK := OK and Raised;
            end;

            Set_Stage ("scoped already-expired deadline");
            declare
               Set       : aliased Operations.Completion_Set (1);
               Operation : DNS.Resolve_Operation (Set'Access);
               Raised    : Boolean := False;
            begin
               DNS.Resolve_Using
                 ("cancel.test",
                  Servers,
                  DNS.IPv4_Only,
                  Ada.Real_Time.Clock,
                  Attempts       => 1,
                  Retry_Interval => 1.0,
                  Operation      => Operation);
               begin
                  declare
                     Ignored : constant DNS.Address_Array := DNS.Finish (Operation);
                     pragma Unreferenced (Ignored);
                  begin
                     null;
                  end;
               exception
                  when Flyology.IO.Timeout_Error =>
                     Raised := True;
               end;
               OK := OK and then Raised and then Operations.Pending_Count (Set) = 0;
            end;

            Set_Stage ("scoped immediate resolver bypass");
            declare
               Empty     : DNS.Name_Server_Array (1 .. 0);
               Set       : aliased Operations.Completion_Set (1);
               Operation : DNS.Resolve_Operation :=
                 DNS.Resolve_Using (Set'Access, "192.0.2.44", Empty, DNS.IPv4_Only, Retry_Interval => 0.0);
            begin
               declare
                  Values : constant DNS.Address_Array := DNS.Finish (Operation);
               begin
                  OK :=
                    OK
                    and then Values'Length = 1
                    and then Sockets.Image (Values (Values'First)) = "192.0.2.44";
               end;
            end;

            Set_Stage ("scoped child capacity rollback");
            declare
               Set       : aliased Operations.Completion_Set (1);
               Operation : DNS.Resolve_Operation (Set'Access);
               Raised    : Boolean := False;
            begin
               begin
                  DNS.Resolve_Using
                    ("a.test",
                     Servers,
                     DNS.IPv4_Only,
                     Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Operation_Timeout),
                     Attempts       => 1,
                     Retry_Interval => Attempt_Interval,
                     Operation      => Operation);
               exception
                  when Operations.Capacity_Error =>
                     Raised := True;
               end;
               OK := OK and then Raised and then Operations.Pending_Count (Set) = 0;
            end;

            Set_Stage ("scoped parent cancellation");
            declare
               Set    : aliased Operations.Completion_Set (3);
               Parent : DNS_Parent (Set'Access);
            begin
               Start_Parent (Parent, Server);
               delay 0.02;
               Operations.Cancel (Parent);
               Operations.Wait_All (Set);
               OK :=
                 OK and then Operations.Outcome (Parent) = Operations.Cancelled and then not Parent.Failed;
               Operations.Consume (Parent);
            end;

            Set_Stage ("scoped abandonment");
            declare
               Set : aliased Operations.Completion_Set (2);
            begin
               declare
                  Operation : DNS.Resolve_Operation :=
                    DNS.Resolve_Using
                      (Set'Access,
                       "cancel.test",
                       Servers,
                       DNS.IPv4_Only,
                       Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (2.0),
                       Attempts       => 1,
                       Retry_Interval => 1.0);
                  pragma Unreferenced (Operation);
               begin
                  delay 0.02;
               end;
               OK := OK and then Operations.Pending_Count (Set) = 0;
            end;

            Set_Stage ("scoped slot reuse and cleanup");
            declare
               Set       : aliased Operations.Completion_Set (1);
               Operation : DNS.Resolve_Operation (Set'Access);
            begin
               for Attempt in 1 .. 10_000 loop
                  DNS.Resolve_Using ("192.0.2.44", Servers, DNS.IPv4_Only, Operation => Operation);
                  declare
                     Values : constant DNS.Address_Array := DNS.Finish (Operation);
                  begin
                     OK := OK and then Values'Length = 1;
                  end;
               end loop;
               OK := OK and then Operations.Pending_Count (Set) = 0;
            end;
         end Run_Scoped_Checks;
      begin
         Control.Await_Start;
         Control.Get_Address (Server);
         Control.Get_Secondary (Secondary);
         Servers (1) := Server;
         DNS.Clear_Cache;
         Set_Stage ("local and numeric bypass");
         declare
            Local   : constant DNS.Address_Array := DNS.Resolve ("localhost");
            Numeric : constant DNS.Address_Array := DNS.Resolve ("192.0.2.44", DNS.IPv4_Only);
         begin
            OK :=
              OK
              and then Local'Length = 2
              and then Numeric'Length = 1
              and then Sockets.Image (Numeric (Numeric'First)) = "192.0.2.44";
         end;
         Expect ("a.test", "192.0.2.1");
         Expect ("a.test", "192.0.2.1");
         OK := OK and then Control.A_Queries = 1;
         Expect_Many ("many-answers.test", "192.0.2.10");
         Expect_Many ("late-alias.test", "192.0.2.25");
         Expect_Malformed ("bad-surplus.test");
         Expect_Malformed ("bad-surplus-cname.test");
         Expect_Many ("many-tcp.test", "198.51.100.9");
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
         OK :=
           OK and then Control.TCP_Truncated_Queries = 1 and then DNS.Testing.Post_Close_Receive_Waits = 0;
         DNS.Testing.Reset_Receive_Waits;
         Expect_Malformed ("recursive-failure.test");
         OK :=
           OK
           and then Control.Recursive_Failure_Queries = 2
           and then DNS.Testing.Post_Close_Receive_Waits = 0;
         Set_Stage ("server ordering");
         declare
            Ordered  : constant DNS.Name_Server_Array := [Server, Secondary];
            Reversed : constant DNS.Name_Server_Array := [Secondary, Server];
            First    : constant DNS.Address_Array :=
              DNS.Resolve_Using
                ("order.test",
                 Ordered,
                 DNS.IPv4_Only,
                 Timeout        => Operation_Timeout,
                 Attempts       => 1,
                 Retry_Interval => Attempt_Interval);
            Second   : constant DNS.Address_Array :=
              DNS.Resolve_Using
                ("order.test",
                 Reversed,
                 DNS.IPv4_Only,
                 Timeout        => Operation_Timeout,
                 Attempts       => 1,
                 Retry_Interval => Attempt_Interval);
         begin
            OK :=
              OK
              and then Sockets.Image (First (First'First)) = "192.0.2.20"
              and then Sockets.Image (Second (Second'First)) = "192.0.2.10";
         end;
         Set_Stage ("TCP failover");
         declare
            Failover : constant DNS.Name_Server_Array := [Server, Secondary];
            Values   : constant DNS.Address_Array :=
              DNS.Resolve_Using
                ("tcp-silent.test",
                 Failover,
                 DNS.IPv4_Only,
                 Timeout        => Operation_Timeout,
                 Attempts       => 1,
                 Retry_Interval => Attempt_Interval);
         begin
            OK :=
              OK and then Values'Length = 1 and then Sockets.Image (Values (Values'First)) = "198.51.100.77";
         end;
         Set_Stage ("synchronous attempt count boundary");
         declare
            Pair   : constant DNS.Name_Server_Array := [Server, Secondary];
            Raised : Boolean := False;
         begin
            begin
               declare
                  Ignored : constant DNS.Address_Array :=
                    DNS.Resolve_Using
                      ("attempt-boundary.test",
                       Pair,
                       DNS.IPv4_Only,
                       Timeout  => 0.0,
                       Attempts => Positive'Last / 2);
                  pragma Unreferenced (Ignored);
               begin
                  null;
               end;
            exception
               when Flyology.IO.Timeout_Error =>
                  Raised := True;
            end;
            OK := OK and then Raised;
            Raised := False;
            begin
               declare
                  Ignored : constant DNS.Address_Array :=
                    DNS.Resolve_Using
                      ("attempt-boundary.test",
                       Pair,
                       DNS.IPv4_Only,
                       Timeout  => 0.0,
                       Attempts => Positive'Last / 2 + 1);
                  pragma Unreferenced (Ignored);
               begin
                  null;
               end;
            exception
               when DNS.Resolution_Failed =>
                  Raised := True;
            end;
            OK := OK and then Raised;
         end;
         Set_Stage ("dual-family fallback");
         declare
            Values : constant DNS.Address_Array :=
              DNS.Resolve_Using
                ("dual.test",
                 Servers,
                 DNS.Any_Family,
                 Timeout        => Operation_Timeout,
                 Attempts       => 1,
                 Retry_Interval => Attempt_Interval);
         begin
            OK := OK and then Values'Length = 1 and then Sockets.Image (Values (Values'First)) = "192.0.2.66";
         end;
         Set_Stage ("dual-family malformed fallback");
         declare
            Values : constant DNS.Address_Array :=
              DNS.Resolve_Using
                ("dual-malformed.test",
                 Servers,
                 DNS.Any_Family,
                 Timeout        => Operation_Timeout,
                 Attempts       => 1,
                 Retry_Interval => Attempt_Interval);
         begin
            OK := OK and then Values'Length = 1 and then Sockets.Image (Values (Values'First)) = "192.0.2.67";
         end;
         Set_Stage ("resolver configuration");
         declare
            Values : constant DNS.Address_Array :=
              DNS.Resolve
                ("config.test",
                 DNS.IPv4_Only,
                 Timeout            => Operation_Timeout,
                 Configuration_Path => Config_Path (Server));
         begin
            OK := OK and then Values'Length = 1 and then Sockets.Image (Values (Values'First)) = "192.0.2.53";
         end;
         Set_Stage ("IPv6 nameserver scope");
         declare
            Interface_Name : constant String :=
              (if Interface_Index (Interfaces.C.To_C ("lo0")) /= 0 then "lo0" else "lo");
            Index          : constant Interfaces.C.unsigned :=
              Interface_Index (Interfaces.C.To_C (Interface_Name));
         begin
            if Index = 0 then
               raise Program_Error with "no loopback interface for DNS scope test";
            end if;
            Write_Config
              (Server, Suffix => "-scope-name", Server_Text => "[fe80::1%" & Interface_Name & "]:5353");
            Write_Config
              (Server, Suffix => "-scope-bare", Server_Text => "fe80::1%" & Interface_Name);
            Write_Config (Server, Suffix => "-scope-number", Server_Text => "[fe80::1%7]:5353");
            Write_Config (Server, Suffix => "-scope-invalid", Server_Text => "[fe80::1%4294967296]:5353");
            declare
               Named  : constant DNS.Resolver_Configuration :=
                 DNS.Load_Configuration (Config_Path (Server, "-scope-name"));
               Bare   : constant DNS.Resolver_Configuration :=
                 DNS.Load_Configuration (Config_Path (Server, "-scope-bare"));
               Number : constant DNS.Resolver_Configuration :=
                 DNS.Load_Configuration (Config_Path (Server, "-scope-number"));
               First  : constant Sockets.Endpoint := DNS.Testing.Configured_Server (Named, 1);
               Plain  : constant Sockets.Endpoint := DNS.Testing.Configured_Server (Bare, 1);
               Second : constant Sockets.Endpoint := DNS.Testing.Configured_Server (Number, 1);
            begin
               OK :=
                 OK
                 and then First.Family = Sockets.IPv6
                 and then Sockets.Image (First.Address) = "fe80::1"
                 and then First.Port = 5353
                 and then First.Scope = Sockets.Scope_ID (Index)
                 and then Plain.Family = Sockets.IPv6
                 and then Plain.Port = 53
                 and then Plain.Scope = Sockets.Scope_ID (Index)
                 and then Second.Family = Sockets.IPv6
                 and then Second.Scope = 7;
            end;
            begin
               declare
                  Ignored : constant DNS.Resolver_Configuration :=
                    DNS.Load_Configuration (Config_Path (Server, "-scope-invalid"));
                  pragma Unreferenced (Ignored);
               begin
                  OK := False;
               end;
            exception
               when DNS.Resolution_Failed =>
                  null;
            end;
         end;
         Set_Stage ("synchronous ndots candidate order");
         DNS.Clear_Cache;
         declare
            Bare_Before   : constant Natural := Control.NDots_Bare_Queries;
            Search_Before : constant Natural := Control.NDots_Search_Queries;
            Server_Failed : Boolean := False;
         begin
            begin
               declare
                  Ignored : constant DNS.Address_Array :=
                    DNS.Resolve
                      (NDots_Name,
                       DNS.IPv4_Only,
                       Timeout            => Operation_Timeout,
                       Configuration_Path => Config_Path (Server, "-ndots"));
                  pragma Unreferenced (Ignored);
               begin
                  null;
               end;
            exception
               when DNS.Name_Server_Failure =>
                  Server_Failed := True;
            end;
            OK :=
              OK
              and then Server_Failed
              and then Control.NDots_Bare_Queries = Bare_Before + 1
              and then Control.NDots_Search_Queries = Search_Before + 1;
         end;
         Set_Stage ("synchronous ndots mixed failures");
         DNS.Clear_Cache;
         declare
            Search_Before : constant Natural := Control.NDots_Mixed_Search_Queries;
            Server_Failed : Boolean := False;
         begin
            begin
               declare
                  Ignored : constant DNS.Address_Array :=
                    DNS.Resolve
                      (NDots_Mixed_Name,
                       DNS.IPv4_Only,
                       Timeout            => Operation_Timeout,
                       Configuration_Path => Config_Path (Server, "-ndots"));
                  pragma Unreferenced (Ignored);
               begin
                  null;
               end;
            exception
               when DNS.Name_Server_Failure =>
                  Server_Failed := True;
            end;
            OK := OK and then Server_Failed and then Control.NDots_Mixed_Search_Queries = Search_Before + 1;
         end;
         Set_Stage ("synchronous ndots reverse failures");
         DNS.Clear_Cache;
         declare
            Search_Before : constant Natural := Control.NDots_Mixed_Search_Queries;
            Not_Found     : Boolean := False;
         begin
            begin
               declare
                  Ignored : constant DNS.Address_Array :=
                    DNS.Resolve
                      (NDots_Reverse_Name,
                       DNS.IPv4_Only,
                       Timeout            => Operation_Timeout,
                       Configuration_Path => Config_Path (Server, "-ndots"));
                  pragma Unreferenced (Ignored);
               begin
                  null;
               end;
            exception
               when DNS.Name_Not_Found =>
                  Not_Found := True;
            end;
            OK := OK and then Not_Found and then Control.NDots_Mixed_Search_Queries = Search_Before + 1;
         end;
         Set_Stage ("remaining search candidate");
         declare
            Values : constant DNS.Address_Array :=
              DNS.Resolve
                (Search_Name,
                 DNS.IPv4_Only,
                 Timeout            => Operation_Timeout,
                 Configuration_Path => Config_Path (Server, "-remaining"));
         begin
            OK := OK and then Values'Length = 1 and then Sockets.Image (Values (Values'First)) = "192.0.2.54";
         end;
         Set_Stage ("invalid search domains before valid candidate");
         DNS.Clear_Cache;
         declare
            Values : constant DNS.Address_Array :=
              DNS.Resolve
                (Search_Name,
                 DNS.IPv4_Only,
                 Timeout            => Operation_Timeout,
                 Configuration_Path => Config_Path (Server, "-invalid-search"));
         begin
            OK := OK and then Values'Length = 1 and then Sockets.Image (Values (Values'First)) = "192.0.2.54";
         end;
         Set_Stage ("invalid search domains before bare fallback");
         DNS.Clear_Cache;
         declare
            Values : constant DNS.Address_Array :=
              DNS.Resolve
                (Bare_Name,
                 DNS.IPv4_Only,
                 Timeout            => Operation_Timeout,
                 Configuration_Path => Config_Path (Server, "-invalid-only"));
         begin
            OK := OK and then Values'Length = 1 and then Sockets.Image (Values (Values'First)) = "192.0.2.55";
         end;
         Set_Stage ("bare-name fallback");
         declare
            Values : constant DNS.Address_Array :=
              DNS.Resolve
                (Bare_Name,
                 DNS.IPv4_Only,
                 Timeout            => Operation_Timeout,
                 Configuration_Path => Config_Path (Server, "-bare"));
         begin
            OK := OK and then Values'Length = 1 and then Sockets.Image (Values (Values'First)) = "192.0.2.55";
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
               Ignored : constant DNS.Address_Array :=
                 DNS.Resolve_Using ("missing.test", Servers, DNS.IPv4_Only, Timeout => 1.0);
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         exception
            when DNS.Name_Not_Found =>
               null;
            when others =>
               OK := False;
         end;
         begin
            Set_Stage ("negative cache hit");
            declare
               Ignored : constant DNS.Address_Array :=
                 DNS.Resolve_Using ("missing.test", Servers, DNS.IPv4_Only, Timeout => 1.0);
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         exception
            when DNS.Name_Not_Found =>
               null;
            when others =>
               OK := False;
         end;
         OK := OK and then Control.Missing_Queries = 1;
         Run_Scoped_Checks;
         Set_Stage ("cancellation");
         begin
            declare
               Ignored : constant DNS.Address_Array :=
                 DNS.Resolve_Using
                   ("cancel.test",
                    Servers,
                    DNS.IPv4_Only,
                    Timeout    => 5.0,
                    Interrupts => (1 => Flyology.Wake_Sources.Descriptor (Cancel_Source)));
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         exception
            when DNS.Operation_Cancelled =>
               Cancelled := True;
            when others =>
               null;
         end;
         Control.Finished (OK and Cancelled);
      exception
         when Error : others =>
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "DNS "
               & Flyology.Execution_Model'Image (Model)
               & " client failed at "
               & Unbounded.To_String (Stage)
               & ": "
               & Ada.Exceptions.Exception_Information (Error));
            Control.Finished (False);
      end Client;

      Address           : Sockets.Endpoint;
      Secondary_Address : Sockets.Endpoint;
      Stopper           : Sockets.Socket_Type;
      Stop_Data         : constant Streams.Stream_Element_Array :=
        (1 => Character'Pos ('s'),
         2 => Character'Pos ('t'),
         3 => Character'Pos ('o'),
         4 => Character'Pos ('p'));
      Last              : Streams.Stream_Element_Offset;
      Passed            : Boolean := False;
      Client_Finished   : Boolean := False;
   begin
      Flyology.Wake_Sources.Ensure (Cancel_Source);
      Control.Get_Address (Address);
      Control.Get_Secondary (Secondary_Address);
      Write_Config (Address);
      Write_Config (Address, Long_Search & " valid.test", Suffix => "-remaining");
      Write_Config (Address, Long_Search, Suffix => "-bare");
      Write_Config (Address, NDots_Suffix, Suffix => "-ndots");
      Write_Config
        (Address, "bad.. .bad a..b " & Invalid_Label & ".test valid.test", Suffix => "-invalid-search");
      Write_Config (Address, "bad.. .bad a..b " & Invalid_Label & ".test", Suffix => "-invalid-only");
      Control.Begin_Client;
      select
         Control.Wait_Cancel_Or_Finished (Client_Finished, Passed);
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
      Sockets.Create_Socket (Stopper, Sockets.IPv4, Sockets.Socket_Datagram);
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
      if Ada.Directories.Exists (Config_Path (Address, "-ndots")) then
         Ada.Directories.Delete_File (Config_Path (Address, "-ndots"));
      end if;
      if Ada.Directories.Exists (Config_Path (Address, "-invalid-search")) then
         Ada.Directories.Delete_File (Config_Path (Address, "-invalid-search"));
      end if;
      if Ada.Directories.Exists (Config_Path (Address, "-invalid-only")) then
         Ada.Directories.Delete_File (Config_Path (Address, "-invalid-only"));
      end if;
      if Ada.Directories.Exists (Config_Path (Address, "-scope-name")) then
         Ada.Directories.Delete_File (Config_Path (Address, "-scope-name"));
      end if;
      if Ada.Directories.Exists (Config_Path (Address, "-scope-bare")) then
         Ada.Directories.Delete_File (Config_Path (Address, "-scope-bare"));
      end if;
      if Ada.Directories.Exists (Config_Path (Address, "-scope-number")) then
         Ada.Directories.Delete_File (Config_Path (Address, "-scope-number"));
      end if;
      if Ada.Directories.Exists (Config_Path (Address, "-scope-invalid")) then
         Ada.Directories.Delete_File (Config_Path (Address, "-scope-invalid"));
      end if;
      return Passed;
   end Run;

begin
   declare
      Native_Passed      : constant Boolean := Run (Flyology.Native_Task);
      Lightweight_Passed : constant Boolean := Run (Flyology.Lightweight_Task);
   begin
      pragma Assert (Native_Passed, "native DNS lifecycle checks failed");
      pragma Assert (Lightweight_Passed, "lightweight DNS lifecycle checks failed");
   end;
end DNS_Smoke;
