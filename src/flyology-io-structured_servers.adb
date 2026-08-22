with Ada.Exceptions;
with Flyology.Counter_Policy;
with Flyology.Structured_Server_Test_Hooks;
with GNAT.OS_Lib;
with Interfaces.C;

package body Flyology.IO.Structured_Servers is
   package Connections renames Flyology.IO.Connections;
   package Counters renames Flyology.Counter_Policy;
   package Sockets renames Flyology.IO.Sockets;
   package Test_Hooks renames Flyology.Structured_Server_Test_Hooks;

   use type Interfaces.C.int;
   use type Policy.Run_Phase;

   function C_Close_Listener (Descriptor : Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, C_Close_Listener, "flyology_structured_listener_close");

   type Listener_Close_Guard
     (Source : not null access Sockets.Socket_Type;
      Result : not null access Interfaces.C.int)
   is new Ada.Finalization.Limited_Controlled with record
      Value : Descriptor := Invalid_Descriptor;
   end record;

   overriding
   procedure Initialize (Item : in out Listener_Close_Guard);
   overriding
   procedure Finalize (Item : in out Listener_Close_Guard);

   overriding
   procedure Initialize (Item : in out Listener_Close_Guard) is
   begin
      --  Controlled initialization is abort-deferred. Transfer both halves of
      --  socket ownership here so an abort cannot observe duplicate owners.
      Sockets.Release (Item.Source.all, Item.Value);
   end Initialize;

   overriding
   procedure Finalize (Item : in out Listener_Close_Guard) is
   begin
      if Item.Value /= Invalid_Descriptor then
         if Test_Hooks.Enabled then
            Test_Hooks.Barrier (4);
         end if;
         Item.Result.all := C_Close_Listener (Item.Value);
         Policy.Consume_After_Close_Attempt (Item.Value);
      end if;
   end Finalize;

   protected body Lifecycle is
      procedure Begin_Serve (Expected : Positive) is
      begin
         if not Policy.Begin_Allowed (Phase, Serve_Started) then
            raise Program_Error with "structured server is one-shot";
         end if;
         Serve_Started := True;
         Phase := Policy.Phase_After_Begin (Phase);
         Accepting_Marked := False;
         Workers_Done := 0;
         Expected_Workers := Expected;
      end Begin_Serve;

      procedure Request_Stop (New_Request : out Boolean) is
      begin
         New_Request := Policy.Stop_Is_New (Phase);
         Phase := Policy.Phase_After_Stop (Phase);
         Accepting_Marked := False;
      end Request_Stop;

      entry Await_Stop when Phase = Stop_Requested is
      begin
         null;
      end Await_Stop;

      function Stop_Was_Requested return Boolean
      is (Policy.Stop_Was_Requested (Phase));

      procedure Mark_Accepting is
      begin
         Accepting_Marked := Policy.Accepting_After_Worker_Start (Phase);
      end Mark_Accepting;

      procedure Handler_Started is
      begin
         if not Policy.Handler_Start_Allowed (Active, Expected_Workers) then
            raise Program_Error with "handler admission exceeds capacity";
         end if;
         Active := Active + 1;
         Accepted := Counters.Saturating_Increment (Accepted);
      end Handler_Started;

      procedure Handler_Completed (Cancelled : Boolean; Failed : Boolean) is
      begin
         if Active = 0 then
            raise Program_Error with "handler completion without admission";
         end if;
         Active := Active - 1;
         if Cancelled then
            Lifecycle.Cancelled := Counters.Saturating_Increment (Lifecycle.Cancelled);
         elsif not Failed then
            Completed := Counters.Saturating_Increment (Completed);
         end if;
      end Handler_Completed;

      procedure Worker_Finished is
      begin
         if not Policy.Worker_Finish_Allowed (Workers_Done, Expected_Workers) then
            raise Program_Error with "structured server worker completion exceeds capacity";
         end if;
         Workers_Done := Workers_Done + 1;
      end Worker_Finished;

      procedure Record_Failure (Origin : Failure_Origin; Information : String) is
         Length : constant Natural := Natural'Min (Information'Length, Failure_Text'Length);
      begin
         Failure_Total := Failure_Total + 1;
         if Failure_Source = No_Failure then
            Failure_Source := Origin;
            Failure_Text_Length := Length;
            if Length > 0 then
               Failure_Text (1 .. Length) :=
                 Information (Information'First .. Information'First + Length - 1);
            end if;
         end if;
         Phase := Policy.Phase_After_Stop (Phase);
         Accepting_Marked := False;
      end Record_Failure;

      procedure Mark_Forced is
      begin
         Forced := True;
      end Mark_Forced;

      procedure Finish_Serve is
      begin
         if not Policy.Serve_Finish_Allowed (Workers_Done, Expected_Workers, Active) then
            raise Program_Error with "structured server finished with live handlers";
         end if;
         Phase := Finished;
         Accepting_Marked := False;
         Workers_Done := 0;
         Expected_Workers := 0;
      end Finish_Serve;

      procedure Abandon_Serve is
      begin
         --  The task scope has joined before Serve's outer cleanup guard
         --  finalizes, so no worker can publish after this reset.
         Phase := Finished;
         Accepting_Marked := False;
         Active := 0;
         Workers_Done := 0;
         Expected_Workers := 0;
      end Abandon_Serve;

      entry Await_All_Workers when Expected_Workers > 0 and then Workers_Done >= Expected_Workers is
      begin
         null;
      end Await_All_Workers;

      function Read_Snapshot return Snapshot
      is (Running               => Policy.Snapshot_Running (Serve_Started, Phase),
          Accepting             => Policy.Snapshot_Accepting (Accepting_Marked, Phase),
          Shutdown_Requested    => Policy.Snapshot_Shutdown (Phase),
          Forced_Cancellation   => Forced,
          Active_Handlers       => Active,
          Accepted_Connections  => Accepted,
          Completed_Connections => Completed,
          Cancelled_Connections => Cancelled,
          Failures              => Failure_Total,
          First_Failure         => Failure_Source);

      function Failure_Information return String is
      begin
         if Failure_Text_Length = 0 then
            return "";
         else
            return Failure_Text (1 .. Failure_Text_Length);
         end if;
      end Failure_Information;
   end Lifecycle;

   procedure Request_Shutdown (Item : in out Server) is
      New_Request : Boolean;
   begin
      Item.State.Request_Stop (New_Request);
      if New_Request then
         Item.Accept_Stop.Request;
      end if;
   end Request_Shutdown;

   function Current (Item : Server) return Snapshot
   is (Item.State.Read_Snapshot);

   function First_Failure_Information (Item : Server) return String
   is (Item.State.Failure_Information);

   procedure Close_Owned_Listener (Item : in out Server) is
      Result : aliased Interfaces.C.int := 0;
   begin
      if Sockets.Is_Open (Item.Owned_Listener) then
         declare
            Guard : Listener_Close_Guard (Item.Owned_Listener'Access, Result'Access);
            pragma Unreferenced (Guard);
         begin
            --  Initialization transfers ownership and finalization performs
            --  the single close; both callbacks are abort-deferred.
            null;
         end;
         if Result /= 0 then
            raise Sockets.Socket_Error with "listener close failed, errno=" & GNAT.OS_Lib.Errno'Image;
         end if;
      end if;
   end Close_Owned_Listener;

   procedure Serve
     (Item          : aliased in out Server;
      Listener      : in out Sockets.Socket_Type;
      Context       : aliased in out Handler_Context;
      Drain_Timeout : Duration := Infinite)
   is
      Manager : aliased Connections.Server (Capacity => Item.Capacity);

      procedure Stop_Accepting is
      begin
         Item.Accept_Stop.Request;
      end Stop_Accepting;

      procedure Force_Handlers is
      begin
         Item.State.Mark_Forced;
         Item.Handler_Stop.Request;
         Manager.Request_Shutdown;
      end Force_Handlers;

      type Serve_Cleanup_Guard is new Ada.Finalization.Limited_Controlled with record
         Transfer : Descriptor := Invalid_Descriptor;
         Armed    : Boolean := False;
      end record;

      overriding
      procedure Initialize (Guard : in out Serve_Cleanup_Guard);
      overriding
      procedure Finalize (Guard : in out Serve_Cleanup_Guard);
      procedure Complete (Armed : in out Boolean);

      type Worker_Cleanup_Guard (Armed : not null access Boolean) is new Ada.Finalization.Limited_Controlled
      with null record;

      overriding
      procedure Finalize (Guard : in out Worker_Cleanup_Guard);

      overriding
      procedure Initialize (Guard : in out Serve_Cleanup_Guard) is
      begin
         if Sockets.Is_Open (Item.Owned_Listener) then
            raise Program_Error with "structured server already owns a listener";
         end if;

         Item.State.Begin_Serve (Item.Capacity);
         begin
            --  Controlled initialization is abort-deferred. Keep the
            --  descriptor in exactly one of Listener, Transfer, or
            --  Owned_Listener while moving it into the server.
            Sockets.Release (Listener, Guard.Transfer);
            if Test_Hooks.Enabled then
               Test_Hooks.Barrier (1);
            end if;
            Sockets.Adopt (Guard.Transfer, Item.Owned_Listener);
            Guard.Armed := True;
         exception
            when others =>
               --  Initialization failure does not finalize Guard. Restore the
               --  caller's ownership before making the begun lifecycle
               --  terminal.
               if Guard.Transfer /= Invalid_Descriptor then
                  Sockets.Adopt (Guard.Transfer, Listener);
               end if;
               Item.State.Abandon_Serve;
               raise;
         end;
      end Initialize;

      overriding
      procedure Finalize (Guard : in out Serve_Cleanup_Guard) is
      begin
         if not Guard.Armed then
            return;
         end if;

         --  This finalizer is abort-deferred and the nested worker scope has
         --  already joined. Isolate every cleanup action so listener release
         --  and terminal lifecycle publication survive owner abort.
         begin
            Stop_Accepting;
         exception
            when others =>
               null;
         end;
         begin
            Item.Handler_Stop.Request;
         exception
            when others =>
               null;
         end;
         begin
            Manager.Request_Shutdown;
         exception
            when others =>
               null;
         end;
         begin
            Close_Owned_Listener (Item);
         exception
            when others =>
               null;
         end;
         begin
            Item.State.Abandon_Serve;
         exception
            when others =>
               null;
         end;
         Guard.Armed := False;
      end Finalize;

      overriding
      procedure Finalize (Guard : in out Worker_Cleanup_Guard) is
      begin
         if not Guard.Armed.all then
            return;
         end if;

         --  This nested guard finalizes before the task master joins Workers.
         --  Wake blocked lifecycle I/O first so native workers do not strand
         --  an aborted Serve caller at the join boundary.
         begin
            Stop_Accepting;
         exception
            when others =>
               null;
         end;
         begin
            Item.Handler_Stop.Request;
         exception
            when others =>
               null;
         end;
         begin
            Manager.Request_Shutdown;
         exception
            when others =>
               null;
         end;
         Guard.Armed.all := False;
      end Finalize;

      procedure Complete (Armed : in out Boolean) is
      begin
         --  Close before publishing Finished. If close or lifecycle
         --  validation raises, Guard remains armed and its finalizer completes
         --  terminalization without retrying a descriptor already released by
         --  Listener_Close_Guard.
         Close_Owned_Listener (Item);
         Item.State.Finish_Serve;
         Armed := False;
      end Complete;

   begin
      if not Sockets.Is_Open (Listener) then
         raise Program_Error with "structured server requires a listening socket";
      end if;

      if Test_Hooks.Enabled then
         Test_Hooks.Barrier (0);
      end if;

      declare
         Cleanup : Serve_Cleanup_Guard;
      begin
         if Test_Hooks.Enabled then
            Test_Hooks.Barrier (2);
         end if;
         declare
            task type Worker with CPU => Handler_CPU is
               pragma Task_Info (Handler_Model);
               entry Start;
            end Worker;

            task body Worker is
               Activation_Checked  : constant Boolean :=
                 (if Test_Hooks.Enabled then Test_Hooks.Check_Activation else True);
               pragma Unreferenced (Activation_Checked);
               Stop_Worker         : Boolean := False;
               Completion_Reported : Boolean := False;

               procedure Report_Completion is
               begin
                  if not Completion_Reported then
                     Completion_Reported := True;
                     Item.State.Worker_Finished;
                  end if;
               end Report_Completion;

               procedure Report (Origin : Failure_Origin; Event : Ada.Exceptions.Exception_Occurrence) is
               begin
                  Item.State.Record_Failure (Origin, Ada.Exceptions.Exception_Information (Event));
                  Stop_Accepting;
               end Report;
            begin
               --  Do not enter admission work until every worker has
               --  activated and the nested cleanup guard is installed. If a
               --  sibling activation fails, already-live workers can select
               --  terminate while the enclosing master completes.
               select
                  accept Start;
               or
                  terminate;
               end select;

               begin
                  while not Stop_Worker loop
                     declare
                        --  Binding the connection to Manager makes the
                        --  borrowed-admission lifetime a compiler-checked
                        --  property of this handler scope.
                        Connection : Connections.Connection (Manager'Access);
                        Peer       : Sockets.Endpoint;
                        Admitted   : Boolean := False;
                        Cancelled  : Boolean := False;
                        Failed     : Boolean := False;
                     begin
                        begin
                           Connections.Accept_Connection
                             (Manager  => Manager,
                              Listener => Item.Owned_Listener,
                              Item     => Connection,
                              Address  => Peer,
                              Token    => Item.Accept_Stop'Access);
                           Admitted := True;
                           Item.State.Handler_Started;
                        exception
                           when Connections.Operation_Cancelled | Connections.Admission_Closed =>
                              Stop_Worker := True;
                           when Event : others =>
                              Report (Admission_Loop, Event);
                              Stop_Worker := True;
                        end;

                        if Admitted then
                           begin
                              Handle (Context, Connection, Peer, Item.Handler_Stop'Access);
                           exception
                              when Connections.Operation_Cancelled =>
                                 Cancelled := True;
                              when Event : others =>
                                 Report (Handler_Callback, Event);
                                 Failed := True;
                           end;

                           begin
                              Connections.Close (Connection);
                           exception
                              when Event : others =>
                                 Report (Handler_Callback, Event);
                                 Failed := True;
                           end;
                           Item.State.Handler_Completed (Cancelled, Failed);
                        end if;
                     end;

                     exit when Item.State.Stop_Was_Requested;
                  end loop;
               exception
                  when Event : others =>
                     Report (Admission_Loop, Event);
               end;
               Report_Completion;
            exception
               when Event : others =>
                  --  Preserve the task-scope join even if bookkeeping itself
                  --  detects an invariant failure.
                  Item.State.Record_Failure (Admission_Loop, Ada.Exceptions.Exception_Information (Event));
                  Report_Completion;
            end Worker;

            Workers : array (1 .. Item.Capacity) of Worker;
         begin
            if Test_Hooks.Enabled then
               Test_Hooks.Barrier (6);
            end if;
            declare
               Worker_Cleanup_Armed : aliased Boolean := True;
               Worker_Cleanup       : Worker_Cleanup_Guard (Worker_Cleanup_Armed'Access);
               pragma Unreferenced (Worker_Cleanup);
            begin
               for Index in Workers'Range loop
                  Workers (Index).Start;
               end loop;
               Item.State.Mark_Accepting;
               if Test_Hooks.Enabled then
                  Test_Hooks.Barrier (3);
               end if;
               if Item.State.Stop_Was_Requested then
                  Stop_Accepting;
               else
                  Item.State.Await_Stop;
                  Stop_Accepting;
               end if;

               if Drain_Timeout = Infinite then
                  Item.State.Await_All_Workers;
               else
                  select
                     Item.State.Await_All_Workers;
                  or
                     delay Drain_Timeout;
                     Force_Handlers;
                     Item.State.Await_All_Workers;
                  end select;
               end if;
               Worker_Cleanup_Armed := False;
            end;
         exception
            when others =>
               Stop_Accepting;
               Force_Handlers;
               raise;
         end;

         Complete (Cleanup.Armed);
      end;

      if Item.State.Read_Snapshot.Failures > 0 then
         raise Server_Failed with Item.State.Failure_Information;
      end if;
   end Serve;

   overriding
   procedure Finalize (Item : in out Server) is
      Was_Running : constant Boolean := Item.State.Read_Snapshot.Running;
   begin
      begin
         if Was_Running then
            Request_Shutdown (Item);
            Item.Handler_Stop.Request;
         end if;
      exception
         when others =>
            null;
      end;

      if not Was_Running then
         begin
            Close_Owned_Listener (Item);
         exception
            when others =>
               null;
         end;
      end if;
   end Finalize;

end Flyology.IO.Structured_Servers;
