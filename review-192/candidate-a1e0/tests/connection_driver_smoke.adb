with Ada.Streams;
with Flyology;
with Flyology.IO.Connections;
with Flyology.IO.Connections.Drivers;
with Flyology.IO.Sockets;

procedure Connection_Driver_Smoke is
   package Connections renames Flyology.IO.Connections;
   package Drivers renames Flyology.IO.Connections.Drivers;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use type Drivers.Step_Result;
   use type Drivers.Wait_Result;

   protected type Coordination is
      procedure Waiting;
      procedure Finish (Value : Boolean);
      entry Await_Waiting;
      entry Await_Finished;
      function Passed return Boolean;
   private
      Is_Waiting : Boolean := False;
      Is_Done    : Boolean := False;
      Is_OK      : Boolean := False;
   end Coordination;

   protected body Coordination is
      procedure Waiting is
      begin
         Is_Waiting := True;
      end Waiting;

      procedure Finish (Value : Boolean) is
      begin
         Is_OK := Value;
         Is_Done := True;
      end Finish;

      entry Await_Waiting when Is_Waiting is
      begin
         null;
      end Await_Waiting;

      entry Await_Finished when Is_Done is
      begin
         null;
      end Await_Finished;

      function Passed return Boolean
      is (Is_OK);
   end Coordination;

   procedure Close_If_Open (Socket : in out Sockets.Socket_Type) is
   begin
      if Sockets.Is_Open (Socket) then
         Sockets.Close_Socket (Socket);
      end if;
   exception
      when others =>
         null;
   end Close_If_Open;

   procedure Run_Full_Duplex (Model : Flyology.Execution_Model) is
      Manager : aliased Connections.Server (Capacity => 1);
      Item    : Connections.Connection;
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
      Wakeup  : Drivers.Outbound_Wakeup;
      State   : Coordination;
      Reply   : Stream_Element_Array (1 .. 2);
   begin
      Sockets.Create_Socket_Pair (Socket, Peer);
      Connections.Take (Manager, Socket, Item);
      Sockets.Send_All (Peer, [11, 12, 13]);
      Drivers.Signal (Wakeup);
      Drivers.Signal (Wakeup);

      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
            procedure Pump (IO : in out Drivers.Capability) is
               Incoming : Stream_Element_Array (1 .. 3);
               Last     : Stream_Element_Offset;
               Step     : Drivers.Step_Result;
               Ready    : Drivers.Wait_Result;
            begin
               Drivers.Receive (IO, Incoming, Last, Step);
               pragma
                 Assert
                   (Step = Drivers.Made_Progress
                      and then Last = Incoming'Last
                      and then Incoming = [11, 12, 13]);
               Drivers.Send (IO, [1 => 21, 2 => 22], Last, Step);
               pragma Assert (Step = Drivers.Made_Progress and then Last = 2);

               Drivers.Receive (IO, Incoming, Last, Step);
               pragma Assert (Step = Drivers.Need_Read and then Last < Incoming'First);

               Drivers.Wait (IO, Wakeup, Drivers.Protocol_Only, 0.0, Ready);
               pragma Assert (Ready = Drivers.Outbound_Ready);
               Drivers.Wait (IO, Wakeup, Drivers.Protocol_Only, 0.0, Ready);
               pragma Assert (Ready = Drivers.Wait_Timed_Out);

               State.Waiting;
               Drivers.Wait (IO, Wakeup, Drivers.Protocol_Only, 1.0, Ready);
               pragma Assert (Ready = Drivers.Outbound_Ready);
            end Pump;
         begin
            Drivers.Run (Item, Pump'Access, Timeout => 2.0);
            State.Finish (True);
         exception
            when others =>
               State.Finish (False);
         end Worker;
      begin
         State.Await_Waiting;
         Drivers.Signal (Wakeup);
         State.Await_Finished;
      end;

      pragma Assert (State.Passed);
      pragma Assert (Connections.Is_Open (Item));
      pragma Assert (Manager.Active = 1);
      Sockets.Receive_Exactly (Peer, Reply, Timeout => 1.0);
      pragma Assert (Reply = [21, 22]);

      --  Returning from Run restores the ordinary synchronous API.
      Item.Send_All ([31], Timeout => 1.0);
      Sockets.Receive_Exactly (Peer, Reply (1 .. 1), Timeout => 1.0);
      pragma Assert (Reply (1) = 31);
      Connections.Close (Item);
      pragma Assert (Manager.Active = 0);
      Close_If_Open (Peer);
   end Run_Full_Duplex;

   procedure Run_Backpressure (Model : Flyology.Execution_Model) is
      Manager : aliased Connections.Server (Capacity => 1);
      Item    : Connections.Connection;
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
      State   : Coordination;
   begin
      Sockets.Create_Socket_Pair (Socket, Peer);
      Connections.Take (Manager, Socket, Item);

      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
            procedure Pump (IO : in out Drivers.Capability) is
               Data    : constant Stream_Element_Array (1 .. 65_536) := [others => 7];
               Last    : Stream_Element_Offset;
               Step    : Drivers.Step_Result := Drivers.Made_Progress;
               Blocked : Boolean := False;
            begin
               for Attempt in 1 .. 1_024 loop
                  Drivers.Send (IO, Data, Last, Step);
                  if Step = Drivers.Need_Write then
                     Blocked := True;
                     exit;
                  end if;
                  pragma Assert (Step = Drivers.Made_Progress and then Last >= Data'First);
               end loop;
               pragma Assert (Blocked);
            end Pump;
         begin
            Drivers.Run (Item, Pump'Access, Timeout => 2.0);
            State.Finish (True);
         exception
            when others =>
               State.Finish (False);
         end Worker;
      begin
         State.Await_Finished;
      end;

      pragma Assert (State.Passed);
      pragma Assert (Connections.Is_Open (Item) and then Manager.Active = 1);
      Connections.Close (Item);
      pragma Assert (Manager.Active = 0);
      Close_If_Open (Peer);
   end Run_Backpressure;

   type Interruption_Kind is (Token_Cancel, Manager_Shutdown, Concurrent_Close);

   procedure Run_Interruption (Model : Flyology.Execution_Model; Kind : Interruption_Kind) is
      Manager : aliased Connections.Server (Capacity => 1);
      Token   : aliased Connections.Cancellation_Token;
      Item    : Connections.Connection;
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
      Wakeup  : Drivers.Outbound_Wakeup;
      State   : Coordination;
   begin
      Sockets.Create_Socket_Pair (Socket, Peer);
      Connections.Take (Manager, Socket, Item);

      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
            procedure Pump (IO : in out Drivers.Capability) is
               Ready : Drivers.Wait_Result;
            begin
               State.Waiting;
               Drivers.Wait (IO, Wakeup, Drivers.Protocol_Only, Flyology.IO.Infinite, Ready);
            end Pump;
         begin
            begin
               Drivers.Run (Item, Pump'Access, Timeout => 2.0, Token => Token'Access);
               State.Finish (False);
            exception
               when Connections.Operation_Cancelled =>
                  State.Finish (True);
            end;
         exception
            when others =>
               State.Finish (False);
         end Worker;
      begin
         State.Await_Waiting;
         case Kind is
            when Token_Cancel     =>
               Token.Request;

            when Manager_Shutdown =>
               Manager.Request_Shutdown;

            when Concurrent_Close =>
               Connections.Close (Item);
         end case;
         State.Await_Finished;
      end;

      pragma Assert (State.Passed);
      if Kind = Concurrent_Close then
         pragma Assert (not Connections.Is_Open (Item) and then Manager.Active = 0);
      else
         pragma Assert (Connections.Is_Open (Item) and then Manager.Active = 1);
         Connections.Close (Item);
      end if;
      if Kind = Manager_Shutdown then
         Manager.Await_Drained;
      end if;
      pragma Assert (Manager.Active = 0);
      Close_If_Open (Peer);
   end Run_Interruption;

   procedure Run_Abort_Restoration (Model : Flyology.Execution_Model) is
      Manager : aliased Connections.Server (Capacity => 1);
      Item    : Connections.Connection;
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
      Wakeup  : Drivers.Outbound_Wakeup;
      State   : Coordination;
      Byte    : Stream_Element_Array (1 .. 1);
   begin
      Sockets.Create_Socket_Pair (Socket, Peer);
      Connections.Take (Manager, Socket, Item);

      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
            procedure Pump (IO : in out Drivers.Capability) is
               Ready : Drivers.Wait_Result;
            begin
               State.Waiting;
               Drivers.Wait (IO, Wakeup, Drivers.Protocol_Only, Flyology.IO.Infinite, Ready);
            end Pump;
         begin
            Drivers.Run (Item, Pump'Access);
         end Worker;
      begin
         State.Await_Waiting;
         abort Worker;
         --  Native Ada abort does not promise to interrupt poll(2). Supply a
         --  normal driver wake so the task reaches an abort completion point;
         --  lightweight waits are safe under the same race.
         Drivers.Signal (Wakeup);
      end;

      pragma Assert (Connections.Is_Open (Item));
      pragma Assert (Manager.Active = 1);
      Item.Send_All ([41], Timeout => 1.0);
      Sockets.Receive_Exactly (Peer, Byte, Timeout => 1.0);
      pragma Assert (Byte (1) = 41);
      Connections.Close (Item);
      pragma Assert (Manager.Active = 0);
      Close_If_Open (Peer);
   end Run_Abort_Restoration;

   procedure Run_Zero_Deadline (Model : Flyology.Execution_Model) is
      Manager : aliased Connections.Server (Capacity => 1);
      Item    : Connections.Connection;
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
      State   : Coordination;
   begin
      Sockets.Create_Socket_Pair (Socket, Peer);
      Connections.Take (Manager, Socket, Item);

      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
            procedure Pump (IO : in out Drivers.Capability) is
               pragma Unreferenced (IO);
            begin
               State.Finish (False);
            end Pump;
         begin
            begin
               Drivers.Run (Item, Pump'Access, Timeout => 0.0);
               State.Finish (False);
            exception
               when Flyology.IO.Timeout_Error =>
                  State.Finish (True);
            end;
         exception
            when others =>
               State.Finish (False);
         end Worker;
      begin
         State.Await_Finished;
      end;

      pragma Assert (State.Passed);
      pragma Assert (Connections.Is_Open (Item) and then Manager.Active = 1);
      Connections.Close (Item);
      pragma Assert (Manager.Active = 0);
      Close_If_Open (Peer);
   end Run_Zero_Deadline;

   procedure Run_Deadline_Restoration (Model : Flyology.Execution_Model) is
      Manager : aliased Connections.Server (Capacity => 1);
      Item    : Connections.Connection;
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
      Wakeup  : Drivers.Outbound_Wakeup;
      State   : Coordination;
   begin
      Sockets.Create_Socket_Pair (Socket, Peer);
      Connections.Take (Manager, Socket, Item);

      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
            procedure Pump (IO : in out Drivers.Capability) is
               Ready : Drivers.Wait_Result;
            begin
               Drivers.Wait (IO, Wakeup, Drivers.Protocol_Only, Flyology.IO.Infinite, Ready);
            end Pump;
         begin
            begin
               Drivers.Run (Item, Pump'Access, Timeout => 0.02);
               State.Finish (False);
            exception
               when Flyology.IO.Timeout_Error =>
                  State.Finish (True);
            end;
         exception
            when others =>
               State.Finish (False);
         end Worker;
      begin
         State.Await_Finished;
      end;

      pragma Assert (State.Passed);
      pragma Assert (Connections.Is_Open (Item) and then Manager.Active = 1);
      Connections.Close (Item);
      pragma Assert (Manager.Active = 0);
      Close_If_Open (Peer);
   end Run_Deadline_Restoration;

   procedure Run_All (Model : Flyology.Execution_Model) is
   begin
      Run_Full_Duplex (Model);
      Run_Backpressure (Model);
      for Kind in Interruption_Kind loop
         Run_Interruption (Model, Kind);
      end loop;
      Run_Abort_Restoration (Model);
      Run_Zero_Deadline (Model);
      Run_Deadline_Restoration (Model);
   end Run_All;

begin
   Run_All (Flyology.Lightweight_Task);
   Run_All (Flyology.Native_Task);
end Connection_Driver_Smoke;
