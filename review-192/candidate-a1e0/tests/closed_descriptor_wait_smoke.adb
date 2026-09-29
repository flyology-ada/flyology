with Ada.Real_Time;
with Ada.Streams;
with Flyology;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.IO.Timers;

--  A raw descriptor wait does not own its descriptor, so another task may
--  close it while a poller interest is still armed. Linux epoll rejects
--  EPOLL_CTL_DEL and EPOLL_CTL_MOD for a closed descriptor with EBADF, and the
--  scheduler cancels every orphaned interest when it removes a waiter. If the
--  poller reported that EBADF as a cancellation failure the scheduler would
--  escalate an ordinary close race into a whole-process abort, so both the
--  deadline path and the multi-source wakeup path are exercised here.

procedure Closed_Descriptor_Wait_Smoke is
   use Ada.Streams;
   use type Ada.Real_Time.Time;

   protected Handshake is
      procedure Deadline_Armed;
      entry Wait_Until_Deadline_Armed;
      procedure Deadline_Result (Value : Boolean);
      entry Wait_Deadline_Result;
      function Deadline_Passed return Boolean;
      procedure Fanout_Armed;
      entry Wait_Until_Fanout_Armed;
      procedure Fanout_Result (Value : Natural);
      entry Wait_Fanout_Result;
      function Fanout_Index return Natural;
   private
      Deadline_Ready : Boolean := False;
      Deadline_Done  : Boolean := False;
      Deadline_OK    : Boolean := False;
      Fanout_Ready   : Boolean := False;
      Fanout_Done    : Boolean := False;
      Fanout_Value   : Natural := 0;
   end Handshake;

   protected body Handshake is
      procedure Deadline_Armed is
      begin
         Deadline_Ready := True;
      end Deadline_Armed;

      entry Wait_Until_Deadline_Armed when Deadline_Ready is
      begin
         null;
      end Wait_Until_Deadline_Armed;

      procedure Deadline_Result (Value : Boolean) is
      begin
         Deadline_OK := Value;
         Deadline_Done := True;
      end Deadline_Result;

      entry Wait_Deadline_Result when Deadline_Done is
      begin
         null;
      end Wait_Deadline_Result;

      function Deadline_Passed return Boolean
      is (Deadline_OK);

      procedure Fanout_Armed is
      begin
         Fanout_Ready := True;
      end Fanout_Armed;

      entry Wait_Until_Fanout_Armed when Fanout_Ready is
      begin
         null;
      end Wait_Until_Fanout_Armed;

      procedure Fanout_Result (Value : Natural) is
      begin
         Fanout_Value := Value;
         Fanout_Done := True;
      end Fanout_Result;

      entry Wait_Fanout_Result when Fanout_Done is
      begin
         null;
      end Wait_Fanout_Result;

      function Fanout_Index return Natural
      is (Fanout_Value);
   end Handshake;

   Watched      : Flyology.IO.Sockets.Socket_Type;
   Watched_Peer : Flyology.IO.Sockets.Socket_Type;
   Ready_Side   : Flyology.IO.Sockets.Socket_Type;
   Ready_Peer   : Flyology.IO.Sockets.Socket_Type;
   Closed_Side  : Flyology.IO.Sockets.Socket_Type;
   Closed_Peer  : Flyology.IO.Sockets.Socket_Type;

   --  A descriptor closed while its readiness interest is armed must expire
   --  through the ordinary deadline path instead of aborting the process.
   procedure Timeout_After_Close is
      Started : Ada.Real_Time.Time;
      Elapsed : Duration;
   begin
      Flyology.IO.Sockets.Create_Socket_Pair (Watched, Watched_Peer);
      Started := Ada.Real_Time.Clock;
      declare
         task Waiter is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Waiter;

         task Closer is
            pragma Task_Info (Flyology.Native_Task);
         end Closer;

         task body Waiter is
            FD : constant Flyology.IO.Descriptor := Flyology.IO.Sockets.Native_Descriptor (Watched);
         begin
            Handshake.Deadline_Armed;
            Handshake.Deadline_Result (not Flyology.IO.Wait (FD, Flyology.IO.For_Read, Timeout => 0.400));
         exception
            when others =>
               --  Device_Error is an acceptable outcome for a descriptor the
               --  caller destroyed while waiting; a process abort is not.
               Handshake.Deadline_Result (True);
         end Waiter;

         task body Closer is
         begin
            Handshake.Wait_Until_Deadline_Armed;
            --  Let the waiter reach the poller before the descriptor goes.
            Flyology.IO.Timers.Sleep_For (0.050);
            Flyology.IO.Sockets.Close_Socket (Watched);
         end Closer;
      begin
         Handshake.Wait_Deadline_Result;
      end;
      Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
      Flyology.IO.Sockets.Close_Socket (Watched_Peer);
      if not Handshake.Deadline_Passed then
         raise Program_Error with "wait on a closed descriptor did not expire";
      end if;
      if Elapsed > 5.0 then
         raise Program_Error with "wait on a closed descriptor did not respect its deadline";
      end if;
   end Timeout_After_Close;

   --  Waking a multi-source wait cancels the interests that did not fire. One
   --  of those descriptors is closed, which is the same rejected cancellation
   --  the deadline path sees, reached through the readiness path instead.
   procedure Fanout_After_Close is
      Probe : Stream_Element_Array (1 .. 1);
      Last  : Stream_Element_Offset;
   begin
      Flyology.IO.Sockets.Create_Socket_Pair (Ready_Side, Ready_Peer);
      Flyology.IO.Sockets.Create_Socket_Pair (Closed_Side, Closed_Peer);
      declare
         task Waiter is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Waiter;

         task Driver is
            pragma Task_Info (Flyology.Native_Task);
         end Driver;

         task body Waiter is
            Requests : constant Flyology.IO.Wait_Request_Array :=
              [(FD => Flyology.IO.Sockets.Native_Descriptor (Ready_Side), Condition => Flyology.IO.For_Read),
               (FD        => Flyology.IO.Sockets.Native_Descriptor (Closed_Side),
                Condition => Flyology.IO.For_Read)];
         begin
            Handshake.Fanout_Armed;
            Handshake.Fanout_Result (Flyology.IO.Wait_Any (Requests, Timeout => 2.0));
         exception
            when others =>
               Handshake.Fanout_Result (0);
         end Waiter;

         task body Driver is
         begin
            Handshake.Wait_Until_Fanout_Armed;
            Flyology.IO.Timers.Sleep_For (0.050);
            Flyology.IO.Sockets.Close_Socket (Closed_Side);
            Flyology.IO.Sockets.Send_All (Ready_Peer, [1 => 77], Timeout => 1.0);
         end Driver;
      begin
         Handshake.Wait_Fanout_Result;
      end;
      if Handshake.Fanout_Index /= 1 then
         raise Program_Error with "multi-source wait did not report the ready descriptor";
      end if;
      Flyology.IO.Sockets.Receive (Ready_Side, Probe, Last, Timeout => 1.0);
      if Last /= Probe'Last or else Probe (1) /= 77 then
         raise Program_Error with "multi-source wait reported readiness without data";
      end if;
      Flyology.IO.Sockets.Close_Socket (Ready_Side);
      Flyology.IO.Sockets.Close_Socket (Ready_Peer);
      Flyology.IO.Sockets.Close_Socket (Closed_Peer);
   end Fanout_After_Close;

begin
   Timeout_After_Close;
   Fanout_After_Close;
end Closed_Descriptor_Wait_Smoke;
