with Ada.Directories;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology;
with Flyology.IO;
with Flyology.IO.DNS;
with Flyology.IO.Files;
with Flyology.IO.Sockets;

--  Resolver resilience against hostile or failing name servers. Every check
--  bounds resolution latency or the observed exception category, so a
--  regression shows up as a failed assertion rather than a stalled process.

procedure DNS_Resilience_Smoke is
   package DNS renames Flyology.IO.DNS;
   package Sockets renames Flyology.IO.Sockets;
   package Streams renames Ada.Streams;

   use type Ada.Real_Time.Time;
   use type Streams.Stream_Element;
   use type Streams.Stream_Element_Offset;
   use type Flyology.IO.Files.File_Descriptor;

   Flood_Seconds       : constant Duration := 4.0;
   --  A resolver that ignores its deadline stalls for the whole flood, so the
   --  accepted latency must stay well below it.
   Flood_Latency_Limit : constant Duration := 2.0;

   function Run (Model : Flyology.Execution_Model) return Boolean is

      protected Control is
         procedure Ready (Address : Sockets.Endpoint);
         procedure Failed;
         entry Get_Address (Address : out Sockets.Endpoint);
         procedure Begin_Client;
         entry Await_Start;
         procedure Secondary_Ready (Address : Sockets.Endpoint);
         procedure Secondary_Failed;
         entry Get_Secondary (Address : out Sockets.Endpoint);
         procedure Rotate_Query;
         function Rotate_Queries return Natural;
         procedure Stop_Flood;
         function Flood_Stopped return Boolean;
         procedure Finished (Passed : Boolean);
         entry Wait_Finished (Passed : out Boolean);
      private
         Is_Ready               : Boolean := False;
         Setup_Failed           : Boolean := False;
         Server                 : Sockets.Endpoint;
         Secondary              : Sockets.Endpoint;
         Secondary_Is_Ready     : Boolean := False;
         Secondary_Setup_Failed : Boolean := False;
         Rotate_Count           : Natural := 0;
         Can_Start              : Boolean := False;
         Flood_Halted           : Boolean := False;
         Is_Finished            : Boolean := False;
         All_OK                 : Boolean := False;
      end Control;

      protected body Control is
         procedure Ready (Address : Sockets.Endpoint) is
         begin
            Server := Address;
            Is_Ready := True;
         end Ready;
         procedure Failed is
         begin
            Setup_Failed := True;
         end Failed;
         entry Get_Address (Address : out Sockets.Endpoint) when Is_Ready or else Setup_Failed is
         begin
            if Setup_Failed then
               raise Program_Error with "resilience DNS server setup failed";
            end if;
            Address := Server;
         end Get_Address;
         procedure Secondary_Ready (Address : Sockets.Endpoint) is
         begin
            Secondary := Address;
            Secondary_Is_Ready := True;
         end Secondary_Ready;
         procedure Secondary_Failed is
         begin
            Secondary_Setup_Failed := True;
         end Secondary_Failed;
         entry Get_Secondary (Address : out Sockets.Endpoint)
           when Secondary_Is_Ready or else Secondary_Setup_Failed
         is
         begin
            if Secondary_Setup_Failed then
               raise Program_Error with "secondary DNS server setup failed";
            end if;
            Address := Secondary;
         end Get_Secondary;
         procedure Rotate_Query is
         begin
            Rotate_Count := Rotate_Count + 1;
         end Rotate_Query;
         function Rotate_Queries return Natural
         is (Rotate_Count);
         procedure Begin_Client is
         begin
            Can_Start := True;
         end Begin_Client;
         entry Await_Start when Can_Start is
         begin
            null;
         end Await_Start;
         procedure Stop_Flood is
         begin
            Flood_Halted := True;
         end Stop_Flood;
         function Flood_Stopped return Boolean
         is (Flood_Halted);
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

      function Config_Path (Server : Sockets.Endpoint; Suffix : String := "") return String
      is ("/tmp/flyology-dns-resilience-"
          & Ada.Strings.Fixed.Trim (Sockets.Port'Image (Server.Port), Ada.Strings.Both)
          & Suffix
          & ".conf");

      procedure Write_Config (Server : Sockets.Endpoint; Text : String; Suffix : String := "") is
         File : Flyology.IO.Files.File_Descriptor := Flyology.IO.Files.Invalid_File;
         Data : Streams.Stream_Element_Array (1 .. Streams.Stream_Element_Offset (Text'Length));
         Last : Streams.Stream_Element_Offset;
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

      procedure Close_Quietly (Socket : in out Sockets.Socket_Type) is
      begin
         if Sockets.Is_Open (Socket) then
            Sockets.Close_Socket (Socket);
         end if;
      exception
         when others =>
            null;
      end Close_Quietly;

      task Hostile_Server;

      task body Hostile_Server is
         UDP   : Sockets.Socket_Type;
         Peer  : Sockets.Endpoint;
         Bound : Sockets.Endpoint;
         Query : Streams.Stream_Element_Array (1 .. 512);
         Last  : Streams.Stream_Element_Offset;

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

         --  Stream datagrams that always fail validation. Each one keeps the
         --  resolver socket readable without ever committing an attempt.
         procedure Flood is
            Garbage : constant Streams.Stream_Element_Array (1 .. 12) := (others => 16#5A#);
            Stop_At : constant Ada.Real_Time.Time :=
              Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Flood_Seconds);
            Sent    : Streams.Stream_Element_Offset;
         begin
            while Ada.Real_Time.Clock < Stop_At and then not Control.Flood_Stopped loop
               for Burst in 1 .. 64 loop
                  Sockets.Send_Socket (UDP, Garbage, Sent, Peer);
               end loop;
            end loop;
         exception
            when Sockets.Socket_Error =>
               null;
         end Flood;

         function Question_End return Streams.Stream_Element_Offset is
            Position : Streams.Stream_Element_Offset := 13;
         begin
            while Query (Position) /= 0 loop
               Position := Position + 1 + Streams.Stream_Element_Offset (Query (Position));
            end loop;
            return Position + 4;
         end Question_End;

         --  Echo the question with the requested response code and no answer
         --  records. Code 3 is NXDOMAIN and code 2 is SERVFAIL.
         procedure Send_Status (Response_Code : Streams.Stream_Element) is
            Response      : Streams.Stream_Element_Array (1 .. 512) := (others => 0);
            Question_Last : constant Streams.Stream_Element_Offset := Question_End;
            Sent          : Streams.Stream_Element_Offset;
         begin
            Response (1 .. Question_Last) := Query (1 .. Question_Last);
            Response (3) := 16#81#;
            Response (4) := 16#80# + Response_Code;
            Response (7) := 0;
            Response (8) := 0;
            Sockets.Send_Socket (UDP, Response (1 .. Question_Last), Sent, Peer);
         end Send_Status;

         procedure Send_A (Address_Image : String) is
            Response      : Streams.Stream_Element_Array (1 .. 512) := (others => 0);
            Question_Last : constant Streams.Stream_Element_Offset := Question_End;
            Position      : Streams.Stream_Element_Offset;
            Sent          : Streams.Stream_Element_Offset;
            Address       : constant Sockets.IP_Address := Sockets.Parse_IP_Address (Address_Image);
         begin
            Response (1 .. Question_Last) := Query (1 .. Question_Last);
            Response (3) := 16#81#;
            Response (4) := 16#80#;
            Response (7) := 0;
            Response (8) := 1;
            Position := Question_Last + 1;
            Response (Position) := 16#C0#;
            Response (Position + 1) := 12;
            Response (Position + 2) := 0;
            Response (Position + 3) := 1;
            Response (Position + 4) := 0;
            Response (Position + 5) := 1;
            Response (Position + 6 .. Position + 9) := (others => 0);
            Response (Position + 9) := 60;
            Response (Position + 10) := 0;
            Response (Position + 11) := 4;
            Position := Position + 12;
            for Index in Address.V4'Range loop
               Response (Position) := Streams.Stream_Element (Address.V4 (Index));
               Position := Position + 1;
            end loop;
            Sockets.Send_Socket (UDP, Response (1 .. Position - 1), Sent, Peer);
         end Send_A;

         --  Answer with an alias whose first wire label begins with a dot
         --  byte. The label is legal wire format, so a resolver that stores
         --  decoded names as dotted text cannot re-encode it.
         procedure Send_Dotted_CNAME is
            Response      : Streams.Stream_Element_Array (1 .. 512) := (others => 0);
            Question_Last : constant Streams.Stream_Element_Offset := Question_End;
            Target        : constant Streams.Stream_Element_Array :=
              (4,
               Character'Pos ('.'),
               Character'Pos ('b'),
               Character'Pos ('a'),
               Character'Pos ('d'),
               4,
               Character'Pos ('t'),
               Character'Pos ('e'),
               Character'Pos ('s'),
               Character'Pos ('t'),
               0);
            Position      : Streams.Stream_Element_Offset;
            Sent          : Streams.Stream_Element_Offset;
         begin
            Response (1 .. Question_Last) := Query (1 .. Question_Last);
            Response (3) := 16#81#;
            Response (4) := 16#80#;
            Response (7) := 0;
            Response (8) := 1;
            Position := Question_Last + 1;
            Response (Position) := 16#C0#;
            Response (Position + 1) := 12;
            Response (Position + 2) := 0;
            Response (Position + 3) := 5;
            Response (Position + 4) := 0;
            Response (Position + 5) := 1;
            Response (Position + 6 .. Position + 9) := (others => 0);
            Response (Position + 9) := 60;
            Response (Position + 10) := 0;
            Response (Position + 11) := Streams.Stream_Element (Target'Length);
            Position := Position + 12;
            Response (Position .. Position + Target'Length - 1) := Target;
            Position := Position + Target'Length;
            Sockets.Send_Socket (UDP, Response (1 .. Position - 1), Sent, Peer);
         end Send_Dotted_CNAME;
      begin
         Sockets.Create_Socket (UDP, Sockets.IPv4, Sockets.Socket_Datagram);
         Sockets.Bind_Socket (UDP, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
         Bound := Sockets.Get_Socket_Name (UDP);
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
               if Name = "flood.test" then
                  Flood;
               elsif Name = "rotate.test" then
                  Control.Rotate_Query;
                  Send_A ("192.0.2.21");
               elsif Name = "dotty.test" then
                  Send_Dotted_CNAME;
               elsif Name = "walk.lab.test" then
                  Send_A ("192.0.2.13");
               elsif Name = "walk.corp.test"
                 or else Name = "reject.corp.test"
                 or else Name = "reject.lab.test"
                 or else Name = "reject"
               then
                  Send_Status (2);
               else
                  Send_Status (3);
               end if;
            end;
         end loop;
         Sockets.Close_Socket (UDP);
      exception
         when Error : others =>
            Close_Quietly (UDP);
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "hostile DNS test server failed: " & Ada.Exceptions.Exception_Information (Error));
            Control.Failed;
      end Hostile_Server;

      --  A second numeric endpoint so a rotated server list can be observed.
      --  Both endpoints answer rotate.test identically and count the query,
      --  so the cache must serve the second call whichever one it rotates to.
      task Rotation_Server;

      task body Rotation_Server is
         UDP      : Sockets.Socket_Type;
         Peer     : Sockets.Endpoint;
         Bound    : Sockets.Endpoint;
         Query    : Streams.Stream_Element_Array (1 .. 512);
         Response : Streams.Stream_Element_Array (1 .. 512);
         Last     : Streams.Stream_Element_Offset;

         procedure Answer is
            Question_Last : Streams.Stream_Element_Offset := 13;
            Position      : Streams.Stream_Element_Offset;
            Sent          : Streams.Stream_Element_Offset;
            Address       : constant Sockets.IP_Address := Sockets.Parse_IP_Address ("192.0.2.21");
         begin
            while Query (Question_Last) /= 0 loop
               Question_Last := Question_Last + 1 + Streams.Stream_Element_Offset (Query (Question_Last));
            end loop;
            Question_Last := Question_Last + 4;
            Response := (others => 0);
            Response (1 .. Question_Last) := Query (1 .. Question_Last);
            Response (3) := 16#81#;
            Response (4) := 16#80#;
            Response (7) := 0;
            Response (8) := 1;
            Position := Question_Last + 1;
            Response (Position) := 16#C0#;
            Response (Position + 1) := 12;
            Response (Position + 3) := 1;
            Response (Position + 5) := 1;
            Response (Position + 9) := 60;
            Response (Position + 11) := 4;
            Position := Position + 12;
            for Index in Address.V4'Range loop
               Response (Position) := Streams.Stream_Element (Address.V4 (Index));
               Position := Position + 1;
            end loop;
            Sockets.Send_Socket (UDP, Response (1 .. Position - 1), Sent, Peer);
         end Answer;
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
            Control.Rotate_Query;
            Answer;
         end loop;
         Sockets.Close_Socket (UDP);
      exception
         when Error : others =>
            Close_Quietly (UDP);
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "rotation DNS test server failed: " & Ada.Exceptions.Exception_Information (Error));
            Control.Secondary_Failed;
      end Rotation_Server;

      task Client is
         pragma Task_Info (Model);
      end Client;

      task body Client is
         Server  : Sockets.Endpoint;
         Servers : DNS.Name_Server_Array (1 .. 1);
         OK      : Boolean := True;

         --  A hostile server that keeps the socket readable must not extend
         --  resolution past the caller's deadline.
         procedure Check_Flood_Deadline is
            Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
            Raised  : Boolean := False;
            Elapsed : Duration;
         begin
            begin
               declare
                  Ignored : constant DNS.Address_Array :=
                    DNS.Resolve_Using
                      ("flood.test",
                       Servers,
                       DNS.IPv4_Only,
                       Timeout        => 0.5,
                       Attempts       => 1,
                       Retry_Interval => 0.5);
                  pragma Unreferenced (Ignored);
               begin
                  null;
               end;
            exception
               when DNS.Malformed_Response | Flyology.IO.Timeout_Error =>
                  Raised := True;
               when Error : others =>
                  Ada.Text_IO.Put_Line
                    (Ada.Text_IO.Standard_Error,
                     "flood resolution raised an unexpected exception: "
                     & Ada.Exceptions.Exception_Name (Error));
            end;
            Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
            Control.Stop_Flood;
            if not Raised or else Elapsed > Flood_Latency_Limit then
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "flood resolution ignored its deadline: raised="
                  & Raised'Image
                  & " elapsed="
                  & Elapsed'Image);
               OK := False;
            end if;
         end Check_Flood_Deadline;

         --  A server-failure response code for one search candidate must not
         --  cancel the remaining candidates.
         procedure Check_Search_Walk_Survives_Failure is
         begin
            declare
               Values : constant DNS.Address_Array :=
                 DNS.Resolve
                   ("walk", DNS.IPv4_Only, Timeout => 3.0, Configuration_Path => Config_Path (Server));
            begin
               if Values'Length /= 1 or else Sockets.Image (Values (Values'First)) /= "192.0.2.13" then
                  Ada.Text_IO.Put_Line
                    (Ada.Text_IO.Standard_Error, "search walk returned an unexpected address");
                  OK := False;
               end if;
            end;
         exception
            when Error : others =>
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "server failure aborted the search walk: " & Ada.Exceptions.Exception_Name (Error));
               OK := False;
         end Check_Search_Walk_Survives_Failure;

         --  When every candidate ends in a server failure the deadline is
         --  still unspent, so the outcome must not be reported as a timeout.
         procedure Check_Server_Failure_Category is
            Started  : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
            Reported : Boolean := False;
            Elapsed  : Duration;
         begin
            begin
               declare
                  Ignored : constant DNS.Address_Array :=
                    DNS.Resolve
                      ("reject", DNS.IPv4_Only, Timeout => 3.0, Configuration_Path => Config_Path (Server));
                  pragma Unreferenced (Ignored);
               begin
                  null;
               end;
            exception
               when DNS.Name_Server_Failure =>
                  Reported := True;
               when Error : others =>
                  Ada.Text_IO.Put_Line
                    (Ada.Text_IO.Standard_Error,
                     "rejected resolution raised " & Ada.Exceptions.Exception_Name (Error));
            end;
            Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
            if not Reported or else Elapsed > 1.0 then
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "server failure was misreported: reported=" & Reported'Image & " elapsed=" & Elapsed'Image);
               OK := False;
            end if;
         end Check_Server_Failure_Category;

         --  A hostile alias target must be discarded like any other unusable
         --  response instead of reporting the caller's own input as invalid.
         procedure Check_Hostile_Alias_Is_Discarded is
            Reported : Boolean := False;
         begin
            begin
               declare
                  Ignored : constant DNS.Address_Array :=
                    DNS.Resolve_Using
                      ("dotty.test",
                       Servers,
                       DNS.IPv4_Only,
                       Timeout        => 1.0,
                       Attempts       => 1,
                       Retry_Interval => 0.2);
                  pragma Unreferenced (Ignored);
               begin
                  null;
               end;
            exception
               when DNS.Malformed_Response =>
                  Reported := True;
               when Error : others =>
                  Ada.Text_IO.Put_Line
                    (Ada.Text_IO.Standard_Error,
                     "hostile alias raised " & Ada.Exceptions.Exception_Name (Error));
            end;
            if not Reported then
               OK := False;
            end if;
         end Check_Hostile_Alias_Is_Discarded;

         --  Rotation reorders the endpoints tried first. It must not split
         --  one host into a separate cache entry per rotation offset.
         procedure Check_Rotation_Shares_Cache is
            Expected : constant String := "192.0.2.21";
         begin
            for Call in 1 .. 2 loop
               declare
                  Values : constant DNS.Address_Array :=
                    DNS.Resolve
                      ("rotate.test",
                       DNS.IPv4_Only,
                       Timeout            => 3.0,
                       Configuration_Path => Config_Path (Server, "-rotate"));
               begin
                  if Values'Length /= 1 or else Sockets.Image (Values (Values'First)) /= Expected then
                     Ada.Text_IO.Put_Line
                       (Ada.Text_IO.Standard_Error, "rotated resolution returned an unexpected address");
                     OK := False;
                  end if;
               end;
            end loop;
            if Control.Rotate_Queries /= 1 then
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "rotation fragmented the DNS cache: queries=" & Control.Rotate_Queries'Image);
               OK := False;
            end if;
         exception
            when Error : others =>
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "rotated resolution raised " & Ada.Exceptions.Exception_Name (Error));
               OK := False;
         end Check_Rotation_Shares_Cache;
      begin
         Control.Await_Start;
         Control.Get_Address (Server);
         Servers (1) := Server;
         DNS.Clear_Cache;
         Check_Flood_Deadline;
         Check_Search_Walk_Survives_Failure;
         Check_Server_Failure_Category;
         Check_Hostile_Alias_Is_Discarded;
         Check_Rotation_Shares_Cache;
         Control.Finished (OK);
      exception
         when Error : others =>
            Control.Stop_Flood;
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "resilience DNS client failed: " & Ada.Exceptions.Exception_Information (Error));
            Control.Finished (False);
      end Client;

      Address   : Sockets.Endpoint;
      Secondary : Sockets.Endpoint;
      Stopper   : Sockets.Socket_Type;
      Stop_Data : constant Streams.Stream_Element_Array :=
        (1 => Character'Pos ('s'),
         2 => Character'Pos ('t'),
         3 => Character'Pos ('o'),
         4 => Character'Pos ('p'));
      Last      : Streams.Stream_Element_Offset;
      Passed    : Boolean;
   begin
      Control.Get_Address (Address);
      Control.Get_Secondary (Secondary);
      Write_Config
        (Address,
         "nameserver "
         & Sockets.Image (Address)
         & ASCII.LF
         & "search corp.test lab.test"
         & ASCII.LF
         & "options attempts:1 timeout:1"
         & ASCII.LF);
      Write_Config
        (Address,
         "nameserver "
         & Sockets.Image (Address)
         & ASCII.LF
         & "nameserver "
         & Sockets.Image (Secondary)
         & ASCII.LF
         & "options rotate attempts:1 timeout:1"
         & ASCII.LF,
         Suffix => "-rotate");
      Control.Begin_Client;
      select
         Control.Wait_Finished (Passed);
      or
         delay 30.0;
         Passed := False;
      end select;
      Sockets.Create_Socket (Stopper, Sockets.IPv4, Sockets.Socket_Datagram);
      Sockets.Send_Socket (Stopper, Stop_Data, Last, Address);
      Sockets.Send_Socket (Stopper, Stop_Data, Last, Secondary);
      Sockets.Close_Socket (Stopper);
      if Ada.Directories.Exists (Config_Path (Address)) then
         Ada.Directories.Delete_File (Config_Path (Address));
      end if;
      if Ada.Directories.Exists (Config_Path (Address, "-rotate")) then
         Ada.Directories.Delete_File (Config_Path (Address, "-rotate"));
      end if;
      return Passed;
   end Run;

begin
   declare
      Native_Passed      : constant Boolean := Run (Flyology.Native_Task);
      Lightweight_Passed : constant Boolean := Run (Flyology.Lightweight_Task);
   begin
      pragma Assert (Native_Passed, "native DNS resilience checks failed");
      pragma Assert (Lightweight_Passed, "lightweight DNS resilience checks failed");
   end;
   Ada.Text_IO.Put_Line ("DNS resilience: checks passed");
end DNS_Resilience_Smoke;
