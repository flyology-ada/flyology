with Ada.Real_Time;
with Ada.Unchecked_Conversion;
with GNAT.OS_Lib;
with Flyology.Time_Math;
with Flyology.Wait_Policy;
with Interfaces.C;
with System;
with System.OS_Constants;

package body Flyology.IO.Sockets is
   package Sockets renames GNAT.Sockets;

   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.C.int;
   use type Sockets.Error_Type;
   use type Sockets.Socket_Type;

   function To_Descriptor is new Ada.Unchecked_Conversion
     (Sockets.Socket_Type, Interfaces.C.int);

   function To_Socket is new Ada.Unchecked_Conversion
     (Interfaces.C.int, Sockets.Socket_Type);

   function C_Accept
     (Socket  : Interfaces.C.int;
      Address : System.Address;
      Length  : System.Address) return Interfaces.C.int;
   pragma Import (C, C_Accept, "flyology_accept");

   function C_Errno_Connection_Aborted return Interfaces.C.int;
   pragma Import
     (C, C_Errno_Connection_Aborted,
      "flyology_errno_connection_aborted");
   function C_Errno_Protocol_Error return Interfaces.C.int;
   pragma Import
     (C, C_Errno_Protocol_Error, "flyology_errno_protocol_error");
   function C_Errno_Process_File_Limit return Interfaces.C.int;
   pragma Import
     (C, C_Errno_Process_File_Limit,
      "flyology_errno_process_file_limit");
   function C_Errno_System_File_Limit return Interfaces.C.int;
   pragma Import
     (C, C_Errno_System_File_Limit,
      "flyology_errno_system_file_limit");

   Connection_Aborted_Error : constant Interfaces.C.int :=
     C_Errno_Connection_Aborted;
   Protocol_Error : constant Interfaces.C.int := C_Errno_Protocol_Error;
   Process_File_Limit_Error : constant Interfaces.C.int :=
     C_Errno_Process_File_Limit;
   System_File_Limit_Error : constant Interfaces.C.int :=
     C_Errno_System_File_Limit;

   --  GNAT implements this as SO_NOSIGPIPE where the platform needs a socket
   --  option and as the appropriate no-op/send-time policy elsewhere.
   procedure Disable_SIGPIPE (Socket : Interfaces.C.int);
   pragma Import (C, Disable_SIGPIPE, "__gnat_disable_sigpipe");
   function Native_Descriptor
     (Socket : Sockets.Socket_Type) return Descriptor
   is
     (To_Descriptor (Socket));

   function Remaining
     (Started : Ada.Real_Time.Time; Timeout : Duration) return Duration;

   procedure Wait_For
     (Socket    : Sockets.Socket_Type;
      Condition : Wait_Kind;
      Started   : Ada.Real_Time.Time;
      Timeout   : Duration;
      Interrupt_1 : Descriptor;
      Interrupt_2 : Descriptor;
      Interrupt_3 : Descriptor);

   procedure Receive_Prepared
     (Socket  : Sockets.Socket_Type;
      Item    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration;
      Interrupt_1 : Descriptor;
      Interrupt_2 : Descriptor;
      Interrupt_3 : Descriptor);

   procedure Send_Prepared
     (Socket  : Sockets.Socket_Type;
      Item    : Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration;
      Interrupt_1 : Descriptor;
      Interrupt_2 : Descriptor;
      Interrupt_3 : Descriptor);

   function Remaining
     (Started : Ada.Real_Time.Time; Timeout : Duration) return Duration
   is
      Elapsed : Duration;
   begin
      if Timeout < 0.0 then
         return Infinite;
      end if;

      Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
      return Time_Math.Remaining (Timeout, Elapsed);
   end Remaining;

   procedure Wait_For
     (Socket    : Sockets.Socket_Type;
      Condition : Wait_Kind;
      Started   : Ada.Real_Time.Time;
      Timeout   : Duration;
      Interrupt_1 : Descriptor;
      Interrupt_2 : Descriptor;
      Interrupt_3 : Descriptor)
   is
      Outcome : constant Wait_Outcome :=
        Wait_Interruptibly
          (To_Descriptor (Socket), Condition, Remaining (Started, Timeout),
           Interrupt_1, Interrupt_2, Interrupt_3);
   begin
      case Outcome is
         when Ready => null;
         when Timed_Out =>
            raise Timeout_Error with "socket operation timed out";
         when Interrupted =>
            raise Operation_Interrupted with "socket operation interrupted";
      end case;
   end Wait_For;

   procedure Prepare (Socket : Sockets.Socket_Type) is
      Request : Sockets.Request_Type (Sockets.Non_Blocking_IO) :=
        (Name => Sockets.Non_Blocking_IO, Enabled => True);
   begin
      Sockets.Control_Socket (Socket, Request);
   end Prepare;

   procedure Receive
     (Socket  : Sockets.Socket_Type;
      Item    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration := Infinite;
      Interrupt_1 : Descriptor := Invalid_Descriptor;
      Interrupt_2 : Descriptor := Invalid_Descriptor;
      Interrupt_3 : Descriptor := Invalid_Descriptor)
   is
   begin
      Prepare (Socket);
      Receive_Prepared
        (Socket, Item, Last, Timeout,
         Interrupt_1, Interrupt_2, Interrupt_3);
   end Receive;

   procedure Receive_Prepared
     (Socket  : Sockets.Socket_Type;
      Item    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration;
      Interrupt_1 : Descriptor;
      Interrupt_2 : Descriptor;
      Interrupt_3 : Descriptor)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   begin
      loop
         begin
            Sockets.Receive_Socket (Socket, Item, Last);
            return;
         exception
            when Occurrence : Sockets.Socket_Error =>
               case Sockets.Resolve_Exception (Occurrence) is
                  when Sockets.Resource_Temporarily_Unavailable =>
                     Wait_For
                       (Socket, For_Read, Started, Timeout,
                        Interrupt_1, Interrupt_2, Interrupt_3);
                  when Sockets.Interrupted_System_Call =>
                     null;
                  when others =>
                     raise;
               end case;
         end;
      end loop;
   end Receive_Prepared;

   procedure Receive_Exactly
     (Socket  : Sockets.Socket_Type;
      Item    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite;
      Interrupt_1 : Descriptor := Invalid_Descriptor;
      Interrupt_2 : Descriptor := Invalid_Descriptor;
      Interrupt_3 : Descriptor := Invalid_Descriptor)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      First   : Ada.Streams.Stream_Element_Offset := Item'First;
      Last    : Ada.Streams.Stream_Element_Offset;
   begin
      Prepare (Socket);
      while First <= Item'Last loop
         Receive_Prepared
           (Socket,
            Item (First .. Item'Last),
            Last,
            Remaining (Started, Timeout),
            Interrupt_1,
            Interrupt_2,
            Interrupt_3);
         if Last < First then
            raise Device_Error with "socket closed while receiving";
         end if;
         First := Last + 1;
      end loop;
   end Receive_Exactly;

   procedure Send
     (Socket  : Sockets.Socket_Type;
      Item    : Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration := Infinite;
      Interrupt_1 : Descriptor := Invalid_Descriptor;
      Interrupt_2 : Descriptor := Invalid_Descriptor;
      Interrupt_3 : Descriptor := Invalid_Descriptor)
   is
   begin
      Prepare (Socket);
      Send_Prepared
        (Socket, Item, Last, Timeout,
         Interrupt_1, Interrupt_2, Interrupt_3);
   end Send;

   procedure Send_Prepared
     (Socket  : Sockets.Socket_Type;
      Item    : Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration;
      Interrupt_1 : Descriptor;
      Interrupt_2 : Descriptor;
      Interrupt_3 : Descriptor)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   begin
      loop
         begin
            Sockets.Send_Socket (Socket, Item, Last);
            return;
         exception
            when Occurrence : Sockets.Socket_Error =>
               case Sockets.Resolve_Exception (Occurrence) is
                  when Sockets.Resource_Temporarily_Unavailable =>
                     Wait_For
                       (Socket, For_Write, Started, Timeout,
                        Interrupt_1, Interrupt_2, Interrupt_3);
                  when Sockets.Interrupted_System_Call =>
                     null;
                  when others =>
                     raise;
               end case;
         end;
      end loop;
   end Send_Prepared;

   procedure Send_All
     (Socket  : Sockets.Socket_Type;
      Item    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite;
      Interrupt_1 : Descriptor := Invalid_Descriptor;
      Interrupt_2 : Descriptor := Invalid_Descriptor;
      Interrupt_3 : Descriptor := Invalid_Descriptor)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      First   : Ada.Streams.Stream_Element_Offset := Item'First;
      Last    : Ada.Streams.Stream_Element_Offset;
   begin
      Prepare (Socket);
      while First <= Item'Last loop
         Send_Prepared
           (Socket,
            Item (First .. Item'Last),
            Last,
            Remaining (Started, Timeout),
            Interrupt_1,
            Interrupt_2,
            Interrupt_3);
         if Last < First then
            raise Device_Error with "socket closed while sending";
         end if;
         First := Last + 1;
      end loop;
   end Send_All;

   procedure Accept_Connection
     (Server  : Sockets.Socket_Type;
      Socket  : out Sockets.Socket_Type;
      Address : out Sockets.Sock_Addr_Type;
      Timeout : Duration := Infinite;
      Interrupt_1 : Descriptor := Invalid_Descriptor;
      Interrupt_2 : Descriptor := Invalid_Descriptor;
      Interrupt_3 : Descriptor := Invalid_Descriptor)
   is
      Started  : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Accepted : Sockets.Socket_Type := Sockets.No_Socket;
      Peer      : Sockets.Sock_Addr_Type := Sockets.No_Sock_Addr;
      Pressure_Backoff : Duration := 0.001;

      procedure Pause_Before_Retry (Requested : Duration) is
         Requests : Wait_Request_Array (1 .. 3);
         Count    : Natural := 0;
         Left     : constant Duration := Remaining (Started, Timeout);
         Pause    : Duration;

         procedure Add (FD : Descriptor) is
         begin
            if FD >= 0 then
               Count := Count + 1;
               Requests (Count) := (FD => FD, Condition => For_Read);
            end if;
         end Add;
      begin
         if Timeout >= 0.0 and then Left <= 0.0 then
            raise Timeout_Error with "socket operation timed out";
         end if;
         Pause :=
           (if Requested <= 0.0 then 0.0
            elsif Timeout < 0.0 then Requested
            else Duration'Min (Requested, Left));

         Add (Interrupt_1);
         Add (Interrupt_2);
         Add (Interrupt_3);
         if Count > 0 then
            if Wait_Any (Requests (1 .. Count), Pause) /= 0 then
               raise Operation_Interrupted with
                 "socket operation interrupted";
            end if;
         elsif Pause > 0.0 then
            delay Pause;
         end if;
         if Pause = 0.0 then
            --  Continuous aborted admissions must not monopolize a
            --  lightweight task's execution group.
            delay 0.0;
         end if;

         if Timeout >= 0.0 and then Remaining (Started, Timeout) <= 0.0 then
            raise Timeout_Error with "socket operation timed out";
         end if;
      end Pause_Before_Retry;
   begin
      Prepare (Server);
      loop
         declare
            Result : constant Interfaces.C.int :=
              C_Accept
                (To_Descriptor (Server),
                 System.Null_Address,
                 System.Null_Address);
            Error_Code : Integer;
         begin
            if Result < 0 then
               Error_Code := GNAT.OS_Lib.Errno;
               case Wait_Policy.Classify_Accept_Error
                 (Interfaces.C.int (Error_Code),
                  Interfaces.C.int (System.OS_Constants.EWOULDBLOCK),
                  Interfaces.C.int (System.OS_Constants.EINTR),
                  Connection_Aborted_Error,
                  Protocol_Error,
                  Process_File_Limit_Error,
                  System_File_Limit_Error)
               is
                  when Wait_Policy.Wait_For_Connection =>
                     Wait_For
                       (Server, For_Read, Started, Timeout,
                        Interrupt_1, Interrupt_2, Interrupt_3);
                  when Wait_Policy.Retry_Accept =>
                     Pause_Before_Retry (0.0);
                  when Wait_Policy.Retry_Transient =>
                     Pause_Before_Retry (0.0);
                  when Wait_Policy.Backoff_Descriptor_Pressure =>
                     Pause_Before_Retry (Pressure_Backoff);
                     Pressure_Backoff :=
                       Duration'Min (Pressure_Backoff * 2, 0.050);
                  when Wait_Policy.Fail_Accept =>
                     raise Sockets.Socket_Error with
                       "accept failed, errno=" & Error_Code'Image;
               end case;
            else
               Accepted := To_Socket (Result);
               Disable_SIGPIPE (Result);
               Peer := Sockets.Get_Peer_Name (Accepted);
               Prepare (Accepted);
               Socket := Accepted;
               Address := Peer;
               return;
            end if;
         exception
            when others =>
               if Accepted /= Sockets.No_Socket then
                  Sockets.Close_Socket (Accepted);
               end if;
               raise;
         end;
      end loop;
   end Accept_Connection;

   procedure Connect
     (Socket  : Sockets.Socket_Type;
      Server  : Sockets.Sock_Addr_Type;
      Timeout : Duration := Infinite;
      Interrupt_1 : Descriptor := Invalid_Descriptor;
      Interrupt_2 : Descriptor := Invalid_Descriptor;
      Interrupt_3 : Descriptor := Invalid_Descriptor)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Pending : Boolean := False;
   begin
      Prepare (Socket);
      begin
         Sockets.Connect_Socket (Socket, Server);
         return;
      exception
         when Occurrence : Sockets.Socket_Error =>
            case Sockets.Resolve_Exception (Occurrence) is
               when Sockets.Operation_Now_In_Progress |
                    Sockets.Operation_Already_In_Progress =>
                  Pending := True;
               when Sockets.Transport_Endpoint_Already_Connected =>
                  return;
               when others =>
                  raise;
            end case;
      end;

      if Pending then
         Wait_For
           (Socket, For_Write, Started, Timeout,
            Interrupt_1, Interrupt_2, Interrupt_3);
         declare
            Result : constant Sockets.Option_Type :=
              Sockets.Get_Socket_Option
                (Socket, Sockets.Socket_Level, Sockets.Error);
         begin
            if Result.Error /= Sockets.Success then
               raise Sockets.Socket_Error with
                 "connect failed: " & Result.Error'Image;
            end if;
         end;
      end if;
   end Connect;

end Flyology.IO.Sockets;
