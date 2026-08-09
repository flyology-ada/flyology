with Flyology;
with Flyology.IO.Sockets;
with Flyology.IO.TLS;
with Flyology.IO.TLS.Testing;
with Interfaces.C;
with TLS_Test_Provider;

--  Take transfers descriptor, session, and socket ownership as one step. A
--  task abort delivered inside that transfer must leave either a connection
--  that owns everything or a socket that still owns the descriptor, and it
--  must never leak a provider session.
procedure TLS_Take_Abort is
   package TLS renames Flyology.IO.TLS;
   package Testing renames Flyology.IO.TLS.Testing;
   package Provider renames TLS_Test_Provider;
   package Sockets renames Flyology.IO.Sockets;

   use type Interfaces.C.int;

   type Model_Array is array (Positive range <>) of Flyology.Execution_Model;
   Models : constant Model_Array :=
     [Flyology.Lightweight_Task, Flyology.Native_Task];

   function Open_FD_Count return Interfaces.C.int
     with Import, Convention => C,
          External_Name => "flyology_test_open_fd_count";

   --  Triggering alternative for the asynchronous transfer of control that
   --  aborts Take. The entry stays queued until the observer task has seen
   --  the aborted task park inside the transfer.
   protected type Gate is
      procedure Open;
      entry Wait;
   private
      Opened : Boolean := False;
   end Gate;

   protected body Gate is
      procedure Open is
      begin
         Opened := True;
      end Open;

      entry Wait when Opened is
      begin
         null;
      end Wait;
   end Gate;

   --  Records whether the aborted task ever resumed after Take.
   protected type Completion is
      procedure Report;
      function Reported return Boolean;
   private
      Seen : Boolean := False;
   end Completion;

   protected body Completion is
      procedure Report is
      begin
         Seen := True;
      end Report;

      function Reported return Boolean is (Seen);
   end Completion;

   procedure Close_If_Open (Socket : in out Sockets.Socket_Type) is
   begin
      if Sockets.Is_Open (Socket) then
         Sockets.Close_Socket (Socket);
      end if;
   exception
      when others =>
         null;
   end Close_If_Open;

   procedure Warm_Model (Model : Flyology.Execution_Model) is
      task Worker is
         pragma Task_Info (Model);
      end Worker;

      task body Worker is
      begin
         delay 0.0;
      end Worker;
   begin
      null;
   end Warm_Model;

   procedure Run_One
     (Point : Testing.Take_Barrier_Point;
      Model : Flyology.Execution_Model)
   is
      Backend : Provider.Provider;
      Conn    : TLS.Connection;
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
      Trigger : Gate;
      Resumed : Completion;
      State   : Provider.State_Telemetry;
      Owned   : Boolean;
   begin
      Provider.Reset_State_Telemetry;
      Testing.Reset_Take_Barriers;
      Sockets.Create_Socket_Pair (Socket, Peer);
      Testing.Arm (Point);

      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
         begin
            select
               Trigger.Wait;
            then abort
               TLS.Take (Backend, Socket, TLS.Server, "", Conn);
               Resumed.Report;
            end select;
         exception
            when others =>
               null;
         end Worker;
      begin
         Testing.Wait_Reached (Point);
         Trigger.Open;
         --  An unprotected transfer is abandoned here, while the barrier
         --  still holds the aborted task inside Take.
         delay 0.100;
         Testing.Release (Point);
      end;

      --  The abort must really have interrupted Take; otherwise the barrier
      --  no longer covers the ownership transfer.
      pragma Assert (not Resumed.Reported);

      Owned := TLS.Is_Open (Conn);
      Provider.Get_State_Telemetry (State);
      if Owned then
         --  The connection took the descriptor, so the caller's socket must
         --  no longer own it and the session must be installed.
         pragma Assert (not Sockets.Is_Open (Socket));
         pragma Assert (State.Sessions_Live = 1);
      else
         --  Nothing was transferred, so the caller keeps the descriptor and
         --  the abandoned session must not survive.
         pragma Assert (Sockets.Is_Open (Socket));
         pragma Assert (State.Sessions_Live = 0);
      end if;

      TLS.Close (Conn);
      Close_If_Open (Socket);
      Close_If_Open (Peer);

      Provider.Get_State_Telemetry (State);
      pragma Assert (State.Sessions_Live = 0);
      pragma Assert (State.Sessions_Created = State.Sessions_Finalized);
   end Run_One;

   procedure Run_Checked
     (Point : Testing.Take_Barrier_Point;
      Model : Flyology.Execution_Model)
   is
      Baseline : Interfaces.C.int;
   begin
      Warm_Model (Model);
      Baseline := Open_FD_Count;
      Run_One (Point, Model);
      pragma Assert (Open_FD_Count = Baseline);
   end Run_Checked;

begin
   Testing.Check_Take_Barrier_State_Machine;
   for Model of Models loop
      for Point in Testing.Take_Barrier_Point loop
         Run_Checked (Point, Model);
      end loop;
   end loop;
end TLS_Take_Abort;
