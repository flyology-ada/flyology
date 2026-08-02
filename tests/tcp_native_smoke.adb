with Ada.Exceptions;
with Ada.Streams;
with Ada.Text_IO;
with GNAT.Sockets;
with Gnatevl;
with Gnatevl.IO.Sockets;

procedure TCP_Native_Smoke is
   use Ada.Streams;

   Listener : GNAT.Sockets.Socket_Type;
   Address  : GNAT.Sockets.Sock_Addr_Type;

   protected Results is
      procedure Report (Passed : Boolean);
      entry Wait;
      function Passed return Boolean;
   private
      Count : Natural := 0;
      OK    : Boolean := True;
   end Results;

   protected body Results is
      procedure Report (Passed : Boolean) is
      begin
         Count := Count + 1;
         OK := OK and Passed;
      end Report;

      entry Wait when Count = 2 is
      begin
         null;
      end Wait;

      function Passed return Boolean is (OK);
   end Results;

begin
   GNAT.Sockets.Create_Socket (Listener);
   GNAT.Sockets.Bind_Socket
     (Listener,
      (Family => GNAT.Sockets.Family_Inet,
       Addr   => GNAT.Sockets.Loopback_Inet_Addr,
       Port   => GNAT.Sockets.Any_Port));
   GNAT.Sockets.Listen_Socket (Listener);
   Address := GNAT.Sockets.Get_Socket_Name (Listener);

   declare
      task Server is
         pragma Task_Info (Gnatevl.Native_Thread);
      end Server;

      task Client is
         pragma Task_Info (Gnatevl.Native_Thread);
      end Client;

      task body Server is
         Peer : GNAT.Sockets.Socket_Type;
         From : GNAT.Sockets.Sock_Addr_Type;
         Data : Stream_Element_Array (1 .. 1);
         Last : Stream_Element_Offset;
      begin
         Gnatevl.IO.Sockets.Accept_Connection
           (Listener, Peer, From, Timeout => 1.0);
         Gnatevl.IO.Sockets.Receive (Peer, Data, Last, Timeout => 1.0);
         Results.Report (Last = Data'Last and then Data (1) = 42);
         GNAT.Sockets.Close_Socket (Peer);
      exception
         when Occurrence : others =>
            Ada.Text_IO.Put_Line
              ("native server failed: "
               & Ada.Exceptions.Exception_Information (Occurrence));
            Results.Report (False);
      end Server;

      task body Client is
         Data : constant Stream_Element_Array (1 .. 1) := [1 => 42];
         Last : Stream_Element_Offset;
      begin
         delay 0.020;
         declare
            Socket : GNAT.Sockets.Socket_Type;
         begin
            GNAT.Sockets.Create_Socket (Socket);
            Gnatevl.IO.Sockets.Connect (Socket, Address, Timeout => 1.0);
            Gnatevl.IO.Sockets.Send (Socket, Data, Last, Timeout => 1.0);
            Results.Report (Last = Data'Last);
            GNAT.Sockets.Close_Socket (Socket);
         end;
      exception
         when Occurrence : others =>
            Ada.Text_IO.Put_Line
              ("native client failed: "
               & Ada.Exceptions.Exception_Information (Occurrence));
            Results.Report (False);
      end Client;
   begin
      Results.Wait;
   end;

   GNAT.Sockets.Close_Socket (Listener);
   if not Results.Passed then
      raise Program_Error with "native TCP baseline failed";
   end if;
end TCP_Native_Smoke;
