with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Text_IO;
with Flyology;
with Flyology.IO;
with Flyology.IO.DNS;
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

   Flood_Seconds : constant Duration := 4.0;
   --  A resolver that ignores its deadline stalls for the whole flood, so the
   --  accepted latency must stay well below it.
   Flood_Latency_Limit : constant Duration := 2.0;

   function Run (Model : Flyology.Execution_Model) return Boolean is

      protected Control is
         procedure Ready (Address : Sockets.Endpoint);
         procedure Failed;
         entry Get_Address (Address : out Sockets.Endpoint);
         procedure Stop_Flood;
         function Flood_Stopped return Boolean;
         procedure Finished (Passed : Boolean);
         entry Wait_Finished (Passed : out Boolean);
      private
         Is_Ready    : Boolean := False;
         Setup_Failed : Boolean := False;
         Server      : Sockets.Endpoint;
         Flood_Halted : Boolean := False;
         Is_Finished : Boolean := False;
         All_OK      : Boolean := False;
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
         entry Get_Address (Address : out Sockets.Endpoint)
           when Is_Ready or else Setup_Failed is
         begin
            if Setup_Failed then
               raise Program_Error with "resilience DNS server setup failed";
            end if;
            Address := Server;
         end Get_Address;
         procedure Stop_Flood is
         begin
            Flood_Halted := True;
         end Stop_Flood;
         function Flood_Stopped return Boolean is (Flood_Halted);
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

      procedure Close_Quietly (Socket : in out Sockets.Socket_Type) is
      begin
         if Sockets.Is_Open (Socket) then
            Sockets.Close_Socket (Socket);
         end if;
      exception
         when others => null;
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
                  Result (Length) := Character'Val
                    (Query
                       (Position + Streams.Stream_Element_Offset (Offset)));
               end loop;
               Position :=
                 Position + Streams.Stream_Element_Offset (Label_Length);
            end loop;
            return Result (1 .. Length);
         end Query_Name;

         --  Stream datagrams that always fail validation. Each one keeps the
         --  resolver socket readable without ever committing an attempt.
         procedure Flood is
            Garbage : constant Streams.Stream_Element_Array (1 .. 12) :=
              (others => 16#5A#);
            Stop_At : constant Ada.Real_Time.Time :=
              Ada.Real_Time.Clock
              + Ada.Real_Time.To_Time_Span (Flood_Seconds);
            Sent    : Streams.Stream_Element_Offset;
         begin
            while Ada.Real_Time.Clock < Stop_At
              and then not Control.Flood_Stopped
            loop
               for Burst in 1 .. 64 loop
                  Sockets.Send_Socket (UDP, Garbage, Sent, Peer);
               end loop;
            end loop;
         exception
            when Sockets.Socket_Error => null;
         end Flood;

         procedure Send_NXDOMAIN is
            Response      : Streams.Stream_Element_Array (1 .. 512) :=
              (others => 0);
            Question_Last : Streams.Stream_Element_Offset := 13;
            Sent          : Streams.Stream_Element_Offset;
         begin
            while Query (Question_Last) /= 0 loop
               Question_Last := Question_Last
                 + 1 + Streams.Stream_Element_Offset (Query (Question_Last));
            end loop;
            Question_Last := Question_Last + 4;
            Response (1 .. Question_Last) := Query (1 .. Question_Last);
            Response (3) := 16#81#;
            Response (4) := 16#83#;
            Response (7) := 0;
            Response (8) := 0;
            Sockets.Send_Socket
              (UDP, Response (1 .. Question_Last), Sent, Peer);
         end Send_NXDOMAIN;
      begin
         Sockets.Create_Socket (UDP, Sockets.IPv4, Sockets.Socket_Datagram);
         Sockets.Bind_Socket
           (UDP, Sockets.Network_Endpoint
              (Sockets.Loopback_IPv4, Sockets.Any_Port));
         Bound := Sockets.Get_Socket_Name (UDP);
         Control.Ready (Bound);
         loop
            Sockets.Receive_Socket (UDP, Query, Last, Peer);
            exit when Last = 4
              and then Character'Val (Query (1)) = 's'
              and then Character'Val (Query (2)) = 't'
              and then Character'Val (Query (3)) = 'o'
              and then Character'Val (Query (4)) = 'p';
            if Query_Name = "flood.test" then
               Flood;
            else
               Send_NXDOMAIN;
            end if;
         end loop;
         Sockets.Close_Socket (UDP);
      exception
         when Error : others =>
            Close_Quietly (UDP);
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "hostile DNS test server failed: "
               & Ada.Exceptions.Exception_Information (Error));
            Control.Failed;
      end Hostile_Server;

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
                  Ignored : constant DNS.Address_Array := DNS.Resolve_Using
                    ("flood.test", Servers, DNS.IPv4_Only, Timeout => 0.5,
                     Attempts => 1, Retry_Interval => 0.5);
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
            Elapsed :=
              Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
            Control.Stop_Flood;
            if not Raised or else Elapsed > Flood_Latency_Limit then
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "flood resolution ignored its deadline: raised="
                  & Raised'Image & " elapsed=" & Elapsed'Image);
               OK := False;
            end if;
         end Check_Flood_Deadline;
      begin
         Control.Get_Address (Server);
         Servers (1) := Server;
         DNS.Clear_Cache;
         Check_Flood_Deadline;
         Control.Finished (OK);
      exception
         when Error : others =>
            Control.Stop_Flood;
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "resilience DNS client failed: "
               & Ada.Exceptions.Exception_Information (Error));
            Control.Finished (False);
      end Client;

      Address   : Sockets.Endpoint;
      Stopper   : Sockets.Socket_Type;
      Stop_Data : constant Streams.Stream_Element_Array :=
        (1 => Character'Pos ('s'), 2 => Character'Pos ('t'),
         3 => Character'Pos ('o'), 4 => Character'Pos ('p'));
      Last      : Streams.Stream_Element_Offset;
      Passed    : Boolean;
   begin
      Control.Get_Address (Address);
      select
         Control.Wait_Finished (Passed);
      or
         delay 30.0;
         Passed := False;
      end select;
      Sockets.Create_Socket (Stopper, Sockets.IPv4, Sockets.Socket_Datagram);
      Sockets.Send_Socket (Stopper, Stop_Data, Last, Address);
      Sockets.Close_Socket (Stopper);
      return Passed;
   end Run;

begin
   declare
      Native_Passed : constant Boolean := Run (Flyology.Native_Task);
      Lightweight_Passed : constant Boolean :=
        Run (Flyology.Lightweight_Task);
   begin
      pragma Assert
        (Native_Passed, "native DNS resilience checks failed");
      pragma Assert
        (Lightweight_Passed, "lightweight DNS resilience checks failed");
   end;
   Ada.Text_IO.Put_Line ("DNS resilience: checks passed");
end DNS_Resilience_Smoke;
