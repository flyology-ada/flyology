with Ada.Exceptions;
with Ada.Streams;
with Ada.Text_IO;
with GNAT.Sockets;
with Flyology;
with Flyology_Config;
with Flyology.IO.Sockets;
with Interfaces.C;
with System;

procedure TCP_Native_Smoke is
   use Ada.Streams;

   package C renames Interfaces.C;
   use type C.int;

   SOL_SOCKET   : constant C.int := 16#FFFF#;
   SO_NOSIGPIPE : constant C.int := 16#1022#;

   function Get_Socket_Option
     (Socket     : C.int;
      Level      : C.int;
      Option     : C.int;
      Value      : System.Address;
      Value_Size : access C.unsigned) return C.int;
   pragma Import (C, Get_Socket_Option, "getsockopt");

   function SIGPIPE_Is_Disabled
     (Socket : GNAT.Sockets.Socket_Type) return Boolean
   is
      Value : aliased C.int := 0;
      Size  : aliased C.unsigned := C.unsigned (C.int'Size / 8);
   begin
      --  Linux suppresses SIGPIPE at send time with MSG_NOSIGNAL rather than
      --  with a per-socket option. Darwin exposes SO_NOSIGPIPE for inspection.
      if Flyology_Config.Alire_Host_OS = "linux" then
         return True;
      end if;
      return
        Get_Socket_Option
          (C.int (Flyology.IO.Sockets.Native_Descriptor (Socket)),
           SOL_SOCKET,
           SO_NOSIGPIPE,
           Value'Address,
           Size'Access) = 0
        and then Value = 1;
   end SIGPIPE_Is_Disabled;

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
         pragma Task_Info (Flyology.Native_Task);
      end Server;

      task Client is
         pragma Task_Info (Flyology.Native_Task);
      end Client;

      task body Server is
         Peer : GNAT.Sockets.Socket_Type;
         From : GNAT.Sockets.Sock_Addr_Type;
         Data : Stream_Element_Array (1 .. 1);
         Last : Stream_Element_Offset;
         Stage : Natural := 0;
      begin
         Stage := 1;
         Flyology.IO.Sockets.Accept_Connection
           (Listener, Peer, From, Timeout => 1.0);
         Stage := 2;
         Flyology.IO.Sockets.Receive (Peer, Data, Last, Timeout => 1.0);
         Stage := 3;
         Results.Report
           (Last = Data'Last
            and then Data (1) = 42
            and then SIGPIPE_Is_Disabled (Peer));
         Stage := 4;
         GNAT.Sockets.Close_Socket (Peer);
      exception
         when Occurrence : others =>
            Ada.Text_IO.Put_Line
              ("native server failed at stage" & Stage'Image & ": "
               & Ada.Exceptions.Exception_Information (Occurrence));
            Results.Report (False);
      end Server;

      task body Client is
         Data : constant Stream_Element_Array (1 .. 1) := [1 => 42];
         Last : Stream_Element_Offset;
         Stage : Natural := 0;
      begin
         Stage := 1;
         delay 0.020;
         declare
            Socket : GNAT.Sockets.Socket_Type;
         begin
            GNAT.Sockets.Create_Socket (Socket);
            Stage := 2;
            Flyology.IO.Sockets.Connect (Socket, Address, Timeout => 1.0);
            Stage := 3;
            Flyology.IO.Sockets.Send (Socket, Data, Last, Timeout => 1.0);
            Stage := 4;
            Results.Report (Last = Data'Last);
            Stage := 5;
            GNAT.Sockets.Close_Socket (Socket);
         end;
      exception
         when Occurrence : others =>
            Ada.Text_IO.Put_Line
              ("native client failed at stage" & Stage'Image & ": "
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
