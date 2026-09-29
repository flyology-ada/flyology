with Ada.Streams;
with Flyology;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.IO.Sockets.GNAT_Adapters;
with GNAT.Sockets;
with Flyology.IO.Timers;

procedure IO_Smoke is
   use Ada.Streams;
   use type Flyology.IO.Descriptor;
   use type Flyology.IO.Sockets.Endpoint;

   Event_Socket  : Flyology.IO.Sockets.Socket_Type;
   Native_Socket : Flyology.IO.Sockets.Socket_Type;

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

   protected Duplex_Results is
      procedure Reader_Passed (Value : Boolean);
      procedure Writer_Passed (Value : Boolean);
      entry Wait;
      function Passed return Boolean;
   private
      Reader_Done, Writer_Done : Boolean := False;
      Reader_OK, Writer_OK     : Boolean := False;
   end Duplex_Results;

   protected Fanout_Results is
      procedure Started;
      procedure Finished (Value : Boolean);
      entry Wait_Until_Started;
      entry Wait_Until_Finished;
      function Passed return Boolean;
   private
      Started_Count  : Natural := 0;
      Finished_Count : Natural := 0;
      All_OK         : Boolean := True;
   end Fanout_Results;

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

      function Passed return Boolean
      is (Event_OK and Native_OK);
   end Results;

   protected body Duplex_Results is
      procedure Reader_Passed (Value : Boolean) is
      begin
         Reader_OK := Value;
         Reader_Done := True;
      end Reader_Passed;

      procedure Writer_Passed (Value : Boolean) is
      begin
         Writer_OK := Value;
         Writer_Done := True;
      end Writer_Passed;

      entry Wait when Reader_Done and Writer_Done is
      begin
         null;
      end Wait;

      function Passed return Boolean
      is (Reader_OK and Writer_OK);
   end Duplex_Results;

   protected body Fanout_Results is
      procedure Started is
      begin
         Started_Count := Started_Count + 1;
      end Started;

      procedure Finished (Value : Boolean) is
      begin
         Finished_Count := Finished_Count + 1;
         All_OK := All_OK and Value;
      end Finished;

      entry Wait_Until_Started when Started_Count = 2 is
      begin
         null;
      end Wait_Until_Started;

      entry Wait_Until_Finished when Finished_Count = 2 is
      begin
         null;
      end Wait_Until_Finished;

      function Passed return Boolean
      is (All_OK);
   end Fanout_Results;

begin
   declare
      Alias    : Flyology.IO.Sockets.Socket_Type;
      Rejected : Boolean := False;
   begin
      begin
         Flyology.IO.Sockets.Create_Socket_Pair (Alias, Alias);
      exception
         when Program_Error =>
            Rejected := True;
      end;
      pragma Assert (Rejected);
      pragma Assert (not Flyology.IO.Sockets.Is_Open (Alias));
   end;

   Flyology.IO.Sockets.Create_Socket_Pair (Event_Socket, Native_Socket);
   declare
      Receiver : Flyology.IO.Sockets.Socket_Type;
      Sender   : Flyology.IO.Sockets.Socket_Type;
      Payload  : constant Stream_Element_Array := [16#A5#, 16#5A#];
      Incoming : Stream_Element_Array (Payload'Range);
      Last     : Stream_Element_Offset;
      From     : Flyology.IO.Sockets.Endpoint;
   begin
      Flyology.IO.Sockets.Create_Socket_Pair (Receiver, Sender, Flyology.IO.Sockets.Socket_Datagram);
      Flyology.IO.Sockets.Send_Socket (Sender, Payload, Last);
      pragma Assert (Last = Payload'Last);
      Flyology.IO.Sockets.Receive_Socket (Receiver, Incoming, Last, From);
      pragma Assert (Last = Incoming'Last);
      pragma Assert (Incoming = Payload);
      pragma Assert (From = Flyology.IO.Sockets.No_Endpoint);
      Flyology.IO.Sockets.Close_Socket (Receiver);
      Flyology.IO.Sockets.Close_Socket (Sender);
   end;
   declare
      Released : Flyology.IO.Descriptor;
      Original : constant Flyology.IO.Descriptor := Flyology.IO.Sockets.Native_Descriptor (Event_Socket);
   begin
      Flyology.IO.Sockets.Release (Event_Socket, Released);
      pragma Assert (not Flyology.IO.Sockets.Is_Open (Event_Socket));
      pragma Assert (Released = Original);
      Flyology.IO.Sockets.Adopt (Released, Event_Socket);
      pragma Assert (Released = Flyology.IO.Invalid_Descriptor);
      pragma Assert (Flyology.IO.Sockets.Native_Descriptor (Event_Socket) = Original);
   end;
   declare
      GNAT_Socket : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Original    : constant Flyology.IO.Descriptor := Flyology.IO.Sockets.Native_Descriptor (Event_Socket);
   begin
      Flyology.IO.Sockets.GNAT_Adapters.Release (Event_Socket, GNAT_Socket);
      pragma Assert (not Flyology.IO.Sockets.Is_Open (Event_Socket));
      pragma Assert (GNAT.Sockets.To_C (GNAT_Socket) = Integer (Original));
      Flyology.IO.Sockets.GNAT_Adapters.Adopt (GNAT_Socket, Event_Socket);
      pragma Assert (GNAT.Sockets.To_C (GNAT_Socket) < 0);
      pragma Assert (Flyology.IO.Sockets.Native_Descriptor (Event_Socket) = Original);
   end;

   declare
      task Lightweight is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Lightweight;

      task Native is
         pragma Task_Info (Flyology.Native_Task);
      end Native;

      task body Lightweight is
         Incoming : Stream_Element_Array (Native_To_Event'Range);
      begin
         Flyology.IO.Sockets.Receive_Exactly (Event_Socket, Incoming, Timeout => 1.0);
         Flyology.IO.Sockets.Send_All (Event_Socket, Event_To_Native, Timeout => 1.0);
         Results.Event_Passed (Incoming = Native_To_Event);
      end Lightweight;

      task body Native is
         Incoming  : Stream_Element_Array (Event_To_Native'Range);
         Probe     : Stream_Element_Array (1 .. 1);
         Last      : Stream_Element_Offset;
         Timed_Out : Boolean := False;
      begin
         Flyology.IO.Timers.Sleep_For (0.020);
         Flyology.IO.Sockets.Send_All (Native_Socket, Native_To_Event, Timeout => 1.0);
         Flyology.IO.Sockets.Receive_Exactly (Native_Socket, Incoming, Timeout => 1.0);
         begin
            Flyology.IO.Sockets.Receive (Native_Socket, Probe, Last, Timeout => 0.010);
         exception
            when Flyology.IO.Timeout_Error =>
               Timed_Out := True;
         end;
         Results.Native_Passed (Incoming = Event_To_Native and then Timed_Out);
      end Native;
   begin
      Results.Wait;
   end;

   declare
      task Read_Waiter is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Read_Waiter;

      task Write_Waiter is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Write_Waiter;
      task Native_Sender is
         pragma Task_Info (Flyology.Native_Task);
      end Native_Sender;

      task body Read_Waiter is
         Incoming : Stream_Element_Array (1 .. 1);
      begin
         if Flyology.IO.Wait
              (Flyology.IO.Sockets.Native_Descriptor (Event_Socket), Flyology.IO.For_Read, Timeout => 1.0)
         then
            Flyology.IO.Sockets.Receive_Exactly (Event_Socket, Incoming, Timeout => 1.0);
            Duplex_Results.Reader_Passed (Incoming (1) = 42);
         else
            Duplex_Results.Reader_Passed (False);
         end if;
      end Read_Waiter;

      task body Write_Waiter is
      begin
         Duplex_Results.Writer_Passed
           (Flyology.IO.Wait
              (Flyology.IO.Sockets.Native_Descriptor (Event_Socket), Flyology.IO.For_Write, Timeout => 1.0));
      end Write_Waiter;

      task body Native_Sender is
      begin
         Flyology.IO.Timers.Sleep_For (0.020);
         Flyology.IO.Sockets.Send_All (Native_Socket, [1 => 42], Timeout => 1.0);
      end Native_Sender;
   begin
      Duplex_Results.Wait;
   end;

   if not Duplex_Results.Passed then
      raise Program_Error with "simultaneous read/write descriptor waits failed";
   end if;

   declare
      task type Read_Waiter is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Read_Waiter;
      task Sender is
         pragma Task_Info (Flyology.Native_Task);
      end Sender;

      task body Read_Waiter is
         Ready : Boolean := False;
      begin
         Fanout_Results.Started;
         Ready :=
           Flyology.IO.Wait
             (Flyology.IO.Sockets.Native_Descriptor (Event_Socket), Flyology.IO.For_Read, Timeout => 1.0);
         Fanout_Results.Finished (Ready);
      exception
         when others =>
            Fanout_Results.Finished (False);
      end Read_Waiter;

      task body Sender is
      begin
         Fanout_Results.Wait_Until_Started;
         Flyology.IO.Sockets.Send_All (Native_Socket, [1 => 43], Timeout => 1.0);
      end Sender;

      Waiters : array (1 .. 2) of Read_Waiter;
      pragma Unreferenced (Waiters);
      Probe   : Stream_Element_Array (1 .. 1);
   begin
      Fanout_Results.Wait_Until_Finished;
      Flyology.IO.Sockets.Receive_Exactly (Event_Socket, Probe, Timeout => 1.0);
      if not Fanout_Results.Passed or else Probe (1) /= 43 then
         raise Program_Error with "same-direction descriptor fanout failed";
      end if;
   end;

   declare
      Probe     : Stream_Element_Array (1 .. 1);
      Last      : Stream_Element_Offset;
      Timed_Out : Boolean := False;

      task Delayed_Sender is
         pragma Task_Info (Flyology.Native_Task);
      end Delayed_Sender;

      task body Delayed_Sender is
      begin
         Flyology.IO.Timers.Sleep_For (0.050);
         Flyology.IO.Sockets.Send_All (Native_Socket, [1 => 44], Timeout => 1.0);
      end Delayed_Sender;
   begin
      begin
         Flyology.IO.Sockets.Receive (Event_Socket, Probe, Last, Timeout => 0.010);
      exception
         when Flyology.IO.Timeout_Error =>
            Timed_Out := True;
      end;
      if not Timed_Out then
         raise Program_Error with "lightweight socket timeout did not fire";
      end if;

      Flyology.IO.Sockets.Receive_Exactly (Event_Socket, Probe, Timeout => 1.0);
      if Probe (1) /= 44 then
         raise Program_Error with "descriptor wait did not rearm after timeout";
      end if;
   end;

   Flyology.IO.Sockets.Close_Socket (Event_Socket);
   Flyology.IO.Sockets.Close_Socket (Native_Socket);

   if not Results.Passed then
      raise Program_Error with "socket-pair I/O failed";
   end if;
end IO_Smoke;
