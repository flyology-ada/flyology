with Ada.Real_Time;
with Ada.Unchecked_Conversion;
with GNAT.OS_Lib;
with Gnatevl.Time_Math;
with Gnatevl.Wait_Policy;
with Interfaces.C;
with System;
with System.OS_Constants;

package body Gnatevl.IO.Sockets is
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
   pragma Import (C, C_Accept, "accept");

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
               case Wait_Policy.Classify_Error
                 (Interfaces.C.int (Error_Code),
                  Interfaces.C.int (System.OS_Constants.EWOULDBLOCK),
                  Interfaces.C.int (System.OS_Constants.EINTR))
               is
                  when Wait_Policy.Wait_For_Ready =>
                     Wait_For
                       (Server, For_Read, Started, Timeout,
                        Interrupt_1, Interrupt_2, Interrupt_3);
                  when Wait_Policy.Retry_Operation =>
                     null;
                  when Wait_Policy.Fail_Operation =>
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

end Gnatevl.IO.Sockets;
