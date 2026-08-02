with Ada.Streams;
with GNAT.Sockets;
with Gnatevl;
with Gnatevl.IO;
with Gnatevl.IO.Sockets;
with Gnatevl.IO.Timers;

procedure IO_Smoke is
   use Ada.Streams;

   Event_Socket  : GNAT.Sockets.Socket_Type;
   Native_Socket : GNAT.Sockets.Socket_Type;

   Event_To_Native : constant Stream_Element_Array := [1, 2, 3, 4];
   Native_To_Event : constant Stream_Element_Array := [5, 6, 7, 8];

   protected Results is
      procedure Event_Passed (Value : Boolean);
      procedure Native_Passed (Value : Boolean);
      entry Wait;
      function Passed return Boolean;
   private
      Event_Done, Native_Done : Boolean := False;
      Event_OK, Native_OK     : Boolean := False;
   end Results;

   protected body Results is
      procedure Event_Passed (Value : Boolean) is
      begin
         Event_OK := Value;
         Event_Done := True;
      end Event_Passed;

      procedure Native_Passed (Value : Boolean) is
      begin
         Native_OK := Value;
         Native_Done := True;
      end Native_Passed;

      entry Wait when Event_Done and Native_Done is
      begin
         null;
      end Wait;

      function Passed return Boolean is (Event_OK and Native_OK);
   end Results;

begin
   GNAT.Sockets.Create_Socket_Pair (Event_Socket, Native_Socket);

   declare
      task Evented;

      task Native is
         pragma Task_Info (Gnatevl.Native_Thread);
      end Native;

      task body Evented is
         Incoming : Stream_Element_Array (Native_To_Event'Range);
      begin
         Gnatevl.IO.Sockets.Receive_Exactly
           (Event_Socket, Incoming, Timeout => 1.0);
         Gnatevl.IO.Sockets.Send_All
           (Event_Socket, Event_To_Native, Timeout => 1.0);
         Results.Event_Passed (Incoming = Native_To_Event);
      end Evented;

      task body Native is
         Incoming : Stream_Element_Array (Event_To_Native'Range);
         Probe    : Stream_Element_Array (1 .. 1);
         Last     : Stream_Element_Offset;
         Timed_Out : Boolean := False;
      begin
         Gnatevl.IO.Timers.Sleep_For (0.020);
         Gnatevl.IO.Sockets.Send_All
           (Native_Socket, Native_To_Event, Timeout => 1.0);
         Gnatevl.IO.Sockets.Receive_Exactly
           (Native_Socket, Incoming, Timeout => 1.0);
         begin
            Gnatevl.IO.Sockets.Receive
              (Native_Socket, Probe, Last, Timeout => 0.010);
         exception
            when Gnatevl.IO.Timeout_Error =>
               Timed_Out := True;
         end;
         Results.Native_Passed
           (Incoming = Event_To_Native and then Timed_Out);
      end Native;
   begin
      Results.Wait;
   end;

   declare
      Probe     : Stream_Element_Array (1 .. 1);
      Last      : Stream_Element_Offset;
      Timed_Out : Boolean := False;
   begin
      begin
         Gnatevl.IO.Sockets.Receive
           (Event_Socket, Probe, Last, Timeout => 0.010);
      exception
         when Gnatevl.IO.Timeout_Error =>
            Timed_Out := True;
      end;
      if not Timed_Out then
         raise Program_Error with "evented socket timeout did not fire";
      end if;
   end;

   GNAT.Sockets.Close_Socket (Event_Socket);
   GNAT.Sockets.Close_Socket (Native_Socket);

   if not Results.Passed then
      raise Program_Error with "socket-pair I/O failed";
   end if;
end IO_Smoke;
