with Fault_Control;
with Flyology;
with Flyology.IO;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with Flyology.IO.Structured_Servers;
with Interfaces.C;
with Structured_Server_Test_Control;
with System.Multiprocessors;

procedure Structured_Server_Abort_Smoke is
   package Connections renames Flyology.IO.Connections;
   package Sockets renames Flyology.IO.Sockets;
   package Test_Control renames Structured_Server_Test_Control;

   use type Flyology.IO.Descriptor;
   use type Test_Control.Barrier_Point;

   function Open_FD_Count return Interfaces.C.int
     with Import,
          Convention => C,
          External_Name => "flyology_test_open_fd_count";
   function FD_Is_Open (FD : Interfaces.C.int) return Interfaces.C.int
     with Import,
          Convention => C,
          External_Name => "flyology_test_fd_is_open";

   procedure Open_Listener (Listener : in out Sockets.Socket_Type) is
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Set_Socket_Option
        (Listener,
         Sockets.Socket_Level,
         (Sockets.Reuse_Address, True));
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint
           (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener, Length => 4);
   end Open_Listener;

   procedure Open_Listener
     (Listener : in out Sockets.Socket_Type;
      Address  : out Sockets.Endpoint)
   is
   begin
      Open_Listener (Listener);
      Address := Sockets.Get_Socket_Name (Listener);
   end Open_Listener;

   procedure Assert_Descriptor_Reused (Old_FD : Flyology.IO.Descriptor) is
      Replacement, Peer : Sockets.Socket_Type;
   begin
      Sockets.Create_Socket_Pair (Replacement, Peer);
      pragma Assert (Sockets.Native_Descriptor (Replacement) = Old_FD);
      Sockets.Close_Socket (Replacement);
      Sockets.Close_Socket (Peer);
   end Assert_Descriptor_Reused;

   generic
      Caller_Model  : Flyology.Execution_Model;
      Caller_CPU    : System.Multiprocessors.CPU_Range;
      Handler_Model : Flyology.Execution_Model;
      Handler_CPU   : System.Multiprocessors.CPU_Range;
   procedure Run_Lane;

   procedure Run_Lane is
      protected type Handler_Gate is
         procedure Enable;
         procedure Enter (Block : out Boolean);
         entry Await_Entered;
         entry Await_Release;
         procedure Release;
      private
         Blocking : Boolean := False;
         Entered  : Boolean := False;
         Released : Boolean := False;
      end Handler_Gate;

      protected body Handler_Gate is
         procedure Enable is
         begin
            Blocking := True;
            Entered := False;
            Released := False;
         end Enable;

         procedure Enter (Block : out Boolean) is
         begin
            Block := Blocking;
            Entered := True;
         end Enter;

         entry Await_Entered when Entered is
         begin
            null;
         end Await_Entered;

         entry Await_Release when Released is
         begin
            null;
         end Await_Release;

         procedure Release is
         begin
            Released := True;
         end Release;
      end Handler_Gate;

      type Context is limited record
         Gate : Handler_Gate;
      end record;

      procedure Handle
        (State        : in out Context;
         Connection   : in out Connections.Connection;
         Peer         : Sockets.Endpoint;
         Cancellation : not null access Connections.Cancellation_Token)
      is
         Block : Boolean;
         pragma Unreferenced (Connection, Peer, Cancellation);
      begin
         State.Gate.Enter (Block);
         if not Block then
            raise Program_Error with
              "abort ownership test unexpectedly admitted a connection";
         end if;
         State.Gate.Await_Release;
      end Handle;

      package Structured is new Flyology.IO.Structured_Servers
         (Handler_Context => Context,
         Handle          => Handle,
         Handler_Model   => Handler_Model,
         Handler_CPU     => Handler_CPU);

      procedure Warm_Runtime is
         Item     : aliased Structured.Server (Capacity => 2);
         State    : aliased Context;
         Listener : Sockets.Socket_Type;
      begin
         Open_Listener (Listener);
         Structured.Request_Shutdown (Item);
         Structured.Serve (Item, Listener, State, Drain_Timeout => 0.1);
         pragma Assert (not Sockets.Is_Open (Listener));
      end Warm_Runtime;

      procedure Assert_Terminal_One_Shot
        (Item : aliased in out Structured.Server)
      is
         Retry    : Sockets.Socket_Type;
         State    : aliased Context;
         Rejected : Boolean := False;
      begin
         Open_Listener (Retry);
         begin
            Structured.Serve (Item, Retry, State, Drain_Timeout => 0.1);
         exception
            when Program_Error =>
               Rejected := True;
         end;
         pragma Assert (Rejected);
         pragma Assert (Sockets.Is_Open (Retry));
         Sockets.Close_Socket (Retry);
      end Assert_Terminal_One_Shot;

      procedure Run_Abort_At (Point : Test_Control.Barrier_Point) is
         Before_FDs : constant Interfaces.C.int := Open_FD_Count;
         Listener   : Sockets.Socket_Type;
         Old_FD     : Flyology.IO.Descriptor;
      begin
         pragma Assert (Point /= Test_Control.Listener_Close);
         Fault_Control.Reset;
         Test_Control.Reset;
         Test_Control.Arm (Point);
         Open_Listener (Listener);
         Old_FD := Sockets.Native_Descriptor (Listener);

         declare
            Item       : aliased Structured.Server (Capacity => 2);
            State      : aliased Context;
            Unexpected : Boolean := False with Atomic;
         begin
            declare
               task Runner with CPU => Caller_CPU is
                  pragma Task_Info (Caller_Model);
               end Runner;

               task body Runner is
               begin
                  Structured.Serve
                    (Item, Listener, State, Drain_Timeout => 0.1);
                  Unexpected := True;
               exception
                  when others =>
                     Unexpected := True;
               end Runner;
            begin
               Test_Control.Wait_Reached (Point);
               if Point = Test_Control.Before_Acquisition then
                  pragma Assert (Sockets.Is_Open (Listener));
                  pragma Assert (not Structured.Current (Item).Running);
               else
                  --  During_Acquisition observes the raw-descriptor handoff;
                  --  later barriers observe completed server acquisition.
                  pragma Assert (not Sockets.Is_Open (Listener));
               end if;
               abort Runner;
               Test_Control.Release (Point);
            exception
               when others =>
                  Test_Control.Release (Point);
                  raise;
            end;

            pragma Assert (not Unexpected);
            if Point = Test_Control.Before_Acquisition then
               pragma Assert (Sockets.Is_Open (Listener));
               pragma Assert
                 (Fault_Control.Calls
                    (Fault_Control.Structured_Listener_Close) = 0);

               --  Abort before controlled acquisition does not consume the
               --  server's one permitted Serve call or the caller's handle.
               Structured.Request_Shutdown (Item);
               Structured.Serve
                 (Item, Listener, State, Drain_Timeout => 0.1);
               pragma Assert (not Sockets.Is_Open (Listener));
            else
               pragma Assert (not Sockets.Is_Open (Listener));
               pragma Assert (not Structured.Current (Item).Running);
               pragma Assert
                 (Structured.Current (Item).Active_Handlers = 0);
               Assert_Terminal_One_Shot (Item);
            end if;
         end;

         pragma Assert
           (Fault_Control.Calls
              (Fault_Control.Structured_Listener_Close) = 1);
         pragma Assert
           (FD_Is_Open (Interfaces.C.int (Old_FD)) = 0);
         Assert_Descriptor_Reused (Old_FD);
         pragma Assert (Open_FD_Count = Before_FDs);
         Test_Control.Reset;
         Fault_Control.Reset;
      exception
         when others =>
            Test_Control.Release (Point);
            Test_Control.Reset;
            Fault_Control.Reset;
            if Sockets.Is_Open (Listener) then
               Sockets.Close_Socket (Listener);
            end if;
            raise;
      end Run_Abort_At;

      procedure Run_Partial_Activation_Failure is
         Before_FDs : constant Interfaces.C.int := Open_FD_Count;
         Listener   : Sockets.Socket_Type;
         Old_FD     : Flyology.IO.Descriptor;
         Failed     : Boolean := False;
      begin
         Fault_Control.Reset;
         Test_Control.Reset;
         Test_Control.Fail_Activation_At (2);
         Open_Listener (Listener);
         Old_FD := Sockets.Native_Descriptor (Listener);

         declare
            Item  : aliased Structured.Server (Capacity => 3);
            State : aliased Context;
         begin
            begin
               Structured.Serve
                 (Item, Listener, State, Drain_Timeout => 0.1);
            exception
               when Tasking_Error =>
                  Failed := True;
            end;

            pragma Assert (Failed);
            pragma Assert (not Sockets.Is_Open (Listener));
            pragma Assert (not Structured.Current (Item).Running);
            pragma Assert (Structured.Current (Item).Active_Handlers = 0);
            Assert_Terminal_One_Shot (Item);
         end;

         pragma Assert
           (Fault_Control.Calls
              (Fault_Control.Structured_Listener_Close) = 1);
         pragma Assert (FD_Is_Open (Interfaces.C.int (Old_FD)) = 0);
         Assert_Descriptor_Reused (Old_FD);
         pragma Assert (Open_FD_Count = Before_FDs);
         Test_Control.Reset;
         Fault_Control.Reset;
      exception
         when others =>
            Test_Control.Reset;
            Fault_Control.Reset;
            if Sockets.Is_Open (Listener) then
               Sockets.Close_Socket (Listener);
            end if;
            raise;
      end Run_Partial_Activation_Failure;

      procedure Run_Abort_With_Active_Handler is
         Before_FDs : constant Interfaces.C.int := Open_FD_Count;
         Listener   : Sockets.Socket_Type;
         Address    : Sockets.Endpoint;
         Client     : Sockets.Socket_Type;
         Old_FD     : Flyology.IO.Descriptor;
         Unexpected : Boolean := False with Atomic;
      begin
         Fault_Control.Reset;
         Test_Control.Reset;
         Test_Control.Arm (Test_Control.Serving);
         Open_Listener (Listener, Address);
         Old_FD := Sockets.Native_Descriptor (Listener);

         declare
            Item  : aliased Structured.Server (Capacity => 2);
            State : aliased Context;
         begin
            State.Gate.Enable;
            declare
               task Runner with CPU => Caller_CPU is
                  pragma Task_Info (Caller_Model);
               end Runner;

               task body Runner is
               begin
                  Structured.Serve
                    (Item, Listener, State, Drain_Timeout => 0.1);
                  Unexpected := True;
               exception
                  when others =>
                     Unexpected := True;
               end Runner;
            begin
               --  Running is published before listener acquisition finishes.
               --  Wait for the worker scope's serving milestone instead of
               --  inferring readiness from that lifecycle snapshot.
               Test_Control.Wait_Reached (Test_Control.Serving);
               pragma Assert (not Sockets.Is_Open (Listener));
               Test_Control.Release (Test_Control.Serving);
               Sockets.Create_Socket (Client);
               Sockets.Connect (Client, Address, Timeout => 1.0);
               State.Gate.Await_Entered;
               pragma Assert
                 (Structured.Current (Item).Active_Handlers = 1);
               pragma Assert
                 (Structured.Current (Item).Accepted_Connections = 1);
               abort Runner;
               State.Gate.Release;
            exception
               when others =>
                  Test_Control.Release (Test_Control.Serving);
                  State.Gate.Release;
                  raise;
            end;

            pragma Assert (not Unexpected);
            pragma Assert (not Structured.Current (Item).Running);
            pragma Assert (Structured.Current (Item).Active_Handlers = 0);
            Assert_Terminal_One_Shot (Item);
         end;

         pragma Assert (not Sockets.Is_Open (Listener));
         pragma Assert
           (Fault_Control.Calls
              (Fault_Control.Structured_Listener_Close) = 1);
         pragma Assert (FD_Is_Open (Interfaces.C.int (Old_FD)) = 0);
         Sockets.Close_Socket (Client);
         Assert_Descriptor_Reused (Old_FD);
         pragma Assert (Open_FD_Count = Before_FDs);
         Test_Control.Reset;
         Fault_Control.Reset;
      exception
         when others =>
            Test_Control.Reset;
            Fault_Control.Reset;
            if Sockets.Is_Open (Client) then
               Sockets.Close_Socket (Client);
            end if;
            if Sockets.Is_Open (Listener) then
               Sockets.Close_Socket (Listener);
            end if;
            raise;
      end Run_Abort_With_Active_Handler;

      procedure Run_Abort_During_Close is
         Before_FDs : constant Interfaces.C.int := Open_FD_Count;
         Listener   : Sockets.Socket_Type;
         Old_FD     : Flyology.IO.Descriptor;
         Unexpected : Boolean := False with Atomic;

         protected Start_Control is
            procedure Start_Shutdown;
            entry Await_Shutdown;
         private
            Started : Boolean := False;
         end Start_Control;

         protected body Start_Control is
            procedure Start_Shutdown is
            begin
               Started := True;
            end Start_Shutdown;

            entry Await_Shutdown when Started is
            begin
               null;
            end Await_Shutdown;
         end Start_Control;
      begin
         Fault_Control.Reset;
         Test_Control.Reset;
         Test_Control.Arm (Test_Control.After_Acquisition);
         Test_Control.Arm (Test_Control.Listener_Close);
         Open_Listener (Listener);
         Old_FD := Sockets.Native_Descriptor (Listener);

         declare
            Item  : aliased Structured.Server (Capacity => 2);
            State : aliased Context;

            task Runner with CPU => Caller_CPU is
               pragma Task_Info (Caller_Model);
            end Runner;
            task Stopper;

            task body Runner is
            begin
               Structured.Serve
                 (Item, Listener, State, Drain_Timeout => 0.1);
               Unexpected := True;
            exception
               when others =>
                  Unexpected := True;
            end Runner;

            task body Stopper is
            begin
               Start_Control.Await_Shutdown;
               Structured.Request_Shutdown (Item);
            end Stopper;
         begin
            --  Running precedes the abort-deferred listener transfer. Observe
            --  the completed acquisition hook before inspecting the caller's
            --  handle or beginning shutdown.
            Test_Control.Wait_Reached (Test_Control.After_Acquisition);
            pragma Assert (not Sockets.Is_Open (Listener));
            Test_Control.Release (Test_Control.After_Acquisition);
            Start_Control.Start_Shutdown;
            Test_Control.Wait_Reached (Test_Control.Listener_Close);
            abort Runner;
            Test_Control.Release (Test_Control.Listener_Close);
         exception
            when others =>
               Start_Control.Start_Shutdown;
               Test_Control.Release (Test_Control.After_Acquisition);
               Test_Control.Release (Test_Control.Listener_Close);
               raise;
         end;

         --  The block joined the Serve and shutdown tasks before finalizing
         --  Item. Finalization must observe terminal state and not retry close.
         pragma Assert (not Unexpected);
         pragma Assert (not Sockets.Is_Open (Listener));
         pragma Assert
           (Fault_Control.Calls
              (Fault_Control.Structured_Listener_Close) = 1);
         pragma Assert (FD_Is_Open (Interfaces.C.int (Old_FD)) = 0);
         Assert_Descriptor_Reused (Old_FD);
         pragma Assert (Open_FD_Count = Before_FDs);
         Test_Control.Reset;
         Fault_Control.Reset;
      exception
         when others =>
            Start_Control.Start_Shutdown;
            Test_Control.Release (Test_Control.After_Acquisition);
            Test_Control.Release (Test_Control.Listener_Close);
            Test_Control.Reset;
            Fault_Control.Reset;
            if Sockets.Is_Open (Listener) then
               Sockets.Close_Socket (Listener);
            end if;
            raise;
      end Run_Abort_During_Close;
   begin
      Warm_Runtime;
      Fault_Control.Reset;
      Run_Abort_At (Test_Control.Before_Acquisition);
      Run_Abort_At (Test_Control.During_Acquisition);
      Run_Abort_At (Test_Control.After_Acquisition);
      Run_Abort_At (Test_Control.During_Worker_Activation);
      Run_Abort_At (Test_Control.After_Worker_Activation);
      Run_Abort_At (Test_Control.Serving);
      Run_Partial_Activation_Failure;
      Run_Abort_With_Active_Handler;
      Run_Abort_During_Close;
   end Run_Lane;

   procedure Run_Lightweight_Lightweight is new Run_Lane
     (Caller_Model  => Flyology.Lightweight_Task,
      Caller_CPU    => 1,
      Handler_Model => Flyology.Lightweight_Task,
      Handler_CPU   => 1);
   procedure Run_Lightweight_Native is new Run_Lane
     (Caller_Model  => Flyology.Lightweight_Task,
      Caller_CPU    => 1,
      Handler_Model => Flyology.Native_Task,
      Handler_CPU   => System.Multiprocessors.Not_A_Specific_CPU);
   procedure Run_Native_Lightweight is new Run_Lane
     (Caller_Model  => Flyology.Native_Task,
      Caller_CPU    => System.Multiprocessors.Not_A_Specific_CPU,
      Handler_Model => Flyology.Lightweight_Task,
      Handler_CPU   => 1);
   procedure Run_Native_Native is new Run_Lane
     (Caller_Model  => Flyology.Native_Task,
      Caller_CPU    => System.Multiprocessors.Not_A_Specific_CPU,
      Handler_Model => Flyology.Native_Task,
      Handler_CPU   => System.Multiprocessors.Not_A_Specific_CPU);
begin
   if not Fault_Control.Enabled then
      raise Program_Error with
        "structured server abort test requires a fault-enabled runtime";
   end if;
   Run_Lightweight_Lightweight;
   Run_Lightweight_Native;
   Run_Native_Lightweight;
   Run_Native_Native;
end Structured_Server_Abort_Smoke;
