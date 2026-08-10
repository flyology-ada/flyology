with Ada.Command_Line;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Text_IO;
with Flyology;
with Flyology.Cancellation;
with Flyology.Execution_Groups;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with Flyology.Observability;

procedure TCP_Readiness_Benchmark is
   use Ada.Streams;
   use Ada.Text_IO;
   use type Ada.Real_Time.Time;

   package Connections renames Flyology.IO.Connections;
   package Groups renames Flyology.Execution_Groups;
   package Observe renames Flyology.Observability;
   package Sockets renames Flyology.IO.Sockets;

   subtype Connection_Count is Positive range 1 .. 4_096;

   function Parse_Connections return Connection_Count is
   begin
      if Ada.Command_Line.Argument_Count /= 1 then
         raise Constraint_Error;
      end if;
      return Connection_Count'Value (Ada.Command_Line.Argument (1));
   end Parse_Connections;

   function Bytes (Value : String) return Stream_Element_Array is
      Result : Stream_Element_Array (1 .. Value'Length);
   begin
      for Index in Value'Range loop
         Result
           (Stream_Element_Offset (Index - Value'First + 1)) :=
             Stream_Element (Character'Pos (Value (Index)));
      end loop;
      return Result;
   end Bytes;

   Connections_To_Accept : constant Connection_Count := Parse_Connections;
   Listener : Sockets.Socket_Type;
   Address  : Sockets.Endpoint;
   Manager  : aliased Connections.Server (Capacity => Connections_To_Accept);
   Stop     : aliased Flyology.Cancellation.Token;

   Response : constant Stream_Element_Array :=
     Bytes
       ("HTTP/1.1 200 OK" & ASCII.CR & ASCII.LF
        & "Content-Length: 0" & ASCII.CR & ASCII.LF
        & "Connection: keep-alive" & ASCII.CR & ASCII.LF
        & ASCII.CR & ASCII.LF);

   type Group_Count_Array is array (Groups.Shared_Group_Id) of Natural;

   protected Progress is
      procedure Accepted (Group : Groups.Group_Id);
      entry Await_Accepted;
      procedure Finished (Requests : Natural; Succeeded : Boolean);
      entry Await_Finished;
      function Request_Count return Natural;
      function Failure_Count return Natural;
      function Group_Count (Group : Groups.Shared_Group_Id) return Natural;
   private
      Accepted_Count : Natural := 0;
      Finished_Count : Natural := 0;
      Requests       : Natural := 0;
      Failures       : Natural := 0;
      Counts         : Group_Count_Array := (others => 0);
   end Progress;

   protected body Progress is
      procedure Accepted (Group : Groups.Group_Id) is
      begin
         Accepted_Count := Accepted_Count + 1;
         if Group in Groups.Shared_Group_Id then
            Counts (Group) := Counts (Group) + 1;
         else
            Failures := Failures + 1;
         end if;
      end Accepted;

      entry Await_Accepted when Accepted_Count = Connections_To_Accept is
      begin
         null;
      end Await_Accepted;

      procedure Finished (Requests : Natural; Succeeded : Boolean) is
      begin
         Finished_Count := Finished_Count + 1;
         Progress.Requests := Progress.Requests + Requests;
         if not Succeeded then
            Failures := Failures + 1;
         end if;
      end Finished;

      entry Await_Finished when Finished_Count = Connections_To_Accept is
      begin
         null;
      end Await_Finished;

      function Request_Count return Natural is (Requests);
      function Failure_Count return Natural is (Failures);
      function Group_Count
        (Group : Groups.Shared_Group_Id) return Natural is (Counts (Group));
   end Progress;

   procedure Close_If_Open (Socket : in out Sockets.Socket_Type) is
   begin
      if Sockets.Is_Open (Socket) then
         Sockets.Close_Socket (Socket);
      end if;
   end Close_If_Open;

begin
   Sockets.Create_Socket (Listener, Sockets.IPv4, Sockets.Socket_Stream);
   Sockets.Set_Socket_Option
     (Listener, (Name => Sockets.Reuse_Address, Enabled => True));
   Sockets.Bind_Socket
     (Listener,
      Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
   Sockets.Listen_Socket (Listener, Connections_To_Accept);
   Address := Sockets.Get_Socket_Name (Listener);

   Put_Line
     ("ready port=" & Sockets.Port'Image (Address.Port)
      & " connections=" & Connection_Count'Image (Connections_To_Accept)
      & " loops=" & Groups.Loop_Pool_Size'Image (Groups.Configured_Pool_Size));
   Ada.Text_IO.Flush;

   declare
      task type Handler is
         pragma Task_Info (Flyology.Lightweight_Task);
         pragma Storage_Size (32 * 1_024);
      end Handler;

      task body Handler is
         Item       : Connections.Connection (Manager'Access);
         Peer       : Sockets.Endpoint;
         Buffer     : Stream_Element_Array (1 .. 4_096);
         Last       : Stream_Element_Offset;
         Matched    : Natural range 0 .. 3 := 0;
         Requests   : Natural := 0;

         procedure Observe_Byte (Value : Stream_Element) is
         begin
            case Matched is
               when 0 =>
                  Matched := (if Value = 13 then 1 else 0);
               when 1 =>
                  if Value = 10 then
                     Matched := 2;
                  elsif Value /= 13 then
                     Matched := 0;
                  end if;
               when 2 =>
                  Matched := (if Value = 13 then 3 else 0);
               when 3 =>
                  if Value = 10 then
                     Matched := 0;
                     Item.Send_All
                       (Response, Timeout => 30.0, Token => Stop'Access);
                     Requests := Requests + 1;
                  elsif Value = 13 then
                     Matched := 1;
                  else
                     Matched := 0;
                  end if;
            end case;
         end Observe_Byte;
      begin
         Connections.Accept_Connection
           (Manager, Listener, Item, Peer,
            Timeout => 30.0, Token => Stop'Access);
         Progress.Accepted (Groups.Current);
         loop
            Item.Receive
              (Buffer, Last, Timeout => 30.0, Token => Stop'Access);
            exit when Last < Buffer'First;
            for Index in Buffer'First .. Last loop
               Observe_Byte (Buffer (Index));
            end loop;
         end loop;
         Progress.Finished (Requests, True);
      exception
         when others =>
            Progress.Finished (Requests, False);
      end Handler;

      type Handler_Access is access Handler;
      type Handler_Array is array (Connection_Count range <>) of Handler_Access;
      Handlers : Handler_Array (1 .. Connections_To_Accept);

      Started  : Ada.Real_Time.Time;
      Elapsed  : Duration;
      Snapshot : Observe.Group_Snapshot;
      Pool     : constant Groups.Loop_Pool_Size := Groups.Configured_Pool_Size;
   begin
      Started := Ada.Real_Time.Clock;
      for Index in Handlers'Range loop
         Handlers (Index) := new Handler;
      end loop;
      Progress.Await_Accepted;
      Close_If_Open (Listener);
      Progress.Await_Finished;
      Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);

      Manager.Request_Shutdown;
      Manager.Await_Drained;
      Put_Line
        ("complete requests=" & Natural'Image (Progress.Request_Count)
         & " failures=" & Natural'Image (Progress.Failure_Count)
         & " elapsed_seconds=" & Duration'Image (Elapsed));
      for Group in Groups.Shared_Group_Id range
        0 .. Groups.Shared_Group_Id (Pool - 1)
      loop
         if Observe.Snapshot (Group, Snapshot) then
            Put_Line
              ("group=" & Groups.Group_Id'Image (Group)
               & " connections=" & Natural'Image (Progress.Group_Count (Group))
               & " dispatches=" & Observe.Counter'Image (Snapshot.Dispatches)
               & " poll_batches=" & Observe.Counter'Image (Snapshot.Poll_Batches)
               & " poll_events=" & Observe.Counter'Image (Snapshot.Poll_Events));
         end if;
      end loop;
      if Progress.Failure_Count /= 0 then
         raise Program_Error with "TCP readiness benchmark handler failed";
      end if;
   end;
exception
   when Constraint_Error =>
      Put_Line ("usage: tcp_readiness_benchmark CONNECTIONS");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   when others =>
      Stop.Request;
      Close_If_Open (Listener);
      raise;
end TCP_Readiness_Benchmark;
