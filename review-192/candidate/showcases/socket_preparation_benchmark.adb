with Ada.Command_Line;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Text_IO;
with Flyology;
with Flyology.IO.Sockets;
with Interfaces.C;

procedure Socket_Preparation_Benchmark is
   package Sockets renames Flyology.IO.Sockets;
   use Ada.Streams;
   use type Ada.Real_Time.Time;
   procedure Reset_Nonblocking_Setups
   with Import, Convention => C, External_Name => "flyology_test_socket_reset_nonblocking_setups";

   function Nonblocking_Setup_Count return Interfaces.C.unsigned_long_long
   with Import, Convention => C, External_Name => "flyology_test_socket_nonblocking_setup_count";

   function Parse_Rounds return Positive is
   begin
      if Ada.Command_Line.Argument_Count = 0 then
         return 200_000;
      elsif Ada.Command_Line.Argument_Count = 1 then
         return Positive'Value (Ada.Command_Line.Argument (1));
      else
         raise Constraint_Error with "usage: socket_preparation_benchmark [rounds]";
      end if;
   end Parse_Rounds;

   Rounds         : constant Positive := Parse_Rounds;
   Server, Client : Sockets.Socket_Type;
   Server_Address : Sockets.Endpoint;
   Request        : constant Stream_Element_Array := [16#A5#];
   Response       : constant Stream_Element_Array := [16#5A#];

   protected Completion is
      procedure Report (Succeeded : Boolean);
      entry Wait (Succeeded : out Boolean);
   private
      Done : Boolean := False;
      OK   : Boolean := False;
   end Completion;

   protected body Completion is
      procedure Report (Succeeded : Boolean) is
      begin
         OK := Succeeded;
         Done := True;
      end Report;

      entry Wait (Succeeded : out Boolean) when Done is
      begin
         Succeeded := OK;
      end Wait;
   end Completion;

   procedure Close_If_Open (Socket : in out Sockets.Socket_Type) is
   begin
      if Sockets.Is_Open (Socket) then
         Sockets.Close_Socket (Socket);
      end if;
   end Close_If_Open;

begin
   Sockets.Create_Socket (Server, Sockets.IPv4, Sockets.Socket_Datagram);
   Sockets.Bind_Socket (Server, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
   Server_Address := Sockets.Get_Socket_Name (Server);
   Sockets.Create_Socket (Client, Sockets.IPv4, Sockets.Socket_Datagram);
   Sockets.Bind_Socket (Client, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
   Reset_Nonblocking_Setups;

   declare
      task Server_Task is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Server_Task;

      task body Server_Task is
         Buffer   : Stream_Element_Array (Request'Range);
         Last     : Stream_Element_Offset;
         Sent     : Stream_Element_Offset;
         Metadata : Sockets.Datagram_Metadata;
      begin
         for Iteration in 1 .. Rounds loop
            Sockets.Receive_Datagram (Server, Buffer, Last, Metadata, Timeout => 5.0);
            if Last /= Buffer'Last or else Buffer /= Request then
               raise Program_Error with "benchmark request mismatch";
            end if;
            Sockets.Send_Datagram
              (Server,
               Response,
               Sent,
               Destination => Metadata.Source,
               Source      => Metadata.Destination,
               Timeout     => 5.0);
            if Sent /= Response'Last then
               raise Program_Error with "benchmark response send mismatch";
            end if;
         end loop;
         Completion.Report (True);
      exception
         when others =>
            Completion.Report (False);
      end Server_Task;

      Started   : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Buffer    : Stream_Element_Array (Response'Range);
      Last      : Stream_Element_Offset;
      Sent      : Stream_Element_Offset;
      Metadata  : Sockets.Datagram_Metadata;
      Server_OK : Boolean;
      Elapsed   : Duration;
   begin
      for Iteration in 1 .. Rounds loop
         Sockets.Send_Datagram (Client, Request, Sent, Server_Address, Timeout => 5.0);
         Sockets.Receive_Datagram (Client, Buffer, Last, Metadata, Timeout => 5.0);
         if Sent /= Request'Last or else Last /= Buffer'Last or else Buffer /= Response then
            raise Program_Error with "benchmark response mismatch";
         end if;
      end loop;
      Completion.Wait (Server_OK);
      if not Server_OK then
         raise Program_Error with "benchmark server failed";
      end if;
      Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
      Ada.Text_IO.Put_Line
        ("rounds="
         & Rounds'Image
         & " elapsed_seconds="
         & Duration'Image (Elapsed)
         & " round_trips_per_second="
         & Long_Long_Integer'Image (Long_Long_Integer (Duration (Rounds) / Elapsed))
         & " nonblocking_setups="
         & Interfaces.C.unsigned_long_long'Image (Nonblocking_Setup_Count));
   end;

   Sockets.Close_Socket (Client);
   Sockets.Close_Socket (Server);
exception
   when others =>
      Close_If_Open (Client);
      Close_If_Open (Server);
      raise;
end Socket_Preparation_Benchmark;
