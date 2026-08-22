with Ada.Streams;
with Flyology;
with Flyology.IO;
with Flyology.IO.Connections;
with Flyology.IO.Connections.Drivers;
with Flyology.IO.Connections.Testing;
with Flyology.IO.Connections.TLS;
with Flyology.IO.Sockets;
with Flyology.IO.TLS;
with TLS_Test_Provider;

procedure Managed_Connection_Connect_Smoke is
   package Connections renames Flyology.IO.Connections;
   package Drivers renames Flyology.IO.Connections.Drivers;
   package Sockets renames Flyology.IO.Sockets;
   package Testing renames Flyology.IO.Connections.Testing;
   package Connection_TLS renames Flyology.IO.Connections.TLS;
   package TLS renames Flyology.IO.TLS;
   package Provider renames TLS_Test_Provider;

   use Ada.Streams;
   use type Drivers.Step_Result;
   use type Drivers.Wait_Result;

   type Test_Result is
     (Pending,
      Succeeded,
      Timed_Out,
      Cancelled,
      Admission_Stopped,
      Transfer_Rejected,
      Failed);

   protected type Result_Box is
      procedure Set (Value : Test_Result);
      entry Wait (Value : out Test_Result);
   private
      Stored : Test_Result := Pending;
   end Result_Box;

   protected body Result_Box is
      procedure Set (Value : Test_Result) is
      begin
         Stored := Value;
      end Set;

      entry Wait (Value : out Test_Result) when Stored /= Pending is
      begin
         Value := Stored;
      end Wait;
   end Result_Box;

   procedure Await_Result
     (Box      : in out Result_Box;
      Expected : Test_Result;
      Label    : String)
   is
      Actual : Test_Result;
   begin
      select
         Box.Wait (Actual);
      or
         delay 2.0;
         raise Program_Error with Label & " did not finish";
      end select;
      if Actual /= Expected then
         raise Program_Error with
           Label & " returned " & Actual'Image & " instead of "
           & Expected'Image;
      end if;
   end Await_Result;

   procedure Close_If_Open (Socket : in out Sockets.Socket_Type) is
   begin
      if Sockets.Is_Open (Socket) then
         Sockets.Close_Socket (Socket);
      end if;
   exception
      when others =>
         null;
   end Close_If_Open;

   procedure Open_Listener
     (Listener : in out Sockets.Socket_Type;
      Address  : out Sockets.Endpoint) is
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint
           (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener, Length => 4);
      Address := Sockets.Get_Socket_Name (Listener);
   end Open_Listener;

   procedure Run_Composition
     (Model  : Flyology.Execution_Model;
      Secure : Boolean)
   is
      Manager : aliased Connections.Server (Capacity => 1);
      Listener : Sockets.Socket_Type;
      Address  : Sockets.Endpoint;
      Backend  : Provider.Provider;
      Client_Result : Result_Box;
      Server_Result : Result_Box;
      State : Provider.State_Telemetry;
   begin
      Open_Listener (Listener, Address);
      if Secure then
         Provider.Reset_State_Telemetry;
         Provider.Set_Script
           (Backend, Provider.Handshake_Operation,
            [1 => (TLS.Complete, Provider.Preserve_Output, 0)]);
      end if;

      declare
         task Server is
            pragma Task_Info (Model);
         end Server;

         task Client is
            pragma Task_Info (Model);
         end Client;

         task body Server is
            Peer     : Sockets.Socket_Type;
            Remote   : Sockets.Endpoint;
            Data     : Stream_Element_Array (1 .. 1);
            Last     : Stream_Element_Offset;
         begin
            begin
               Sockets.Accept_Connection
                 (Listener, Peer, Remote, Timeout => 1.0);
               if Secure then
                  Sockets.Receive (Peer, Data, Last, Timeout => 1.0);
                  if Last >= Data'First then
                     raise Program_Error with
                       "TLS composition peer did not observe scope close";
                  end if;
               else
                  Sockets.Receive_Exactly (Peer, Data, Timeout => 1.0);
                  if Data /= [1 => 41] then
                     raise Program_Error with
                       "managed connection driver received wrong request";
                  end if;
                  Sockets.Send_All (Peer, [1 => 42], Timeout => 1.0);
                  Sockets.Receive (Peer, Data, Last, Timeout => 1.0);
                  if Last >= Data'First then
                     raise Program_Error with
                       "managed connection peer did not observe scope close";
                  end if;
               end if;
               Close_If_Open (Peer);
               Server_Result.Set (Succeeded);
            exception
               when others =>
                  Close_If_Open (Peer);
                  Server_Result.Set (Failed);
            end;
         end Server;

         task body Client is
         begin
            begin
               declare
                  Item   : aliased Connections.Connection (Manager'Access);
                  Wakeup : Drivers.Outbound_Wakeup;

                  procedure Wait_For
                    (IO       : in out Drivers.Capability;
                     Required : Drivers.Step_Result)
                  is
                     Ready : Drivers.Wait_Result;
                  begin
                     Drivers.Wait
                       (IO,
                        Wakeup,
                        (if Required = Drivers.Need_Read
                         then Drivers.Read_Interest
                         else Drivers.Write_Interest),
                        Timeout => 1.0,
                        Result  => Ready);
                     if Ready /= Drivers.Transport_Ready then
                        raise Program_Error with
                          "managed connection driver woke for wrong source";
                     end if;
                  end Wait_For;

                  procedure Pump (IO : in out Drivers.Capability) is
                     Data : Stream_Element_Array (1 .. 1);
                     Last : Stream_Element_Offset;
                     Step : Drivers.Step_Result;
                  begin
                     if Secure then
                        if not Drivers.Is_Acquired (IO) then
                           raise Program_Error with
                             "TLS connection capability did not acquire";
                        end if;
                        return;
                     end if;

                     loop
                        Drivers.Send (IO, [1 => 41], Last, Step);
                        exit when Step = Drivers.Made_Progress;
                        if Step not in Drivers.Need_Read | Drivers.Need_Write
                        then
                           raise Program_Error with
                             "managed connection driver send failed";
                        end if;
                        Wait_For (IO, Step);
                     end loop;
                     if Last /= 1 then
                        raise Program_Error with
                          "managed connection driver sent wrong length";
                     end if;

                     loop
                        Drivers.Receive (IO, Data, Last, Step);
                        exit when Step = Drivers.Made_Progress;
                        if Step not in Drivers.Need_Read | Drivers.Need_Write
                        then
                           raise Program_Error with
                             "managed connection driver receive failed";
                        end if;
                        Wait_For (IO, Step);
                     end loop;
                     if Last /= Data'Last or else Data /= [1 => 42] then
                        raise Program_Error with
                          "managed connection driver received wrong reply";
                     end if;
                  end Pump;
               begin
                  Connections.Connect
                    (Manager, Address, Item, Timeout => 1.0);
                  if not Connections.Is_Open (Item)
                    or else Manager.Active /= 1
                  then
                     raise Program_Error with
                       "managed connect did not publish sole ownership";
                  end if;
                  if Secure then
                     Connection_TLS.Upgrade
                       (Item,
                        Backend,
                        TLS.Client,
                        "localhost",
                        Timeout => 1.0);
                  end if;
                  Drivers.Run (Item, Pump'Access, Timeout => 1.0);
               end;
               if Manager.Active /= 0 then
                  raise Program_Error with
                    "connection scope exit did not release admission";
               end if;
               Client_Result.Set (Succeeded);
            exception
               when others =>
                  Client_Result.Set (Failed);
            end;
         end Client;
      begin
         Await_Result
           (Client_Result,
            Succeeded,
            "managed composition client/" & Model'Image);
         Await_Result
           (Server_Result,
            Succeeded,
            "managed composition server/" & Model'Image);
      end;

      if Manager.Active /= 0 then
         raise Program_Error with "managed composition leaked admission";
      end if;
      if Secure then
         Provider.Get_State_Telemetry (State);
         if State.Sessions_Created /= 1
           or else State.Sessions_Finalized /= 1
           or else State.Sessions_Live /= 0
         then
            raise Program_Error with
              "managed TLS composition leaked provider state";
         end if;
      end if;
      Close_If_Open (Listener);
   exception
      when others =>
         Close_If_Open (Listener);
         raise;
   end Run_Composition;

   type Admission_Trigger is
     (Deadline, Token_Request, Manager_Shutdown);

   procedure Run_Admission_Wait
     (Model   : Flyology.Execution_Model;
      Trigger : Admission_Trigger)
   is
      Manager : aliased Connections.Server (Capacity => 1);
      Token   : aliased Connections.Cancellation_Token;
      Held    : Connections.Connection (Manager'Access);
      Held_Socket, Held_Peer : Sockets.Socket_Type;
      Result  : Result_Box;
      Address : constant Sockets.Endpoint :=
        Sockets.Network_Endpoint (Sockets.Loopback_IPv4, 1);
      Expected : constant Test_Result :=
        (case Trigger is
            when Deadline         => Timed_Out,
            when Token_Request    => Cancelled,
            when Manager_Shutdown => Admission_Stopped);
   begin
      Sockets.Create_Socket_Pair (Held_Socket, Held_Peer);
      Connections.Take (Manager, Held_Socket, Held);
      Testing.Reset_Barriers;
      Testing.Arm (Testing.Admission_Wait_Armed);

      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
            Item : Connections.Connection (Manager'Access);
         begin
            begin
               Connections.Connect
                 (Manager,
                  Address,
                  Item,
                  Timeout => (if Trigger = Deadline then 0.050 else -1.0),
                  Token   => Token'Access);
               Result.Set (Succeeded);
            exception
               when Flyology.IO.Timeout_Error =>
                  Result.Set (Timed_Out);
               when Connections.Operation_Cancelled =>
                  Result.Set (Cancelled);
               when Connections.Admission_Closed =>
                  Result.Set (Admission_Stopped);
               when others =>
                  Result.Set (Failed);
            end;
         end Worker;
      begin
         Testing.Wait_Reached (Testing.Admission_Wait_Armed);
         case Trigger is
            when Deadline =>
               delay 0.075;
            when Token_Request =>
               Token.Request;
            when Manager_Shutdown =>
               Manager.Request_Shutdown;
         end case;
         Testing.Release (Testing.Admission_Wait_Armed);
         Await_Result
           (Result,
            Expected,
            "managed admission " & Trigger'Image & "/" & Model'Image);
      exception
         when others =>
            Token.Request;
            Testing.Release (Testing.Admission_Wait_Armed);
            raise;
      end;

      Connections.Close (Held);
      if Trigger = Manager_Shutdown then
         Manager.Await_Drained;
      end if;
      if Manager.Active /= 0 then
         raise Program_Error with "managed admission wait leaked a permit";
      end if;
      Close_If_Open (Held_Peer);
      Testing.Reset_Barriers;
   exception
      when others =>
         Testing.Release (Testing.Admission_Wait_Armed);
         begin
            Connections.Close (Held);
         exception
            when others =>
               null;
         end;
         Close_If_Open (Held_Socket);
         Close_If_Open (Held_Peer);
         raise;
   end Run_Admission_Wait;

   type Connected_Trigger is (Token_Request, Manager_Shutdown);

   procedure Run_Connected_Interruption
     (Model   : Flyology.Execution_Model;
      Trigger : Connected_Trigger)
   is
      Manager  : aliased Connections.Server (Capacity => 1);
      Token    : aliased Connections.Cancellation_Token;
      Listener : Sockets.Socket_Type;
      Address  : Sockets.Endpoint;
      Client_Result : Result_Box;
      Server_Result : Result_Box;
   begin
      Open_Listener (Listener, Address);
      Testing.Reset_Barriers;
      Testing.Arm (Testing.Managed_Connect_Connected);

      declare
         task Server is
            pragma Task_Info (Model);
         end Server;

         task Client is
            pragma Task_Info (Model);
         end Client;

         task body Server is
            Peer   : Sockets.Socket_Type;
            Remote : Sockets.Endpoint;
            Data   : Stream_Element_Array (1 .. 1);
            Last   : Stream_Element_Offset;
         begin
            begin
               Sockets.Accept_Connection
                 (Listener, Peer, Remote, Timeout => 1.0);
               Sockets.Receive (Peer, Data, Last, Timeout => 1.0);
               Close_If_Open (Peer);
               Server_Result.Set
                 (if Last < Data'First then Succeeded else Failed);
            exception
               when others =>
                  Close_If_Open (Peer);
                  Server_Result.Set (Failed);
            end;
         end Server;

         task body Client is
            Item : Connections.Connection (Manager'Access);
         begin
            begin
               Connections.Connect
                 (Manager,
                  Address,
                  Item,
                  Timeout => 1.0,
                  Token   => Token'Access);
               Client_Result.Set (Succeeded);
            exception
               when Connections.Operation_Cancelled =>
                  Client_Result.Set (Cancelled);
               when others =>
                  Client_Result.Set (Failed);
            end;
         end Client;
      begin
         Testing.Wait_Reached (Testing.Managed_Connect_Connected);
         if Manager.Active /= 1 then
            raise Program_Error with
              "connected interruption did not retain admission";
         end if;
         case Trigger is
            when Token_Request =>
               Token.Request;
            when Manager_Shutdown =>
               Manager.Request_Shutdown;
         end case;
         Testing.Release (Testing.Managed_Connect_Connected);
         Await_Result
           (Client_Result,
            Cancelled,
            "managed connected interruption/" & Trigger'Image & "/"
            & Model'Image);
         Await_Result
           (Server_Result,
            Succeeded,
            "managed connected cleanup/" & Trigger'Image & "/"
            & Model'Image);
      exception
         when others =>
            Token.Request;
            Testing.Release (Testing.Managed_Connect_Connected);
            raise;
      end;

      if Trigger = Manager_Shutdown then
         Manager.Await_Drained;
      end if;
      if Manager.Active /= 0 then
         raise Program_Error with
           "connected interruption leaked admission";
      end if;
      Close_If_Open (Listener);
      Testing.Reset_Barriers;
   exception
      when others =>
         Testing.Release (Testing.Managed_Connect_Connected);
         Close_If_Open (Listener);
         raise;
   end Run_Connected_Interruption;

   procedure Run_Transfer_Failure (Model : Flyology.Execution_Model) is
      Manager  : aliased Connections.Server (Capacity => 2);
      Item     : Connections.Connection (Manager'Access);
      Listener : Sockets.Socket_Type;
      Address  : Sockets.Endpoint;
      Existing, Existing_Peer : Sockets.Socket_Type;
      Client_Result : Result_Box;
      Server_Result : Result_Box;
   begin
      Open_Listener (Listener, Address);
      Testing.Reset_Barriers;
      Testing.Arm (Testing.Managed_Connect_Connected);

      declare
         task Server is
            pragma Task_Info (Model);
         end Server;

         task Client is
            pragma Task_Info (Model);
         end Client;

         task body Server is
            Peer   : Sockets.Socket_Type;
            Remote : Sockets.Endpoint;
            Data   : Stream_Element_Array (1 .. 1);
            Last   : Stream_Element_Offset;
         begin
            begin
               Sockets.Accept_Connection
                 (Listener, Peer, Remote, Timeout => 1.0);
               Sockets.Receive (Peer, Data, Last, Timeout => 1.0);
               Close_If_Open (Peer);
               Server_Result.Set
                 (if Last < Data'First then Succeeded else Failed);
            exception
               when others =>
                  Close_If_Open (Peer);
                  Server_Result.Set (Failed);
            end;
         end Server;

         task body Client is
         begin
            begin
               Connections.Connect
                 (Manager, Address, Item, Timeout => 1.0);
               Client_Result.Set (Succeeded);
            exception
               when Program_Error =>
                  Client_Result.Set (Transfer_Rejected);
               when others =>
                  Client_Result.Set (Failed);
            end;
         end Client;
      begin
         Testing.Wait_Reached (Testing.Managed_Connect_Connected);
         Sockets.Create_Socket_Pair (Existing, Existing_Peer);
         Connections.Take (Manager, Existing, Item);
         if Manager.Active /= 2 or else not Connections.Is_Open (Item) then
            raise Program_Error with
              "transfer failure setup did not own both permits";
         end if;
         Testing.Release (Testing.Managed_Connect_Connected);
         Await_Result
           (Client_Result,
            Transfer_Rejected,
            "managed transfer failure/" & Model'Image);
         Await_Result
           (Server_Result,
            Succeeded,
            "managed transfer cleanup/" & Model'Image);
      exception
         when others =>
            Testing.Release (Testing.Managed_Connect_Connected);
            raise;
      end;

      if Manager.Active /= 1 or else not Connections.Is_Open (Item) then
         raise Program_Error with
           "failed transfer disturbed the existing connection";
      end if;
      Connections.Close (Item);
      Close_If_Open (Existing_Peer);
      Close_If_Open (Listener);
      Testing.Reset_Barriers;
      if Manager.Active /= 0 then
         raise Program_Error with
           "managed transfer failure leaked ownership";
      end if;
   exception
      when others =>
         Testing.Release (Testing.Managed_Connect_Connected);
         begin
            Connections.Close (Item);
         exception
            when others =>
               null;
         end;
         Close_If_Open (Existing);
         Close_If_Open (Existing_Peer);
         Close_If_Open (Listener);
         raise;
   end Run_Transfer_Failure;

begin
   for Model in Flyology.Execution_Model loop
      Run_Composition (Model, Secure => False);
      Run_Composition (Model, Secure => True);
      for Trigger in Admission_Trigger loop
         Run_Admission_Wait (Model, Trigger);
      end loop;
      for Trigger in Connected_Trigger loop
         Run_Connected_Interruption (Model, Trigger);
      end loop;
      Run_Transfer_Failure (Model);
   end loop;
end Managed_Connection_Connect_Smoke;
