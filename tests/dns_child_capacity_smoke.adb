with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Text_IO;
with Flyology;
with Flyology.IO.DNS;
with Flyology.IO.Sockets;
with Flyology.IO.Timers;
with Flyology.Operations;
with Interfaces.C;

procedure DNS_Child_Capacity_Smoke is
   package DNS renames Flyology.IO.DNS;
   package Operations renames Flyology.Operations;
   package Sockets renames Flyology.IO.Sockets;
   package Streams renames Ada.Streams;
   package Timers renames Flyology.IO.Timers;

   use type Ada.Real_Time.Time;
   use type Operations.Terminal_Outcome;
   use type Streams.Stream_Element;
   use type Streams.Stream_Element_Offset;
   use type Interfaces.C.int;

   function Open_FD_Count return Interfaces.C.int;
   pragma Import (C, Open_FD_Count, "flyology_test_open_fd_count");

   protected Result is
      procedure Set (Passed : Boolean);
      entry Wait (Passed : out Boolean);
   private
      Ready : Boolean := False;
      Value : Boolean := False;
   end Result;

   protected body Result is
      procedure Set (Passed : Boolean) is
      begin
         Value := Passed;
         Ready := True;
      end Set;

      entry Wait (Passed : out Boolean) when Ready is
      begin
         Passed := Value;
         Ready := False;
      end Wait;
   end Result;

   task type Runner (Model : Flyology.Execution_Model) is
      pragma Task_Info (Model);
   end Runner;

   task body Runner is
      Passed : Boolean := False;
   begin
      declare
         task Server is
            entry Get_Address (Address : out Sockets.Endpoint);
            entry Stop;
         end Server;

         task body Server is
            Socket        : Sockets.Socket_Type;
            Bound         : Sockets.Endpoint;
            Peer          : Sockets.Endpoint;
            Query         : Streams.Stream_Element_Array (1 .. 512);
            Response      : Streams.Stream_Element_Array (1 .. 512) :=
              (others => 0);
            Last          : Streams.Stream_Element_Offset;
            Sent_Last     : Streams.Stream_Element_Offset;
            Question_Last : Streams.Stream_Element_Offset := 13;
            Position      : Streams.Stream_Element_Offset := 3;

            procedure Put_U16 (Value : Natural) is
            begin
               Response (Position) :=
                 Streams.Stream_Element ((Value / 256) mod 256);
               Response (Position + 1) :=
                 Streams.Stream_Element (Value mod 256);
               Position := Position + 2;
            end Put_U16;
         begin
            Sockets.Create_Socket
              (Socket, Sockets.IPv4, Sockets.Socket_Datagram);
            Sockets.Bind_Socket
              (Socket,
               Sockets.Network_Endpoint
                 (Sockets.Loopback_IPv4, Sockets.Any_Port));
            Bound := Sockets.Get_Socket_Name (Socket);
            accept Get_Address (Address : out Sockets.Endpoint) do
               Address := Bound;
            end Get_Address;

            Sockets.Receive_Socket (Socket, Query, Last, Peer);
            while Query (Question_Last) /= 0 loop
               Question_Last :=
                 Question_Last
                 + 1
                 + Streams.Stream_Element_Offset (Query (Question_Last));
            end loop;
            Question_Last := Question_Last + 4;
            Response (1 .. 2) := Query (1 .. 2);
            Put_U16 (16#8183#);
            Put_U16 (1);
            Put_U16 (0);
            Put_U16 (0);
            Put_U16 (0);
            Response (Position .. Position + Question_Last - 13) :=
              Query (13 .. Question_Last);
            Position := Position + Question_Last - 12;
            Sockets.Send_Socket
              (Socket, Response (1 .. Position - 1), Sent_Last, Peer);
            accept Stop;
            Sockets.Close_Socket (Socket);
         exception
            when Error : others =>
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "DNS child capacity server: "
                  & Ada.Exceptions.Exception_Information (Error));
         end Server;

         Address     : Sockets.Endpoint;
         Servers     : DNS.Name_Server_Array (1 .. 1);
         Before      : Interfaces.C.int;
         Server_Done : Boolean := False;
         Cached      : Boolean := False;
      begin
         select
            Server.Get_Address (Address);
         or
            delay 2.0;
            raise Program_Error with "DNS capacity server did not start";
         end select;
         Servers (1) := Address;

         DNS.Clear_Cache;
         begin
            declare
               Ignored : constant DNS.Address_Array :=
                 DNS.Resolve_Using
                   ("capacity.test",
                    Servers,
                    DNS.IPv6_Only,
                    Timeout        => 1.0,
                    Attempts       => 1,
                    Retry_Interval => 0.5);
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         exception
            when DNS.Name_Not_Found =>
               Cached := True;
         end;
         Server_Done := True;
         if not Cached then
            raise Program_Error
              with "DNS capacity setup did not retain a negative AAAA result";
         end if;
         Before := Open_FD_Count;

         declare
            Set              : aliased Operations.Completion_Set (2);
            Resolve          : DNS.Resolve_Operation :=
              DNS.Resolve_Using
                (Set'Access,
                 "capacity.test",
                 Servers,
                 DNS.Any_Family,
                 Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (2.0),
                 Attempts       => 1,
                 Retry_Interval => 1.0);
            Filler           : Timers.Timer_Operation :=
              Timers.Sleep_For (Set'Access, 1.0);
            Batch            : Operations.Completion_Batch (Set.Capacity);
            Capacity_Escaped : Boolean := False;
            Set_Strained     : Boolean := False;
            Descriptor_Open  : Boolean := False;
            Failed_Retained  : Boolean := False;
         begin
            begin
               Operations.Wait_Some (Set, Batch);
            exception
               when Operations.Capacity_Error =>
                  Capacity_Escaped := True;
                  Descriptor_Open := Open_FD_Count = Before + 1;
            end;

            if Capacity_Escaped then
               begin
                  Operations.Wait_Some (Set, Batch);
               exception
                  when Operations.Operation_Error =>
                     Set_Strained := True;
               end;
               raise Program_Error
                 with
                   "Capacity_Error escaped="
                   & Boolean'Image (Capacity_Escaped)
                   & ", root pending="
                   & Boolean'Image (Operations.Is_Active (Resolve))
                   & ", later wait rejected="
                   & Boolean'Image (Set_Strained)
                   & ", DNS descriptor retained="
                   & Boolean'Image (Descriptor_Open);
            end if;

            if not Operations.Is_Terminal (Resolve)
              or else Operations.Outcome (Resolve) /= Operations.Failed
              or else Open_FD_Count /= Before
            then
               raise Program_Error
                 with
                   "capacity failure did not terminalize and close DNS resolution";
            end if;

            begin
               declare
                  Ignored : constant DNS.Address_Array := DNS.Finish (Resolve);
                  pragma Unreferenced (Ignored);
               begin
                  null;
               end;
            exception
               when DNS.Resolution_Failed =>
                  Failed_Retained := True;
            end;
            if not Failed_Retained then
               raise Program_Error
                 with "DNS Finish did not retain the capacity failure";
            end if;

            Operations.Cancel (Filler);
            begin
               Timers.Finish (Filler);
            exception
               when Operations.Operation_Cancelled =>
                  null;
            end;
            Passed := True;
         end;

         if Server_Done then
            Server.Stop;
         end if;
      exception
         when Error : others =>
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "DNS child capacity "
               & Flyology.Execution_Model'Image (Model)
               & ": "
               & Ada.Exceptions.Exception_Information (Error));
            if Server_Done then
               Server.Stop;
            end if;
      end;
      Result.Set (Passed);
   exception
      when Error : others =>
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "DNS child capacity runner: "
            & Ada.Exceptions.Exception_Information (Error));
         Result.Set (False);
   end Runner;

   type Runner_Access is access Runner;
   Native      : Runner_Access;
   Lightweight : Runner_Access;
   pragma Unreferenced (Native, Lightweight);
   Passed      : Boolean;
begin
   Native := new Runner (Flyology.Native_Task);
   Result.Wait (Passed);
   pragma Assert (Passed, "native DNS child capacity regression failed");

   Lightweight := new Runner (Flyology.Lightweight_Task);
   Result.Wait (Passed);
   pragma Assert (Passed, "lightweight DNS child capacity regression failed");
end DNS_Child_Capacity_Smoke;
