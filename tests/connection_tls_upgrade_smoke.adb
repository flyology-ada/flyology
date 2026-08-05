with Ada.Real_Time;
with Ada.Streams;
with Flyology;
with Flyology.IO.Connections;
with Flyology.IO.Connections.Testing;
with Flyology.IO.Connections.TLS;
with Flyology.IO.Sockets;
with Flyology.IO.TLS;
with TLS_Test_Provider;

procedure Connection_TLS_Upgrade_Smoke is
   package Connections renames Flyology.IO.Connections;
   package Connection_Testing renames Flyology.IO.Connections.Testing;
   package Connection_TLS renames Flyology.IO.Connections.TLS;
   package Sockets renames Flyology.IO.Sockets;
   package TLS renames Flyology.IO.TLS;
   package Provider renames TLS_Test_Provider;

   use Ada.Streams;
   use type Ada.Real_Time.Time;
   use type Provider.Operation_Counts;
   use type TLS.Step_Status;

   protected type Result_Box is
      procedure Report (Passed : Boolean);
      entry Wait;
      function Passed return Boolean;
   private
      Done : Boolean := False;
      OK   : Boolean := False;
   end Result_Box;

   protected body Result_Box is
      procedure Report (Passed : Boolean) is
      begin
         OK := Passed;
         Done := True;
      end Report;

      entry Wait when Done is
      begin
         null;
      end Wait;

      function Passed return Boolean is (OK);
   end Result_Box;

   procedure Close_If_Open (Socket : in out Sockets.Socket_Type) is
   begin
      if Sockets.Is_Open (Socket) then
         Sockets.Close_Socket (Socket);
      end if;
   exception
      when others =>
         null;
   end Close_If_Open;

   procedure Configure_Complete (Backend : in out Provider.Provider) is
   begin
      Provider.Set_Script
        (Backend, Provider.Handshake_Operation,
         [1 => (TLS.Complete, Provider.Preserve_Output, 0)]);
      Provider.Set_Script
        (Backend, Provider.Receive_Operation,
         [1 => (TLS.Complete, Provider.Advance_Output, 1)]);
      Provider.Set_Script
        (Backend, Provider.Send_Operation,
         [1 => (TLS.Complete, Provider.Advance_Output, 1)]);
      Provider.Set_Script
        (Backend, Provider.Shutdown_Operation,
         [1 => (TLS.Complete, Provider.Preserve_Output, 0)]);
   end Configure_Complete;

   procedure Assert_Resources (Created : Natural) is
      State : Provider.State_Telemetry;
   begin
      Provider.Get_State_Telemetry (State);
      pragma Assert (State.Sessions_Created = Created);
      pragma Assert (State.Sessions_Finalized = Created);
      pragma Assert (State.Sessions_Live = 0);
      pragma Assert (State.Finalized_While_FD_Open = Created);
   end Assert_Resources;

   procedure Run_Lifecycle (Model : Flyology.Execution_Model) is
      Manager : aliased Connections.Server (Capacity => 1);
      Item    : Connections.Connection;
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
      Backend : Provider.Provider;
      Result  : Result_Box;
   begin
      Provider.Reset_State_Telemetry;
      Configure_Complete (Backend);
      Sockets.Create_Socket_Pair (Socket, Peer);
      Connections.Take (Manager, Socket, Item);
      pragma Assert (Manager.Active = 1);

      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
            Data : Stream_Element_Array (1 .. 1);
            Double_Rejected : Boolean := False;
         begin
            Connection_TLS.Upgrade
              (Item, Backend, TLS.Server, "", Timeout => 1.0);
            pragma Assert (Connections.Is_Open (Item));
            pragma Assert (Manager.Active = 1);

            Item.Receive_Exactly (Data, Timeout => 1.0);
            pragma Assert (Data = [42]);
            Item.Send_All ([1 => 7], Timeout => 1.0);
            Connection_TLS.Shutdown (Item, Timeout => 1.0);
            Connection_TLS.Shutdown (Item, Timeout => 0.0);

            begin
               Connection_TLS.Upgrade
                 (Item, Backend, TLS.Server, "", Timeout => 0.0);
            exception
               when Program_Error =>
                  Double_Rejected := True;
            end;
            pragma Assert (Double_Rejected);
            pragma Assert (Connections.Is_Open (Item));
            pragma Assert (Manager.Active = 1);

            Connections.Close (Item);
            Connections.Close (Item);
            pragma Assert (not Connections.Is_Open (Item));
            pragma Assert (Manager.Active = 0);
            Result.Report (True);
         exception
            when others =>
               Result.Report (False);
         end Worker;
      begin
         Result.Wait;
      end;

      pragma Assert (Result.Passed);
      Close_If_Open (Peer);
      Assert_Resources (1);
      declare
         State : Provider.State_Telemetry;
      begin
         Provider.Get_State_Telemetry (State);
         pragma Assert
           (State.Calls =
              [Provider.Handshake_Operation => 1,
               Provider.Receive_Operation => 1,
               Provider.Send_Operation => 1,
               Provider.Shutdown_Operation => 1]);
      end;
   end Run_Lifecycle;

   procedure Run_Handshake_Failure (Model : Flyology.Execution_Model) is
      Manager : aliased Connections.Server (Capacity => 1);
      Item    : Connections.Connection;
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
      Backend : Provider.Provider;
      Result  : Result_Box;
   begin
      Provider.Reset_State_Telemetry;
      Provider.Set_Script
        (Backend, Provider.Handshake_Operation,
         [1 => (TLS.Failed, Provider.Preserve_Output, 0)]);
      Sockets.Create_Socket_Pair (Socket, Peer);
      Connections.Take (Manager, Socket, Item);

      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
            Failed_Closed : Boolean := False;
         begin
            begin
               Connection_TLS.Upgrade
                 (Item, Backend, TLS.Server, "", Timeout => 1.0);
            exception
               when TLS.TLS_Error =>
                  Failed_Closed :=
                    not Connections.Is_Open (Item)
                    and then Manager.Active = 0;
            end;
            Result.Report (Failed_Closed);
         exception
            when others =>
               Result.Report (False);
         end Worker;
      begin
         Result.Wait;
      end;

      pragma Assert (Result.Passed);
      Close_If_Open (Peer);
      Assert_Resources (1);
   end Run_Handshake_Failure;

   procedure Run_Setup_Failures (Model : Flyology.Execution_Model) is
      type Failure_Kind is (Unavailable, Create_Raises, Create_Returns_Null);

      procedure Run_One (Kind : Failure_Kind) is
         Manager : aliased Connections.Server (Capacity => 1);
         Item    : Connections.Connection;
         Socket  : Sockets.Socket_Type;
         Peer    : Sockets.Socket_Type;
         Backend : Provider.Provider;
         Result  : Result_Box;
      begin
         Provider.Reset_State_Telemetry;
         case Kind is
            when Unavailable =>
               Provider.Set_Available (Backend, False);
            when Create_Raises =>
               Provider.Set_Create_Behavior
                 (Backend, Provider.Raise_On_Create);
            when Create_Returns_Null =>
               Provider.Set_Create_Behavior
                 (Backend, Provider.Return_Null);
         end case;
         Sockets.Create_Socket_Pair (Socket, Peer);
         Connections.Take (Manager, Socket, Item);

         declare
            task Worker is
               pragma Task_Info (Model);
            end Worker;

            task body Worker is
               Failed_Closed : Boolean := False;
            begin
               begin
                  Connection_TLS.Upgrade
                    (Item, Backend, TLS.Server, "", Timeout => 1.0);
               exception
                  when TLS.TLS_Error =>
                     Failed_Closed :=
                       not Connections.Is_Open (Item)
                       and then Manager.Active = 0;
               end;
               Result.Report (Failed_Closed);
            exception
               when others =>
                  Result.Report (False);
            end Worker;
         begin
            Result.Wait;
         end;

         pragma Assert (Result.Passed);
         Connections.Close (Item);
         pragma Assert (Manager.Active = 0);
         Close_If_Open (Peer);
         Assert_Resources (0);
      end Run_One;

   begin
      for Kind in Failure_Kind loop
         Run_One (Kind);
      end loop;
   end Run_Setup_Failures;

   procedure Run_Setup_Deadline (Model : Flyology.Execution_Model) is
      Manager : aliased Connections.Server (Capacity => 1);
      Item    : Connections.Connection;
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
      Backend : Provider.Provider;
      Result  : Result_Box;
   begin
      Provider.Reset_State_Telemetry;
      Configure_Complete (Backend);
      Provider.Set_Create_Delay (Backend, 0.050);
      Sockets.Create_Socket_Pair (Socket, Peer);
      Connections.Take (Manager, Socket, Item);

      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
            Timed_Out : Boolean := False;
         begin
            begin
               Connection_TLS.Upgrade
                 (Item, Backend, TLS.Server, "", Timeout => 0.010);
            exception
               when Flyology.IO.Timeout_Error =>
                  Timed_Out := True;
            end;
            Result.Report
              (Timed_Out
               and then not Connections.Is_Open (Item)
               and then Manager.Active = 0);
         exception
            when others =>
               Result.Report (False);
         end Worker;
      begin
         Result.Wait;
      end;

      pragma Assert (Result.Passed);
      Close_If_Open (Peer);
      Assert_Resources (1);
      declare
         State : Provider.State_Telemetry;
      begin
         Provider.Get_State_Telemetry (State);
         pragma Assert (State.Calls (Provider.Handshake_Operation) = 0);
      end;
   end Run_Setup_Deadline;

   procedure Run_Stale_Plaintext_Operation
     (Model : Flyology.Execution_Model)
   is
      Manager : aliased Connections.Server (Capacity => 1);
      Item    : Connections.Connection;
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
      Backend : Provider.Provider;
      Sender_Result  : Result_Box;
      Upgrade_Result : Result_Box;
      Point : constant Connection_Testing.Barrier_Point :=
        Connection_Testing.Stale_Operation_Registration;
   begin
      Provider.Reset_State_Telemetry;
      Configure_Complete (Backend);
      Connection_Testing.Reset_Barriers;
      Connection_Testing.Arm (Point);
      Sockets.Create_Socket_Pair (Socket, Peer);
      Connections.Take (Manager, Socket, Item);

      declare
         task Sender is
            pragma Task_Info (Model);
         end Sender;

         task body Sender is
            Cancelled : Boolean := False;
         begin
            begin
               Item.Send_All ([1 => 17], Timeout => 2.0);
            exception
               when Connections.Operation_Cancelled =>
                  Cancelled := True;
            end;
            Sender_Result.Report (Cancelled);
         exception
            when others =>
               Sender_Result.Report (False);
         end Sender;
      begin
         Connection_Testing.Wait_Reached (Point);
         pragma Assert (not Connection_Testing.Operation_Active (Item));
         pragma Assert
           (Connection_Testing.Waiting_Operations (Item) = 1);

         declare
            task Upgrader is
               pragma Task_Info (Model);
            end Upgrader;

            task body Upgrader is
            begin
               Connection_TLS.Upgrade
                 (Item, Backend, TLS.Server, "", Timeout => 1.0);
               Item.Send_All ([1 => 9], Timeout => 1.0);
               Upgrade_Result.Report (True);
            exception
               when others =>
                  Upgrade_Result.Report (False);
            end Upgrader;
         begin
            Upgrade_Result.Wait;
         end;

         pragma Assert (Upgrade_Result.Passed);
         pragma Assert (not Connection_Testing.Operation_Active (Item));
         pragma Assert
           (Connection_Testing.Waiting_Operations (Item) = 1);
         Connection_Testing.Release (Point);
         Sender_Result.Wait;
      exception
         when others =>
            Connection_Testing.Release (Point);
            raise;
      end;

      pragma Assert (Sender_Result.Passed);
      pragma Assert (Connections.Is_Open (Item));
      pragma Assert (Manager.Active = 1);
      pragma Assert (not Connection_Testing.Operation_Active (Item));
      pragma Assert (Connection_Testing.Waiting_Operations (Item) = 0);
      declare
         Probe : Stream_Element_Array (1 .. 1);
         Last  : Stream_Element_Offset;
         No_Plaintext : Boolean := False;
      begin
         begin
            Sockets.Receive (Peer, Probe, Last, Timeout => 0.0);
         exception
            when Flyology.IO.Timeout_Error =>
               No_Plaintext := True;
         end;
         pragma Assert (No_Plaintext);
      end;
      Connections.Close (Item);
      Close_If_Open (Peer);
      Connection_Testing.Reset_Barriers;
      Assert_Resources (1);
      declare
         State : Provider.State_Telemetry;
      begin
         Provider.Get_State_Telemetry (State);
         pragma Assert
           (State.Calls (Provider.Handshake_Operation) = 1
            and then State.Calls (Provider.Send_Operation) = 1);
      end;
   end Run_Stale_Plaintext_Operation;

   procedure Run_Aborted_Upgrade (Model : Flyology.Execution_Model) is
      Manager : aliased Connections.Server (Capacity => 1);
      Item    : Connections.Connection;
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
      Backend : Provider.Provider;
      Point : constant Connection_Testing.Barrier_Point :=
        Connection_Testing.TLS_Session_Installed;
   begin
      Provider.Reset_State_Telemetry;
      Configure_Complete (Backend);
      Connection_Testing.Reset_Barriers;
      Connection_Testing.Arm (Point);
      Sockets.Create_Socket_Pair (Socket, Peer);
      Connections.Take (Manager, Socket, Item);

      declare
         task Upgrader is
            pragma Task_Info (Model);
         end Upgrader;

         task body Upgrader is
         begin
            Connection_TLS.Upgrade
              (Item, Backend, TLS.Server, "", Timeout => 1.0);
         end Upgrader;
      begin
         Connection_Testing.Wait_Reached (Point);
         pragma Assert (Connection_Testing.Operation_Active (Item));
         pragma Assert (Manager.Active = 1);
         abort Upgrader;
         Connection_Testing.Release (Point);
      exception
         when others =>
            Connection_Testing.Release (Point);
            raise;
      end;

      pragma Assert (not Connections.Is_Open (Item));
      pragma Assert (Manager.Active = 0);
      pragma Assert (not Connection_Testing.Operation_Active (Item));
      pragma Assert (Connection_Testing.Waiting_Operations (Item) = 0);
      Close_If_Open (Peer);
      Connection_Testing.Reset_Barriers;
      Assert_Resources (1);
   end Run_Aborted_Upgrade;

   procedure Run_Finalizer_Failure (Model : Flyology.Execution_Model) is
      Manager : aliased Connections.Server (Capacity => 1);
      Item    : Connections.Connection;
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
      Backend : Provider.Provider;
      Result  : Result_Box;
   begin
      Provider.Reset_State_Telemetry;
      Configure_Complete (Backend);
      Provider.Set_Finalize_Failure (Backend);
      Sockets.Create_Socket_Pair (Socket, Peer);
      Connections.Take (Manager, Socket, Item);

      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
            Failed_Safely : Boolean := False;
         begin
            Connection_TLS.Upgrade
              (Item, Backend, TLS.Server, "", Timeout => 1.0);
            begin
               Connections.Close (Item);
            exception
               when TLS.TLS_Error =>
                  Failed_Safely :=
                    not Connections.Is_Open (Item)
                    and then Manager.Active = 0;
            end;
            Result.Report (Failed_Safely);
         exception
            when others =>
               Result.Report (False);
         end Worker;
      begin
         Result.Wait;
      end;

      pragma Assert (Result.Passed);
      Connections.Close (Item);
      Close_If_Open (Peer);
      Assert_Resources (1);
   end Run_Finalizer_Failure;

   procedure Run_Concurrent_Close (Model : Flyology.Execution_Model) is
      Manager : aliased Connections.Server (Capacity => 1);
      Item    : Connections.Connection;
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
      Backend : Provider.Provider;
      Upgrade_Result : Result_Box;
      Close_Result   : Result_Box;
      Queued_Cancelled : Boolean := False;
   begin
      Provider.Reset_State_Telemetry;
      Provider.Set_Block_Handshake (Backend);
      Sockets.Create_Socket_Pair (Socket, Peer);
      Connections.Take (Manager, Socket, Item);

      declare
         task Upgrader is
            pragma Task_Info (Model);
         end Upgrader;

         task body Upgrader is
            Cancelled : Boolean := False;
         begin
            begin
               Connection_TLS.Upgrade
                 (Item, Backend, TLS.Server, "", Timeout => 2.0);
            exception
               when Connections.Operation_Cancelled =>
                  Cancelled := True;
            end;
            Upgrade_Result.Report (Cancelled);
         exception
            when others =>
               Upgrade_Result.Report (False);
         end Upgrader;

         task Closer is
            entry Start;
            pragma Task_Info (Model);
         end Closer;

         task body Closer is
         begin
            accept Start;
            Connections.Close (Item);
            Close_Result.Report (True);
         exception
            when others =>
               Close_Result.Report (False);
         end Closer;
      begin
         Provider.Wait_Handshake_Blocked;
         begin
            Item.Send_All ([1 => 3], Timeout => 0.0);
         exception
            when Connections.Operation_Cancelled =>
               Queued_Cancelled := True;
         end;
         Closer.Start;
         if not Queued_Cancelled then
            Provider.Release_Handshake;
            raise Program_Error with
              "queued operation was not cancelled during TLS upgrade";
         end if;
         declare
            Deadline : constant Ada.Real_Time.Time :=
              Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
         begin
            while not Connection_Testing.Close_Requested (Item) loop
               if Ada.Real_Time.Clock >= Deadline then
                  Provider.Release_Handshake;
                  raise Program_Error with
                    "close did not publish its generation barrier";
               end if;
               delay 0.001;
            end loop;
         end;
         Provider.Release_Handshake;
         select
            Upgrade_Result.Wait;
         or
            delay 2.0;
            raise Program_Error with "TLS upgrader did not drain after close";
         end select;
         select
            Close_Result.Wait;
         or
            delay 2.0;
            raise Program_Error with "concurrent TLS close did not finish";
         end select;
      end;

      pragma Assert (Upgrade_Result.Passed);
      pragma Assert (Close_Result.Passed);
      pragma Assert (not Connections.Is_Open (Item));
      pragma Assert (Manager.Active = 0);
      Close_If_Open (Peer);
      Assert_Resources (1);
   end Run_Concurrent_Close;

   procedure Run_Handshake_Interruptions
     (Model : Flyology.Execution_Model)
   is
      type Interruption_Kind is
        (Deadline_Expires, Token_Requested, Manager_Shutdown);

      procedure Run_One (Kind : Interruption_Kind) is
         Manager : aliased Connections.Server (Capacity => 1);
         Token   : aliased Connections.Cancellation_Token;
         Item    : Connections.Connection;
         Socket  : Sockets.Socket_Type;
         Peer    : Sockets.Socket_Type;
         Backend : Provider.Provider;
         Result  : Result_Box;
      begin
         Provider.Reset_State_Telemetry;
         Provider.Set_Script
           (Backend, Provider.Handshake_Operation,
            [1 => (TLS.Want_Read, Provider.Preserve_Output, 0)]);
         Sockets.Create_Socket_Pair (Socket, Peer);
         Connections.Take (Manager, Socket, Item);

         declare
            task Worker is
               pragma Task_Info (Model);
            end Worker;

            task body Worker is
               Interrupted : Boolean := False;
            begin
               begin
                  Connection_TLS.Upgrade
                    (Item,
                     Backend,
                     TLS.Server,
                     "",
                     Timeout =>
                       (if Kind = Deadline_Expires then 0.020
                        else Flyology.IO.Infinite),
                     Token => Token'Access);
               exception
                  when Flyology.IO.Timeout_Error =>
                     Interrupted := Kind = Deadline_Expires;
                  when Connections.Operation_Cancelled =>
                     Interrupted := Kind /= Deadline_Expires;
               end;
               Result.Report
                 (Interrupted
                  and then not Connections.Is_Open (Item)
                  and then Manager.Active = 0);
            exception
               when others =>
                  Result.Report (False);
            end Worker;
         begin
            Provider.Wait_For_First_Call (Provider.Handshake_Operation);
            case Kind is
               when Deadline_Expires =>
                  null;
               when Token_Requested =>
                  Token.Request;
               when Manager_Shutdown =>
                  Manager.Request_Shutdown;
            end case;
            Result.Wait;
         end;

         pragma Assert (Result.Passed);
         if Kind = Manager_Shutdown then
            Manager.Await_Drained;
         end if;
         Close_If_Open (Peer);
         Assert_Resources (1);
      end Run_One;

   begin
      for Kind in Interruption_Kind loop
         Run_One (Kind);
      end loop;
   end Run_Handshake_Interruptions;

begin
   Run_Lifecycle (Flyology.Lightweight_Task);
   Run_Lifecycle (Flyology.Native_Task);
   Run_Handshake_Failure (Flyology.Lightweight_Task);
   Run_Handshake_Failure (Flyology.Native_Task);
   Run_Setup_Failures (Flyology.Lightweight_Task);
   Run_Setup_Failures (Flyology.Native_Task);
   Run_Setup_Deadline (Flyology.Lightweight_Task);
   Run_Setup_Deadline (Flyology.Native_Task);
   Run_Stale_Plaintext_Operation (Flyology.Lightweight_Task);
   Run_Stale_Plaintext_Operation (Flyology.Native_Task);
   Run_Aborted_Upgrade (Flyology.Lightweight_Task);
   Run_Aborted_Upgrade (Flyology.Native_Task);
   Run_Finalizer_Failure (Flyology.Lightweight_Task);
   Run_Finalizer_Failure (Flyology.Native_Task);
   Run_Concurrent_Close (Flyology.Lightweight_Task);
   Run_Concurrent_Close (Flyology.Native_Task);
   Run_Handshake_Interruptions (Flyology.Lightweight_Task);
   Run_Handshake_Interruptions (Flyology.Native_Task);
end Connection_TLS_Upgrade_Smoke;
