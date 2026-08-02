with Ada.Real_Time;
with Ada.Unchecked_Conversion;
with Gnatevl.Time_Math;
with Interfaces.C;
with System;

package body Gnatevl.IO.Sockets is
   package Sockets renames GNAT.Sockets;

   EINTR        : constant := 4;
   EWOULDBLOCK  : constant := 35;

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

   function Current_Errno return Interfaces.C.int;
   pragma Import (C, Current_Errno, "__get_errno");

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
      Timeout   : Duration);

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
      Timeout   : Duration)
   is
   begin
      if not Wait
        (To_Descriptor (Socket), Condition, Remaining (Started, Timeout))
      then
         raise Timeout_Error with "socket operation timed out";
      end if;
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
      Timeout : Duration := Infinite)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   begin
      Prepare (Socket);
      loop
         begin
            Sockets.Receive_Socket (Socket, Item, Last);
            return;
         exception
            when Occurrence : Sockets.Socket_Error =>
               case Sockets.Resolve_Exception (Occurrence) is
                  when Sockets.Resource_Temporarily_Unavailable =>
                     Wait_For (Socket, For_Read, Started, Timeout);
                  when Sockets.Interrupted_System_Call =>
                     null;
                  when others =>
                     raise;
               end case;
         end;
      end loop;
   end Receive;

   procedure Receive_Exactly
     (Socket  : Sockets.Socket_Type;
      Item    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      First   : Ada.Streams.Stream_Element_Offset := Item'First;
      Last    : Ada.Streams.Stream_Element_Offset;
   begin
      Prepare (Socket);
      while First <= Item'Last loop
         Receive
           (Socket,
            Item (First .. Item'Last),
            Last,
            Remaining (Started, Timeout));
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
      Timeout : Duration := Infinite)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   begin
      Prepare (Socket);
      loop
         begin
            Sockets.Send_Socket (Socket, Item, Last);
            return;
         exception
            when Occurrence : Sockets.Socket_Error =>
               case Sockets.Resolve_Exception (Occurrence) is
                  when Sockets.Resource_Temporarily_Unavailable =>
                     Wait_For (Socket, For_Write, Started, Timeout);
                  when Sockets.Interrupted_System_Call =>
                     null;
                  when others =>
                     raise;
               end case;
         end;
      end loop;
   end Send;

   procedure Send_All
     (Socket  : Sockets.Socket_Type;
      Item    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      First   : Ada.Streams.Stream_Element_Offset := Item'First;
      Last    : Ada.Streams.Stream_Element_Offset;
   begin
      Prepare (Socket);
      while First <= Item'Last loop
         Send
           (Socket,
            Item (First .. Item'Last),
            Last,
            Remaining (Started, Timeout));
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
      Timeout : Duration := Infinite)
   is
      Started  : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Accepted : Sockets.Socket_Type := Sockets.No_Socket;
      Peer      : Sockets.Sock_Addr_Type := Sockets.No_Sock_Addr;
   begin
      Prepare (Server);
      loop
         begin
            declare
               Result : constant Interfaces.C.int :=
                 C_Accept
                   (To_Descriptor (Server),
                    System.Null_Address,
                    System.Null_Address);
               Error_Code : Interfaces.C.int;
            begin
               if Result < 0 then
                  Error_Code := Current_Errno;
                  if Error_Code = EWOULDBLOCK then
                     Wait_For (Server, For_Read, Started, Timeout);
                  elsif Error_Code = EINTR then
                     null;
                  else
                     raise Sockets.Socket_Error with
                       "accept failed, errno=" & Error_Code'Image;
                  end if;
               else
                  Accepted := To_Socket (Result);
                  Peer := Sockets.Get_Peer_Name (Accepted);
               end if;
            end;

            if Accepted /= Sockets.No_Socket then
               Prepare (Accepted);
               Socket := Accepted;
               Address := Peer;
               return;
            end if;
         exception
            when Occurrence : Sockets.Socket_Error =>
               case Sockets.Resolve_Exception (Occurrence) is
                  when Sockets.Resource_Temporarily_Unavailable =>
                     Wait_For (Server, For_Read, Started, Timeout);
                  when Sockets.Interrupted_System_Call =>
                     null;
                  when others =>
                     raise;
               end case;
         end;
      end loop;
   end Accept_Connection;

   procedure Connect
     (Socket  : Sockets.Socket_Type;
      Server  : Sockets.Sock_Addr_Type;
      Timeout : Duration := Infinite)
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
         Wait_For (Socket, For_Write, Started, Timeout);
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
