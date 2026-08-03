with GNAT.Sockets;
with Fault_Control;
with Flyology;
with Flyology.IO;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with Flyology.IO.Structured_Servers;
with System.Multiprocessors;

procedure Structured_Server_Reuse_Smoke is
   package Connections renames Flyology.IO.Connections;
   package Sockets renames GNAT.Sockets;

   use type Flyology.IO.Descriptor;
   use type Sockets.Socket_Type;

   procedure Open_Listener
     (Listener : out Sockets.Socket_Type;
      Address  : out Sockets.Sock_Addr_Type)
   is
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Set_Socket_Option
        (Listener,
         Sockets.Socket_Level,
         (Sockets.Reuse_Address, True));
      Sockets.Bind_Socket
        (Listener,
         (Family => Sockets.Family_Inet,
          Addr   => Sockets.Loopback_Inet_Addr,
          Port   => Sockets.Any_Port));
      Sockets.Listen_Socket (Listener, Length => 4);
      Address := Sockets.Get_Socket_Name (Listener);
   end Open_Listener;

   generic
      Model : Flyology.Execution_Model;
      CPU   : System.Multiprocessors.CPU_Range;
   procedure Run_Lane;

   procedure Run_Lane is
      type Context is null record;

      procedure Handle
        (State        : in out Context;
         Connection   : in out Connections.Connection;
         Peer         : Sockets.Sock_Addr_Type;
         Cancellation : not null access Connections.Cancellation_Token)
      is
         pragma Unreferenced
           (State, Connection, Peer, Cancellation);
      begin
         raise Program_Error with
           "pre-requested shutdown admitted a connection";
      end Handle;

      package Structured is new Flyology.IO.Structured_Servers
        (Handler_Context => Context,
         Handle          => Handle,
         Handler_Model   => Model,
         Handler_CPU     => CPU);

      procedure Run_Close_Failures (Injected_Count : Positive) is
         Listener    : Sockets.Socket_Type := Sockets.No_Socket;
         Address     : Sockets.Sock_Addr_Type;
         Old_FD      : Flyology.IO.Descriptor;
         Caller_Owns : Boolean := False;
      begin
         Fault_Control.Reset;
         declare
            Item         : aliased Structured.Server (Capacity => 3);
            State        : aliased Context;
            Close_Failed : Boolean := False;
            Rejected     : Boolean := False;
         begin
            Open_Listener (Listener, Address);
            Caller_Owns := True;
            Old_FD := Flyology.IO.Sockets.Native_Descriptor (Listener);

            --  A pre-Serve shutdown is pending, but no Serve call is active.
            Structured.Request_Shutdown (Item);
            pragma Assert (not Structured.Current (Item).Running);
            pragma Assert (Structured.Current (Item).Shutdown_Requested);
            pragma Assert
              (not Structured.Current (Item).Forced_Cancellation);

            --  All workers stop before listener cleanup. One injected failure
            --  exercises the immediate retry; two leave ownership in Item for
            --  the controlled finalization retry below.
            Fault_Control.Arm
              (Fault_Control.Structured_Listener_Close,
               Count => Injected_Count);
            Caller_Owns := False;
            begin
               Structured.Serve
                 (Item, Listener, State, Drain_Timeout => 0.1);
            exception
               when Sockets.Socket_Error =>
                  Close_Failed := True;
            end;
            pragma Assert (Close_Failed);
            pragma Assert
              (Fault_Control.Calls
                 (Fault_Control.Structured_Listener_Close) = 2);
            pragma Assert (not Structured.Current (Item).Running);
            pragma Assert (Structured.Current (Item).Shutdown_Requested);
            pragma Assert
              (not Structured.Current (Item).Forced_Cancellation);
            pragma Assert (Structured.Current (Item).Active_Handlers = 0);

            --  Socket_Type is scalar, so Ada need not copy No_Socket back when
            --  Serve propagates. The retained value is not caller-owned.
            Listener := Sockets.No_Socket;

            --  One-shot rejection occurs before a fresh listener transfers.
            Open_Listener (Listener, Address);
            Caller_Owns := True;
            begin
               Structured.Serve
                 (Item, Listener, State, Drain_Timeout => 0.1);
            exception
               when Program_Error =>
                  Rejected := True;
            end;
            pragma Assert (Rejected);
            pragma Assert (Listener /= Sockets.No_Socket);
            Sockets.Close_Socket (Listener);
            Listener := Sockets.No_Socket;
            Caller_Owns := False;
         end;

         pragma Assert
           (Fault_Control.Calls (Fault_Control.Structured_Listener_Close) =
              (if Injected_Count = 1 then 2 else 3));

         --  Finalization has released the original descriptor even when both
         --  Serve-side close attempts failed.
         declare
            Probe : Sockets.Socket_Type;
         begin
            Sockets.Create_Socket (Probe);
            pragma Assert
              (Flyology.IO.Sockets.Native_Descriptor (Probe) = Old_FD);
            Sockets.Close_Socket (Probe);
         end;
         Fault_Control.Reset;
      exception
         when others =>
            Fault_Control.Reset;
            if Caller_Owns and then Listener /= Sockets.No_Socket then
               Sockets.Close_Socket (Listener);
            end if;
            raise;
      end Run_Close_Failures;
   begin
      Run_Close_Failures (1);
      Run_Close_Failures (2);
   end Run_Lane;

   procedure Run_Lightweight is new Run_Lane
     (Model => Flyology.Lightweight_Task,
      CPU   => 1);
   procedure Run_Native is new Run_Lane
     (Model => Flyology.Native_Task,
      CPU   => System.Multiprocessors.Not_A_Specific_CPU);
begin
   if not Fault_Control.Enabled then
      raise Program_Error with
        "structured server reuse test requires a fault-enabled runtime";
   end if;
   Run_Lightweight;
   Run_Native;
end Structured_Server_Reuse_Smoke;
