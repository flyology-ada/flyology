with Ada.Streams;
with Flyology;
with Flyology.Cancellation;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.IO.TLS;
with Interfaces.C;
with TLS_Test_Provider;

procedure TLS_State_Model is
   package TLS renames Flyology.IO.TLS;
   package Provider renames TLS_Test_Provider;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use type Interfaces.C.int;
   use type Provider.Operation_Counts;

   type Model_Array is array (Positive range <>) of Flyology.Execution_Model;
   Models : constant Model_Array := [Flyology.Lightweight_Task, Flyology.Native_Task];

   function Open_FD_Count return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_open_fd_count";

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

      function Passed return Boolean
      is (OK);
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

   procedure Warm_Model (Model : Flyology.Execution_Model) is
      task Worker is
         pragma Task_Info (Model);
      end Worker;

      task body Worker is
      begin
         delay 0.0;
      end Worker;
   begin
      null;
   end Warm_Model;

   procedure Assert_Resources (Created : Natural) is
      State : Provider.State_Telemetry;
   begin
      Provider.Get_State_Telemetry (State);
      pragma Assert (State.Sessions_Created = Created);
      pragma Assert (State.Sessions_Finalized = Created);
      pragma Assert (State.Sessions_Live = 0);
      pragma Assert (State.Finalized_While_FD_Open = Created);
   end Assert_Resources;

   procedure Prime_Readiness (Peer : Sockets.Socket_Type) is
      Ready : constant Stream_Element_Array := [1];
      Last  : Stream_Element_Offset;
   begin
      Sockets.Send_Socket (Peer, Ready, Last);
      pragma Assert (Last = Ready'Last);
   end Prime_Readiness;

   procedure Configure_Happy_Path (Backend : in out Provider.Provider) is
   begin
      Provider.Set_Script
        (Backend,
         Provider.Handshake_Operation,
         [(TLS.Want_Read, Provider.Preserve_Output, 0),
          (TLS.Want_Write, Provider.Preserve_Output, 0),
          (TLS.Want_Read, Provider.Preserve_Output, 0),
          (TLS.Complete, Provider.Preserve_Output, 0)]);
      Provider.Set_Script
        (Backend,
         Provider.Receive_Operation,
         [(TLS.Want_Write, Provider.Preserve_Output, 0),
          (TLS.Want_Read, Provider.Preserve_Output, 0),
          (TLS.Complete, Provider.Advance_Output, 1),
          (TLS.Want_Write, Provider.Preserve_Output, 0),
          (TLS.Complete, Provider.Advance_Output, 2)]);
      Provider.Set_Script
        (Backend,
         Provider.Send_Operation,
         [(TLS.Want_Read, Provider.Preserve_Output, 0),
          (TLS.Want_Write, Provider.Preserve_Output, 0),
          (TLS.Complete, Provider.Advance_Output, 1),
          (TLS.Want_Read, Provider.Preserve_Output, 0),
          (TLS.Complete, Provider.Advance_Output, 2)]);
      Provider.Set_Script
        (Backend,
         Provider.Shutdown_Operation,
         [(TLS.Want_Write, Provider.Preserve_Output, 0),
          (TLS.Want_Read, Provider.Preserve_Output, 0),
          (TLS.Want_Write, Provider.Preserve_Output, 0),
          (TLS.Complete, Provider.Preserve_Output, 0)]);
   end Configure_Happy_Path;

   type Lifecycle_State is (Closed, Owned, Handshaken, Receiving, Sending, Shutdown_Complete);
   type Lifecycle_Action is
     (Take_Action,
      Handshake_Action,
      Receive_Action,
      Send_Action,
      Shutdown_Action,
      Close_Action,
      Close_Again_Action);
   type Transition is record
      Action : Lifecycle_Action;
      From   : Lifecycle_State;
      To     : Lifecycle_State;
      Open   : Boolean;
   end record;

   Lifecycle : constant array (Positive range <>) of Transition :=
     [(Take_Action, Closed, Owned, True),
      (Handshake_Action, Owned, Handshaken, True),
      (Receive_Action, Handshaken, Receiving, True),
      (Send_Action, Receiving, Sending, True),
      (Shutdown_Action, Sending, Shutdown_Complete, True),
      (Close_Action, Shutdown_Complete, Closed, False),
      (Close_Again_Action, Closed, Closed, False)];

   procedure Run_Lifecycle (Model : Flyology.Execution_Model) is
      Backend : Provider.Provider;
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
      Item    : TLS.Connection;
      Result  : Result_Box;
   begin
      Provider.Reset_State_Telemetry;
      Configure_Happy_Path (Backend);
      Sockets.Create_Socket_Pair (Socket, Peer);
      Prime_Readiness (Peer);
      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
            State    : Lifecycle_State := Closed;
            Input    : constant Stream_Element_Array := [1, 2, 3];
            Received : Stream_Element_Array (1 .. 3);
         begin
            for Edge of Lifecycle loop
               pragma Assert (State = Edge.From);
               case Edge.Action is
                  when Take_Action                       =>
                     TLS.Take (Backend, Socket, TLS.Server, "", Item);
                     pragma Assert (not Sockets.Is_Open (Socket));

                  when Handshake_Action                  =>
                     TLS.Handshake (Item, Timeout => 1.0);

                  when Receive_Action                    =>
                     TLS.Receive_Exactly (Item, Received, Timeout => 1.0);
                     pragma Assert (Received = [42, 42, 42]);

                  when Send_Action                       =>
                     TLS.Send_All (Item, Input, Timeout => 1.0);

                  when Shutdown_Action                   =>
                     TLS.Shutdown (Item, Timeout => 1.0);

                  when Close_Action | Close_Again_Action =>
                     TLS.Close (Item);
               end case;
               State := Edge.To;
               pragma Assert (TLS.Is_Open (Item) = Edge.Open);
            end loop;
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
      Assert_Resources (Created => 1);
      declare
         State : Provider.State_Telemetry;
      begin
         Provider.Get_State_Telemetry (State);
         pragma
           Assert
             (State.Calls
                = [Provider.Handshake_Operation => 4,
                   Provider.Receive_Operation   => 5,
                   Provider.Send_Operation      => 5,
                   Provider.Shutdown_Operation  => 4]);
      end;
   end Run_Lifecycle;

   type Invalid_Case is record
      Operation : Provider.Operation_Kind;
      Step      : Provider.Script_Step;
   end record;

   Invalid_Results : constant array (Positive range <>) of Invalid_Case :=
     [(Provider.Handshake_Operation, (TLS.Peer_Closed, Provider.Preserve_Output, 0)),
      (Provider.Handshake_Operation, (TLS.Failed, Provider.Preserve_Output, 0)),
      (Provider.Receive_Operation, (TLS.Complete, Provider.Before_First, 0)),
      (Provider.Receive_Operation, (TLS.Want_Read, Provider.After_Last, 0)),
      (Provider.Receive_Operation, (TLS.Peer_Closed, Provider.After_Last, 0)),
      (Provider.Send_Operation, (TLS.Complete, Provider.Preserve_Output, 0)),
      (Provider.Send_Operation, (TLS.Want_Write, Provider.Advance_Output, 1)),
      (Provider.Send_Operation, (TLS.Peer_Closed, Provider.Advance_Output, 1)),
      (Provider.Shutdown_Operation, (TLS.Peer_Closed, Provider.Preserve_Output, 0)),
      (Provider.Shutdown_Operation, (TLS.Failed, Provider.Preserve_Output, 0))];

   procedure Run_Invalid_Results (Model : Flyology.Execution_Model) is
      Result : Result_Box;
   begin
      Provider.Reset_State_Telemetry;
      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
         begin
            for Test of Invalid_Results loop
               declare
                  Backend  : Provider.Provider;
                  Socket   : Sockets.Socket_Type;
                  Peer     : Sockets.Socket_Type;
                  Item     : TLS.Connection;
                  Buffer   : Stream_Element_Array (3 .. 4);
                  Last     : Stream_Element_Offset;
                  Rejected : Boolean := False;
               begin
                  Provider.Set_Script (Backend, Test.Operation, [1 => Test.Step]);
                  Sockets.Create_Socket_Pair (Socket, Peer);
                  TLS.Take (Backend, Socket, TLS.Server, "", Item);
                  begin
                     case Test.Operation is
                        when Provider.Handshake_Operation =>
                           TLS.Handshake (Item, Timeout => 0.0);

                        when Provider.Receive_Operation   =>
                           TLS.Receive (Item, Buffer, Last, Timeout => 0.0);

                        when Provider.Send_Operation      =>
                           TLS.Send_All (Item, Buffer, Timeout => 0.0);

                        when Provider.Shutdown_Operation  =>
                           TLS.Shutdown (Item, Timeout => 0.0);
                     end case;
                  exception
                     when TLS.TLS_Error =>
                        Rejected := True;
                  end;
                  pragma Assert (Rejected);
                  TLS.Close (Item);
                  Close_If_Open (Peer);
               end;
            end loop;
            Result.Report (True);
         exception
            when others =>
               Result.Report (False);
         end Worker;
      begin
         Result.Wait;
      end;
      pragma Assert (Result.Passed);
      Assert_Resources (Invalid_Results'Length);
   end Run_Invalid_Results;

   procedure Run_Immediate_Timeout (Model : Flyology.Execution_Model) is
      Backend : Provider.Provider;
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
      Item    : TLS.Connection;
      Result  : Result_Box;
   begin
      Provider.Reset_State_Telemetry;
      Provider.Set_Script
        (Backend, Provider.Handshake_Operation, [1 => (TLS.Want_Read, Provider.Preserve_Output, 0)]);
      Sockets.Create_Socket_Pair (Socket, Peer);
      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
            Timed_Out : Boolean := False;
         begin
            TLS.Take (Backend, Socket, TLS.Server, "", Item);
            begin
               TLS.Handshake (Item, Timeout => 0.0);
            exception
               when Flyology.IO.Timeout_Error =>
                  Timed_Out := True;
            end;
            Result.Report (Timed_Out and then TLS.Is_Open (Item));
         exception
            when others =>
               Result.Report (False);
         end Worker;
      begin
         Result.Wait;
      end;
      pragma Assert (Result.Passed);
      TLS.Close (Item);
      Close_If_Open (Peer);
      Assert_Resources (Created => 1);
   end Run_Immediate_Timeout;

   procedure Run_Pre_Cancelled (Model : Flyology.Execution_Model) is
      Backend : Provider.Provider;
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
      Item    : TLS.Connection;
      Token   : aliased Flyology.Cancellation.Token;
      Result  : Result_Box;
   begin
      Provider.Reset_State_Telemetry;
      Provider.Set_Script
        (Backend, Provider.Handshake_Operation, [1 => (TLS.Complete, Provider.Preserve_Output, 0)]);
      Sockets.Create_Socket_Pair (Socket, Peer);
      TLS.Take (Backend, Socket, TLS.Server, "", Item);
      Token.Request;
      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
            Cancelled : Boolean := False;
         begin
            begin
               TLS.Handshake (Item, Token => Token'Access);
            exception
               when TLS.Operation_Cancelled =>
                  Cancelled := True;
            end;
            Result.Report (Cancelled and then TLS.Is_Open (Item));
         exception
            when others =>
               Result.Report (False);
         end Worker;
      begin
         Result.Wait;
      end;
      pragma Assert (Result.Passed);
      declare
         State : Provider.State_Telemetry;
      begin
         Provider.Get_State_Telemetry (State);
         pragma Assert (State.Calls = Provider.Operation_Counts'[others => 0]);
      end;
      TLS.Close (Item);
      Close_If_Open (Peer);
      Assert_Resources (Created => 1);
   end Run_Pre_Cancelled;

   procedure Run_Requested_Cancellation (Model : Flyology.Execution_Model) is
      Backend : Provider.Provider;
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
      Item    : TLS.Connection;
      Token   : aliased Flyology.Cancellation.Token;
      Result  : Result_Box;
   begin
      Provider.Reset_State_Telemetry;
      Provider.Set_Script
        (Backend,
         Provider.Handshake_Operation,
         [(TLS.Want_Read, Provider.Preserve_Output, 0), (TLS.Complete, Provider.Preserve_Output, 0)]);
      Sockets.Create_Socket_Pair (Socket, Peer);
      TLS.Take (Backend, Socket, TLS.Server, "", Item);
      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
            Cancelled : Boolean := False;
         begin
            begin
               TLS.Handshake (Item, Token => Token'Access);
            exception
               when TLS.Operation_Cancelled =>
                  Cancelled := True;
            end;
            Result.Report (Cancelled and then TLS.Is_Open (Item));
         exception
            when others =>
               Result.Report (False);
         end Worker;
      begin
         Provider.Wait_For_First_Call (Provider.Handshake_Operation);
         Token.Request;
         Result.Wait;
      end;
      pragma Assert (Result.Passed);
      TLS.Close (Item);
      Close_If_Open (Peer);
      Assert_Resources (Created => 1);
   end Run_Requested_Cancellation;

   procedure Run_Queued_Serialization (Model : Flyology.Execution_Model) is
      Backend : Provider.Provider;
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
      Item    : TLS.Connection;
      Token   : aliased Flyology.Cancellation.Token;

      protected Progress is
         procedure Release_Queued;
         entry Start_Queued;
         procedure Finished (Passed : Boolean);
         entry Wait_Queued;
         entry Wait_All;
         function Passed return Boolean;
      private
         May_Start   : Boolean := False;
         Done        : Natural := 0;
         Queued_Done : Boolean := False;
         OK          : Boolean := True;
      end Progress;

      protected body Progress is
         procedure Release_Queued is
         begin
            May_Start := True;
         end Release_Queued;
         entry Start_Queued when May_Start is
         begin
            null;
         end Start_Queued;
         procedure Finished (Passed : Boolean) is
         begin
            Done := Done + 1;
            OK := OK and Passed;
            if Done = 1 then
               Queued_Done := True;
            end if;
         end Finished;
         entry Wait_Queued when Queued_Done is
         begin
            null;
         end Wait_Queued;
         entry Wait_All when Done = 2 is
         begin
            null;
         end Wait_All;
         function Passed return Boolean
         is (OK);
      end Progress;
   begin
      Provider.Reset_State_Telemetry;
      Provider.Set_Script
        (Backend, Provider.Handshake_Operation, [1 => (TLS.Want_Read, Provider.Preserve_Output, 0)]);
      Sockets.Create_Socket_Pair (Socket, Peer);
      TLS.Take (Backend, Socket, TLS.Server, "", Item);
      declare
         task Active is
            pragma Task_Info (Model);
         end Active;
         task Queued is
            pragma Task_Info (Model);
         end Queued;

         task body Active is
            Cancelled : Boolean := False;
         begin
            begin
               TLS.Handshake (Item, Token => Token'Access);
            exception
               when TLS.Operation_Cancelled =>
                  Cancelled := True;
            end;
            Progress.Finished (Cancelled);
         exception
            when others =>
               Progress.Finished (False);
         end Active;

         task body Queued is
            Timed_Out : Boolean := False;
         begin
            Progress.Start_Queued;
            begin
               TLS.Handshake (Item, Timeout => 0.0);
            exception
               when Flyology.IO.Timeout_Error =>
                  Timed_Out := True;
            end;
            Progress.Finished (Timed_Out);
         exception
            when others =>
               Progress.Finished (False);
         end Queued;
      begin
         Provider.Wait_For_First_Call (Provider.Handshake_Operation);
         Progress.Release_Queued;
         Progress.Wait_Queued;
         declare
            State : Provider.State_Telemetry;
         begin
            Provider.Get_State_Telemetry (State);
            pragma Assert (State.Calls (Provider.Handshake_Operation) = 1);
         end;
         Token.Request;
         Progress.Wait_All;
      end;
      pragma Assert (Progress.Passed);
      TLS.Close (Item);
      Close_If_Open (Peer);
      Assert_Resources (Created => 1);
   end Run_Queued_Serialization;

   type Model_Test is access procedure (Model : Flyology.Execution_Model);

   procedure Run_Checked (Test : not null Model_Test; Model : Flyology.Execution_Model) is
      Baseline : Interfaces.C.int;
   begin
      Warm_Model (Model);
      Baseline := Open_FD_Count;
      Test (Model);
      pragma Assert (Open_FD_Count = Baseline);
   end Run_Checked;

begin
   for Model of Models loop
      Run_Checked (Run_Lifecycle'Access, Model);
      Run_Checked (Run_Invalid_Results'Access, Model);
      Run_Checked (Run_Immediate_Timeout'Access, Model);
      Run_Checked (Run_Pre_Cancelled'Access, Model);
      Run_Checked (Run_Requested_Cancellation'Access, Model);
      Run_Checked (Run_Queued_Serialization'Access, Model);
   end loop;
end TLS_State_Model;
