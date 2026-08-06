with Ada.Streams;
with Flyology;
with Flyology.IO.Connections;
with Flyology.IO.Connections.Drivers;
with Flyology.IO.Connections.TLS;
with Flyology.IO.Sockets;
with Flyology.IO.TLS;
with TLS_Test_Provider;

procedure Connection_Driver_TLS_Smoke is
   package Connections renames Flyology.IO.Connections;
   package Drivers renames Flyology.IO.Connections.Drivers;
   package Connection_TLS renames Flyology.IO.Connections.TLS;
   package Sockets renames Flyology.IO.Sockets;
   package TLS renames Flyology.IO.TLS;
   package Provider renames TLS_Test_Provider;

   use Ada.Streams;
   use type Drivers.Step_Result;
   use type Drivers.Wait_Result;
   use type Provider.Operation_Counts;

   protected type Result_Box is
      procedure Finish (Value : Boolean);
      entry Await_Finished;
      function Passed return Boolean;
   private
      Done : Boolean := False;
      OK   : Boolean := False;
   end Result_Box;

   protected body Result_Box is
      procedure Finish (Value : Boolean) is
      begin
         OK := Value;
         Done := True;
      end Finish;

      entry Await_Finished when Done is
      begin
         null;
      end Await_Finished;

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

   procedure Configure (Backend : in out Provider.Provider) is
   begin
      Provider.Set_Script
        (Backend, Provider.Handshake_Operation,
         [1 => (TLS.Complete, Provider.Preserve_Output, 0)]);
      Provider.Set_Script
        (Backend, Provider.Receive_Operation,
         [1 => (TLS.Want_Write, Provider.Preserve_Output, 0),
          2 => (TLS.Want_Read, Provider.Preserve_Output, 0),
          3 => (TLS.Complete, Provider.Advance_Output, 2)]);
      Provider.Set_Script
        (Backend, Provider.Send_Operation,
         [1 => (TLS.Want_Read, Provider.Preserve_Output, 0),
          2 => (TLS.Want_Write, Provider.Preserve_Output, 0),
          3 => (TLS.Complete, Provider.Advance_Output, 2)]);
      Provider.Set_Script
        (Backend, Provider.Shutdown_Operation,
         [1 => (TLS.Complete, Provider.Preserve_Output, 0)]);
   end Configure;

   procedure Run_Progress (Model : Flyology.Execution_Model) is
      Manager : aliased Connections.Server (Capacity => 1);
      Item    : Connections.Connection;
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
      Backend : Provider.Provider;
      Wakeup  : Drivers.Outbound_Wakeup;
      Result  : Result_Box;
      State   : Provider.State_Telemetry;
   begin
      Provider.Reset_State_Telemetry;
      Configure (Backend);
      Sockets.Create_Socket_Pair (Socket, Peer);
      Connections.Take (Manager, Socket, Item);
      Connection_TLS.Upgrade
        (Item, Backend, TLS.Server, "", Timeout => 1.0);
      --  The scripted provider does not consume the descriptor. Keep it
      --  readable so Want_Read waits can be exercised deterministically.
      Sockets.Send_All (Peer, [99]);

      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
            procedure Pump (IO : in out Drivers.Capability) is
               Data  : Stream_Element_Array (1 .. 2);
               Last  : Stream_Element_Offset;
               Step  : Drivers.Step_Result;
               Ready : Drivers.Wait_Result;
            begin
               Drivers.Receive (IO, Data, Last, Step);
               pragma Assert (Step = Drivers.Need_Write);
               Drivers.Wait
                 (IO, Wakeup, Drivers.Write_Interest, 1.0, Ready);
               pragma Assert (Ready = Drivers.Transport_Ready);

               Drivers.Receive (IO, Data, Last, Step);
               pragma Assert (Step = Drivers.Need_Read);
               Drivers.Wait
                 (IO, Wakeup, Drivers.Read_Interest, 1.0, Ready);
               pragma Assert (Ready = Drivers.Transport_Ready);

               Drivers.Receive (IO, Data, Last, Step);
               pragma Assert
                 (Step = Drivers.Made_Progress
                    and then Last = Data'Last
                    and then Data = [42, 42]);

               Drivers.Send (IO, [1 => 51, 2 => 52], Last, Step);
               pragma Assert (Step = Drivers.Need_Read);
               Drivers.Wait
                 (IO, Wakeup, Drivers.Read_Interest, 1.0, Ready);
               pragma Assert (Ready = Drivers.Transport_Ready);

               Drivers.Send (IO, [1 => 51, 2 => 52], Last, Step);
               pragma Assert (Step = Drivers.Need_Write);
               Drivers.Wait
                 (IO, Wakeup, Drivers.Write_Interest, 1.0, Ready);
               pragma Assert (Ready = Drivers.Transport_Ready);

               Drivers.Send (IO, [1 => 51, 2 => 52], Last, Step);
               pragma Assert
                 (Step = Drivers.Made_Progress and then Last = 2);
            end Pump;
         begin
            Drivers.Run (Item, Pump'Access, Timeout => 2.0);
            Result.Finish (True);
         exception
            when others =>
               Result.Finish (False);
         end Worker;
      begin
         Result.Await_Finished;
      end;

      pragma Assert (Result.Passed);
      pragma Assert (Connections.Is_Open (Item) and then Manager.Active = 1);
      Provider.Get_State_Telemetry (State);
      pragma Assert
        (State.Calls =
           [Provider.Handshake_Operation => 1,
            Provider.Receive_Operation => 3,
            Provider.Send_Operation => 3,
            Provider.Shutdown_Operation => 0]);
      Connection_TLS.Shutdown (Item, Timeout => 1.0);
      Connections.Close (Item);
      pragma Assert (Manager.Active = 0);
      Close_If_Open (Peer);
      Provider.Get_State_Telemetry (State);
      pragma Assert
        (State.Sessions_Created = 1
           and then State.Sessions_Finalized = 1
           and then State.Sessions_Live = 0);
   end Run_Progress;

   procedure Run_Invalid_Progress (Model : Flyology.Execution_Model) is
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
         [1 => (TLS.Complete, Provider.Preserve_Output, 0)]);
      Provider.Set_Script
        (Backend, Provider.Receive_Operation,
         [1 => (TLS.Complete, Provider.Preserve_Output, 0)]);
      Sockets.Create_Socket_Pair (Socket, Peer);
      Connections.Take (Manager, Socket, Item);
      Connection_TLS.Upgrade
        (Item, Backend, TLS.Server, "", Timeout => 1.0);

      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
            procedure Pump (IO : in out Drivers.Capability) is
               Data : Stream_Element_Array (1 .. 1);
               Last : Stream_Element_Offset;
               Step : Drivers.Step_Result;
            begin
               Drivers.Receive (IO, Data, Last, Step);
            end Pump;
         begin
            begin
               Drivers.Run (Item, Pump'Access, Timeout => 1.0);
               Result.Finish (False);
            exception
               when TLS.TLS_Error =>
                  Result.Finish (True);
            end;
         exception
            when others =>
               Result.Finish (False);
         end Worker;
      begin
         Result.Await_Finished;
      end;

      pragma Assert (Result.Passed);
      pragma Assert (Connections.Is_Open (Item) and then Manager.Active = 1);
      Connections.Close (Item);
      pragma Assert (Manager.Active = 0);
      Close_If_Open (Peer);
   end Run_Invalid_Progress;

   procedure Run_All (Model : Flyology.Execution_Model) is
   begin
      Run_Progress (Model);
      Run_Invalid_Progress (Model);
   end Run_All;

begin
   Run_All (Flyology.Lightweight_Task);
   Run_All (Flyology.Native_Task);
end Connection_Driver_TLS_Smoke;
