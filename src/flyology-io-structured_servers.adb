with Ada.Exceptions;
with Flyology.Counter_Policy;
with Flyology.IO.Sockets;
with GNAT.OS_Lib;
with Interfaces.C;
package body Flyology.IO.Structured_Servers is
   package Connections renames Flyology.IO.Connections;
   package Counters renames Flyology.Counter_Policy;
   package Sockets renames GNAT.Sockets;

   use type Sockets.Socket_Type;
   use type Interfaces.C.int;

   function C_Close_Listener
     (Descriptor : Interfaces.C.int) return Interfaces.C.int;
   pragma Import
     (C, C_Close_Listener, "flyology_structured_listener_close");

   protected body Lifecycle is
      procedure Begin_Serve (Expected : Positive) is
      begin
         case Phase is
            when Idle =>
               null;
            when Stop_Requested =>
               if Serve_Started then
                  raise Program_Error with "structured server is one-shot";
               end if;
            when Serving | Finished =>
               raise Program_Error with "structured server is one-shot";
         end case;
         Serve_Started := True;
         if Phase = Idle then
            Phase := Serving;
         end if;
         Workers_Done := 0;
         Expected_Workers := Expected;
      end Begin_Serve;

      procedure Request_Stop (New_Request : out Boolean) is
      begin
         New_Request := Phase in Idle | Serving;
         if New_Request then
            Phase := Stop_Requested;
         end if;
      end Request_Stop;

      entry Await_Stop when Phase = Stop_Requested is
      begin
         null;
      end Await_Stop;

      function Stop_Was_Requested return Boolean is
        (Phase = Stop_Requested or else Phase = Finished);

      procedure Handler_Started is
      begin
         if Active >= Expected_Workers then
            raise Program_Error with "handler admission exceeds capacity";
         end if;
         Active := Active + 1;
         Accepted := Counters.Saturating_Increment (Accepted);
      end Handler_Started;

      procedure Handler_Completed
        (Cancelled : Boolean;
         Failed    : Boolean)
      is
      begin
         if Active = 0 then
            raise Program_Error with "handler completion without admission";
         end if;
         Active := Active - 1;
         if Cancelled then
            Lifecycle.Cancelled :=
              Counters.Saturating_Increment (Lifecycle.Cancelled);
         elsif not Failed then
            Completed := Counters.Saturating_Increment (Completed);
         end if;
      end Handler_Completed;

      procedure Worker_Finished is
      begin
         if Workers_Done >= Expected_Workers then
            raise Program_Error with
              "structured server worker completion exceeds capacity";
         end if;
         Workers_Done := Workers_Done + 1;
      end Worker_Finished;

      procedure Record_Failure
        (Origin      : Failure_Origin;
         Information : String)
      is
         Length : constant Natural :=
           Natural'Min (Information'Length, Failure_Text'Length);
      begin
         Failure_Total := Failure_Total + 1;
         if Failure_Source = No_Failure then
            Failure_Source := Origin;
            Failure_Text_Length := Length;
            if Length > 0 then
               Failure_Text (1 .. Length) :=
                 Information
                   (Information'First .. Information'First + Length - 1);
            end if;
         end if;
         if Phase in Idle | Serving then
            Phase := Stop_Requested;
         end if;
      end Record_Failure;

      procedure Mark_Forced is
      begin
         Forced := True;
      end Mark_Forced;

      procedure Finish_Serve is
      begin
         if Workers_Done /= Expected_Workers or else Active /= 0 then
            raise Program_Error with
              "structured server finished with live handlers";
         end if;
         Phase := Finished;
         Workers_Done := 0;
         Expected_Workers := 0;
      end Finish_Serve;

      procedure Abandon_Serve is
      begin
         --  The task scope has joined before Serve's outer handler runs, so
         --  no worker can publish another completion after this reset.
         Phase := Finished;
         Active := 0;
         Workers_Done := 0;
         Expected_Workers := 0;
      end Abandon_Serve;

      entry Await_All_Workers
        when Expected_Workers > 0 and then Workers_Done >= Expected_Workers
      is
      begin
         null;
      end Await_All_Workers;

      function Read_Snapshot return Snapshot is
        (Running               =>
           Serve_Started and then Phase in Serving | Stop_Requested,
         Shutdown_Requested    => Phase in Stop_Requested | Finished,
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

   function Current (Item : Server) return Snapshot is
     (Item.State.Read_Snapshot);

   function First_Failure_Information (Item : Server) return String is
     (Item.State.Failure_Information);

   procedure Close_Owned_Listener (Item : in out Server) is
      Result : Interfaces.C.int;
   begin
      if Item.Owned_Listener /= Sockets.No_Socket then
         Result := C_Close_Listener
           (Flyology.IO.Sockets.Native_Descriptor (Item.Owned_Listener));
         if Result /= 0 then
            raise Sockets.Socket_Error with
              "listener close failed, errno=" & GNAT.OS_Lib.Errno'Image;
         end if;
         Item.Owned_Listener := Sockets.No_Socket;
      end if;
   end Close_Owned_Listener;

   procedure Serve
     (Item          : aliased in out Server;
      Listener      : in out Sockets.Socket_Type;
      Context       : aliased in out Handler_Context;
      Drain_Timeout : Duration := Infinite)
   is
      Manager : aliased Connections.Server (Capacity => Item.Capacity);
      Began : Boolean := False;

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

   begin
      if Listener = Sockets.No_Socket then
         raise Program_Error with
           "structured server requires a listening socket";
      end if;

      Item.State.Begin_Serve (Item.Capacity);
      Began := True;
      Item.Owned_Listener := Listener;
      Listener := Sockets.No_Socket;

      declare
         task type Worker with CPU => Handler_CPU is
            pragma Task_Info (Handler_Model);
         end Worker;

         task body Worker is
            Stop_Worker : Boolean := False;
            Completion_Reported : Boolean := False;

            procedure Report_Completion is
            begin
               if not Completion_Reported then
                  Completion_Reported := True;
                  Item.State.Worker_Finished;
               end if;
            end Report_Completion;

            procedure Report
              (Origin : Failure_Origin;
               Event  : Ada.Exceptions.Exception_Occurrence)
            is
            begin
               Item.State.Record_Failure
                 (Origin, Ada.Exceptions.Exception_Information (Event));
               Stop_Accepting;
            end Report;
         begin
            begin
               while not Stop_Worker loop
                  declare
                     Connection : Connections.Connection;
                     Peer       : Sockets.Sock_Addr_Type;
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
                        when Connections.Operation_Cancelled |
                             Connections.Admission_Closed =>
                           Stop_Worker := True;
                        when Event : others =>
                           Report (Admission_Loop, Event);
                           Stop_Worker := True;
                     end;

                     if Admitted then
                        begin
                           Handle
                             (Context,
                              Connection,
                              Peer,
                              Item.Handler_Stop'Access);
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
               Item.State.Record_Failure
                 (Admission_Loop,
                  Ada.Exceptions.Exception_Information (Event));
               Report_Completion;
         end Worker;

         Workers : array (1 .. Item.Capacity) of Worker;
         pragma Unreferenced (Workers);
      begin
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
      exception
         when others =>
            Stop_Accepting;
            Force_Handlers;
            raise;
      end;

      Close_Owned_Listener (Item);
      Item.State.Finish_Serve;
      if Item.State.Read_Snapshot.Failures > 0 then
         raise Server_Failed with Item.State.Failure_Information;
      end if;
   exception
      when Event : others =>
         if Began and then Item.State.Read_Snapshot.Running then
            --  Cleanup failures must not leave the one-shot lifecycle
            --  appearing reusable. Each action is isolated so terminalization
            --  always runs after a successfully begun Serve call.
            begin
               Stop_Accepting;
            exception
               when others =>
                  null;
            end;
            if Item.Owned_Listener /= Sockets.No_Socket then
               begin
                  Close_Owned_Listener (Item);
               exception
                  when others =>
                     null;
               end;
            end if;
            Item.State.Abandon_Serve;
         end if;
         Ada.Exceptions.Reraise_Occurrence (Event);
   end Serve;

   overriding procedure Finalize (Item : in out Server) is
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
