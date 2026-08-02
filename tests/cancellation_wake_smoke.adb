with Ada.Real_Time;
with Ada.Streams;
with GNAT.Sockets;
with Gnatevl;
with Gnatevl.IO;
with Gnatevl.IO.Connections;
with Gnatevl.Observability;
with Interfaces;

procedure Cancellation_Wake_Smoke is
   package Connections renames Gnatevl.IO.Connections;
   use type Ada.Real_Time.Time;
   use type Interfaces.Unsigned_64;

   Scale : constant Positive := 64;
   type Socket_Array is array (Positive range <>) of GNAT.Sockets.Socket_Type;

   procedure Run_Token_Wake is
      Manager : aliased Connections.Server (Capacity => Scale * 2);
      Token   : aliased Connections.Cancellation_Token;
      Servers : Socket_Array (1 .. Scale * 2);
      Peers   : Socket_Array (Servers'Range);

      protected Progress is
         procedure Started;
         procedure Finished (Cancelled : Boolean);
         entry All_Started;
         entry All_Finished;
         function Passed return Boolean;
      private
         Started_Count  : Natural := 0;
         Finished_Count : Natural := 0;
         All_OK         : Boolean := True;
      end Progress;

      protected body Progress is
         procedure Started is
         begin
            Started_Count := Started_Count + 1;
         end Started;
         procedure Finished (Cancelled : Boolean) is
         begin
            All_OK := All_OK and Cancelled;
            Finished_Count := Finished_Count + 1;
         end Finished;
         entry All_Started when Started_Count = Servers'Length is
         begin
            null;
         end All_Started;
         entry All_Finished when Finished_Count = Servers'Length is
         begin
            null;
         end All_Finished;
         function Passed return Boolean is (All_OK);
      end Progress;

      task type Worker
        (Index : Positive; Model : Gnatevl.Execution_Model)
      is
         pragma Task_Info (Model);
         pragma Storage_Size (64 * 1_024);
      end Worker;

      task body Worker is
         Owned : Connections.Connection;
         Data  : Ada.Streams.Stream_Element_Array (1 .. 1);
         Was_Cancelled : Boolean := False;
      begin
         Connections.Take (Manager, Servers (Index), Owned);
         Progress.Started;
         begin
            --  A ten-second legacy quantum makes this an explicit regression
            --  test: scheduler-driven cancellation must not wait for it.
            Owned.Receive_Exactly
              (Data, Cancellation_Quantum => 10.0, Token => Token'Access);
         exception
            when Connections.Operation_Cancelled =>
               Was_Cancelled := True;
         end;
         Progress.Finished (Was_Cancelled);
      exception
         when others =>
            Progress.Finished (False);
      end Worker;

      type Worker_Access is access Worker;
      Workers : array (Servers'Range) of Worker_Access;
      pragma Unreferenced (Workers);
      Cancelled_At : Ada.Real_Time.Time;
      Sample : Gnatevl.Observability.Group_Snapshot;
   begin
      for Index in Servers'Range loop
         GNAT.Sockets.Create_Socket_Pair (Servers (Index), Peers (Index));
      end loop;
      for Index in 1 .. Scale loop
         Workers (Index) :=
           new Worker (Index, Gnatevl.Event_Loop_Task);
      end loop;
      for Index in Scale + 1 .. Servers'Last loop
         Workers (Index) := new Worker (Index, Gnatevl.Native_Thread);
      end loop;
      Progress.All_Started;
      delay 0.050;
      pragma Assert (Gnatevl.Observability.Snapshot (0, Sample));
      pragma Assert
        (Sample.Interrupt_Waits = Gnatevl.Observability.Counter (Scale));
      pragma Assert
        (Sample.Descriptor_Waits = Gnatevl.Observability.Counter (Scale));
      Cancelled_At := Ada.Real_Time.Clock;
      Token.Request;
      Progress.All_Finished;
      pragma Assert
        (Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Cancelled_At) < 1.0);
      pragma Assert (Progress.Passed);
      pragma Assert (Manager.Active = 0);
      for Peer of Peers loop
         GNAT.Sockets.Close_Socket (Peer);
      end loop;
   end Run_Token_Wake;

   procedure Run_Immediate_And_Timeout is
      Manager : aliased Connections.Server (Capacity => 1);
      Token   : aliased Connections.Cancellation_Token;
      Server, Peer : GNAT.Sockets.Socket_Type;
      Owned   : Connections.Connection;
      Data    : Ada.Streams.Stream_Element_Array (1 .. 1);
      Cancelled : Boolean := False;
      Timed_Out : Boolean := False;
   begin
      GNAT.Sockets.Create_Socket_Pair (Server, Peer);
      Connections.Take (Manager, Server, Owned);
      Token.Request;
      begin
         Owned.Receive_Exactly
           (Data, Cancellation_Quantum => 10.0, Token => Token'Access);
      exception
         when Connections.Operation_Cancelled =>
            Cancelled := True;
      end;
      pragma Assert (Cancelled);
      Owned.Close;
      GNAT.Sockets.Close_Socket (Peer);

      GNAT.Sockets.Create_Socket_Pair (Server, Peer);
      declare
         Timeout_Manager : aliased Connections.Server (Capacity => 1);
         Timeout_Owned   : Connections.Connection;
      begin
         Connections.Take (Timeout_Manager, Server, Timeout_Owned);
         begin
            Timeout_Owned.Receive_Exactly
              (Data, Timeout => 0.030, Cancellation_Quantum => 10.0);
         exception
            when Gnatevl.IO.Timeout_Error =>
               Timed_Out := True;
         end;
      end;
      pragma Assert (Timed_Out);
      GNAT.Sockets.Close_Socket (Peer);
   end Run_Immediate_And_Timeout;

   procedure Run_Shutdown_Wake is
      Manager : aliased Connections.Server (Capacity => 1);
      Server, Peer : GNAT.Sockets.Socket_Type;

      protected Result is
         procedure Finished (Cancelled : Boolean);
         entry Wait;
         function Passed return Boolean;
      private
         Done : Boolean := False;
         OK   : Boolean := False;
      end Result;
      protected body Result is
         procedure Finished (Cancelled : Boolean) is
         begin
            OK := Cancelled;
            Done := True;
         end Finished;
         entry Wait when Done is begin null; end Wait;
         function Passed return Boolean is (OK);
      end Result;
   begin
      GNAT.Sockets.Create_Socket_Pair (Server, Peer);
      declare
         task Worker is
            pragma Task_Info (Gnatevl.Event_Loop_Task);
         end Worker;
         task body Worker is
            Owned : Connections.Connection;
            Data  : Ada.Streams.Stream_Element_Array (1 .. 1);
            Was_Cancelled : Boolean := False;
         begin
            Connections.Take (Manager, Server, Owned);
            begin
               Owned.Receive_Exactly
                 (Data, Cancellation_Quantum => 10.0);
            exception
               when Connections.Operation_Cancelled =>
                  Was_Cancelled := True;
            end;
            Result.Finished (Was_Cancelled);
         end Worker;
      begin
         delay 0.050;
         Manager.Request_Shutdown;
         Manager.Await_Drained;
         Result.Wait;
      end;
      pragma Assert (Result.Passed);
      GNAT.Sockets.Close_Socket (Peer);
   end Run_Shutdown_Wake;

begin
   Run_Token_Wake;
   Run_Immediate_And_Timeout;
   Run_Shutdown_Wake;
end Cancellation_Wake_Smoke;
