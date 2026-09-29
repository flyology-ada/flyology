with Ada.Real_Time;
with Ada.Text_IO;
with Flyology;
with Flyology.IO.Connections;
with Flyology.IO.Connections.Testing;
with Flyology.IO.Sockets;
with GNAT.OS_Lib;
with Interfaces.C;

--  Close takes exclusive close leadership in one protected action and only
--  gives it back in a later one. This program aborts the leader inside that
--  window and requires the connection to reach its terminal state anyway:
--  the socket is closed, the admission permit is released, and both a later
--  Close and the aborted task's own finalization complete.

procedure Connection_Close_Abort_Smoke is
   package Connections renames Flyology.IO.Connections;
   package Testing renames Flyology.IO.Connections.Testing;
   package Sockets renames Flyology.IO.Sockets;

   use type Ada.Real_Time.Time;
   use type Interfaces.C.int;

   function Open_FD_Count return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_open_fd_count";

   Termination_Limit : constant Ada.Real_Time.Time_Span := Ada.Real_Time.Seconds (5);
   Close_Limit       : constant Duration := 5.0;

   --  A wedged controller strands every later Close in an abort-deferred
   --  entry call, including the finalization of this program's own objects.
   --  Report the defect and leave the process before that can happen.
   procedure Fail_Fast (Message : String) is
   begin
      Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "connection close abort: " & Message);
      Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
      GNAT.OS_Lib.OS_Exit (1);
   end Fail_Fast;

   procedure Close_If_Open (Socket : in out Sockets.Socket_Type) is
   begin
      if Sockets.Is_Open (Socket) then
         Sockets.Close_Socket (Socket);
      end if;
   exception
      when others =>
         null;
   end Close_If_Open;

   procedure Assert_Descriptors (Before : Interfaces.C.int; Label : String) is
      After : constant Interfaces.C.int := Open_FD_Count;
   begin
      if After /= Before then
         raise Program_Error
           with Label & " leaked descriptors: before=" & Before'Image & ", after=" & After'Image;
      end if;
   end Assert_Descriptors;

   --  The leader closes a connection that outlives it, so the aborted task
   --  itself always terminates. The wedge is observed by the surviving
   --  owner: its Close must still complete and its permit must come back.
   procedure Run_Shared_Connection (Model : Flyology.Execution_Model; Lane : String) is
      Before : constant Interfaces.C.int := Open_FD_Count;
      Label  : constant String := "shared connection " & Lane;
   begin
      declare
         Manager    : aliased Connections.Server (Capacity => 1);
         Item       : Connections.Connection;
         Owned      : Sockets.Socket_Type;
         Peer       : Sockets.Socket_Type;
         Closed     : Boolean := False;
         Close_Fail : Boolean := False;
      begin
         Sockets.Create_Socket_Pair (Owned, Peer);
         Connections.Take (Manager, Owned, Item);
         Testing.Reset_Barriers;
         Testing.Arm (Testing.Close_Leadership_Taken);

         declare
            task Leader is
               pragma Task_Info (Model);
            end Leader;

            task body Leader is
            begin
               Connections.Close (Item);
            exception
               when others =>
                  null;
            end Leader;
         begin
            Testing.Wait_Reached (Testing.Close_Leadership_Taken);
            abort Leader;
            declare
               Deadline : constant Ada.Real_Time.Time := Ada.Real_Time.Clock + Termination_Limit;
            begin
               while not Leader'Terminated loop
                  if Ada.Real_Time.Clock >= Deadline then
                     Fail_Fast (Label & ": aborted close leader never terminated");
                  end if;
                  delay 0.005;
               end loop;
            end;
            Testing.Release (Testing.Close_Leadership_Taken);
         exception
            when others =>
               Testing.Release (Testing.Close_Leadership_Taken);
               raise;
         end;

         --  A wedged connection parks this call in Await_Closed forever, so
         --  bound it with an asynchronous transfer of control instead of
         --  hanging the suite.
         select
            delay Close_Limit;
         then abort
            begin
               Connections.Close (Item);
               Closed := True;
            exception
               when others =>
                  Close_Fail := True;
            end;
         end select;

         if Close_Fail then
            Fail_Fast (Label & ": close after an aborted leader failed");
         elsif not Closed then
            Fail_Fast (Label & ": close after an aborted leader never completed");
         elsif Connections.Is_Open (Item) then
            Fail_Fast (Label & ": connection stayed open after close");
         elsif Manager.Active /= 0 then
            Fail_Fast (Label & ": aborted close leader leaked its admission permit");
         end if;
         Close_If_Open (Peer);
      end;
      Assert_Descriptors (Before, Label);
   end Run_Shared_Connection;

   --  The connection lives in the aborted task, so abort unwinding runs its
   --  finalization. A wedged controller makes that abort-deferred Close wait
   --  for a completion that can never arrive and the task never terminates.
   procedure Run_Owned_Connection (Model : Flyology.Execution_Model; Lane : String) is
      Before : constant Interfaces.C.int := Open_FD_Count;
      Label  : constant String := "owned connection " & Lane;
   begin
      declare
         Manager : aliased Connections.Server (Capacity => 1);
         Owned   : Sockets.Socket_Type;
         Peer    : Sockets.Socket_Type;
      begin
         Sockets.Create_Socket_Pair (Owned, Peer);
         Testing.Reset_Barriers;
         Testing.Arm (Testing.Close_Leadership_Taken);

         declare
            task Worker is
               pragma Task_Info (Model);
            end Worker;

            task body Worker is
               Item : Connections.Connection;
            begin
               Connections.Take (Manager, Owned, Item);
               Connections.Close (Item);
            exception
               when others =>
                  null;
            end Worker;
         begin
            Testing.Wait_Reached (Testing.Close_Leadership_Taken);
            abort Worker;
            declare
               Deadline : constant Ada.Real_Time.Time := Ada.Real_Time.Clock + Termination_Limit;
            begin
               while not Worker'Terminated loop
                  if Ada.Real_Time.Clock >= Deadline then
                     Fail_Fast
                       (Label
                        & ": aborted worker never terminated, so its"
                        & " connection finalization is deadlocked");
                  end if;
                  delay 0.005;
               end loop;
            end;
            Testing.Release (Testing.Close_Leadership_Taken);
         exception
            when others =>
               Testing.Release (Testing.Close_Leadership_Taken);
               raise;
         end;

         if Manager.Active /= 0 then
            Fail_Fast (Label & ": aborted worker leaked its admission permit");
         end if;
         Close_If_Open (Peer);
      end;
      Assert_Descriptors (Before, Label);
   end Run_Owned_Connection;

begin
   --  Lazy event-loop descriptors are process-lifetime resources. Start the
   --  loop before taking per-scenario descriptor baselines.
   declare
      task Warmup is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Warmup;
      task body Warmup is
      begin
         delay 0.0;
      end Warmup;
   begin
      null;
   end;

   Run_Shared_Connection (Flyology.Native_Task, "native");
   Run_Shared_Connection (Flyology.Lightweight_Task, "lightweight");
   Run_Owned_Connection (Flyology.Native_Task, "native");
   Run_Owned_Connection (Flyology.Lightweight_Task, "lightweight");
   Testing.Reset_Barriers;
end Connection_Close_Abort_Smoke;
