with Ada.Real_Time;
with Ada.Streams;
with Flyology.IO.Sockets;
with Flyology;
with Flyology.IO;
with Flyology.IO.Connections;
with Flyology.Observability;
with Interfaces;

procedure Cancellation_Wake_Smoke is
   package Connections renames Flyology.IO.Connections;
   use type Ada.Real_Time.Time;
   use type Interfaces.Unsigned_64;

   Scale : constant Positive := 64;
   type Socket_Array is array
     (Positive range <>) of Flyology.IO.Sockets.Socket_Type;

   procedure Run_Token_Wake is
      Manager : aliased Connections.Server (Capacity => Scale);
      Token   : aliased Connections.Cancellation_Token;
      Servers : Socket_Array (1 .. Scale);
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
        (Index : Positive; Model : Flyology.Execution_Model)
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
         Owned.Close;
         Progress.Finished (Was_Cancelled);
      exception
         when others =>
            Progress.Finished (False);
      end Worker;

      type Worker_Access is access Worker;
      Workers : array (Servers'Range) of Worker_Access;
      pragma Unreferenced (Workers);
      Cancelled_At : Ada.Real_Time.Time;
      Sample : Flyology.Observability.Group_Snapshot;
      Park_Deadline : Ada.Real_Time.Time;
   begin
      for Index in Servers'Range loop
         Flyology.IO.Sockets.Create_Socket_Pair
           (Servers (Index), Peers (Index));
      end loop;
      for Index in Servers'Range loop
         Workers (Index) :=
           new Worker (Index, Flyology.Lightweight_Task);
      end loop;
      Progress.All_Started;
      Park_Deadline := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
      loop
         pragma Assert (Flyology.Observability.Snapshot (0, Sample));
         exit when
           Sample.Interrupt_Waits = Flyology.Observability.Counter (Scale)
           and then
             Sample.Descriptor_Waits = Flyology.Observability.Counter (Scale);
         if Ada.Real_Time.Clock >= Park_Deadline then
            Token.Request;
            raise Program_Error with
              "lightweight cancellable connections did not reach the poller";
         end if;
         delay 0.001;
      end loop;
      Cancelled_At := Ada.Real_Time.Clock;
      Token.Request;
      Progress.All_Finished;
      pragma Assert
        (Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Cancelled_At) < 1.0);
      pragma Assert (Progress.Passed);
      pragma Assert (Manager.Active = 0);
      for Peer of Peers loop
         Flyology.IO.Sockets.Close_Socket (Peer);
      end loop;
   end Run_Token_Wake;

   procedure Run_Immediate_And_Timeout is
      Manager : aliased Connections.Server (Capacity => 1);
      Token   : aliased Connections.Cancellation_Token;
      Server, Peer : Flyology.IO.Sockets.Socket_Type;
      Owned   : Connections.Connection;
      Data    : Ada.Streams.Stream_Element_Array (1 .. 1);
      Cancelled : Boolean := False;
      Timed_Out : Boolean := False;
   begin
      Flyology.IO.Sockets.Create_Socket_Pair (Server, Peer);
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
      Flyology.IO.Sockets.Close_Socket (Peer);

      Flyology.IO.Sockets.Create_Socket_Pair (Server, Peer);
      declare
         Timeout_Manager : aliased Connections.Server (Capacity => 1);
         Timeout_Owned   : Connections.Connection;
      begin
         Connections.Take (Timeout_Manager, Server, Timeout_Owned);
         begin
            Timeout_Owned.Receive_Exactly
              (Data, Timeout => 0.030, Cancellation_Quantum => 10.0);
         exception
            when Flyology.IO.Timeout_Error =>
               Timed_Out := True;
         end;
      end;
      pragma Assert (Timed_Out);
      Flyology.IO.Sockets.Close_Socket (Peer);
   end Run_Immediate_And_Timeout;

   procedure Run_Shutdown_Wake is
      Manager : aliased Connections.Server (Capacity => 1);
      Server, Peer : Flyology.IO.Sockets.Socket_Type;

      protected Result is
         procedure Started;
         procedure Finished (Cancelled : Boolean);
         entry Wait_Started;
         entry Wait;
         function Passed return Boolean;
      private
         Is_Started : Boolean := False;
         Done : Boolean := False;
         OK   : Boolean := False;
      end Result;
      protected body Result is
         procedure Started is
         begin
            Is_Started := True;
         end Started;
         procedure Finished (Cancelled : Boolean) is
         begin
            OK := Cancelled;
            Done := True;
         end Finished;
         entry Wait_Started when Is_Started is begin null; end Wait_Started;
         entry Wait when Done is begin null; end Wait;
         function Passed return Boolean is (OK);
      end Result;
   begin
      Flyology.IO.Sockets.Create_Socket_Pair (Server, Peer);
      declare
         task Worker is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Worker;
         task body Worker is
            Owned : Connections.Connection;
            Data  : Ada.Streams.Stream_Element_Array (1 .. 1);
            Was_Cancelled : Boolean := False;
         begin
            Connections.Take (Manager, Server, Owned);
            Result.Started;
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
         Result.Wait_Started;
         Manager.Request_Shutdown;
         Manager.Await_Drained;
         Result.Wait;
      end;
      pragma Assert (Result.Passed);
      Flyology.IO.Sockets.Close_Socket (Peer);
   end Run_Shutdown_Wake;

begin
   Run_Token_Wake;
   Run_Immediate_And_Timeout;
   Run_Shutdown_Wake;
end Cancellation_Wake_Smoke;
