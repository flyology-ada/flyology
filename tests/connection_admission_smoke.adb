with Flyology;
with Flyology.IO;
with Flyology.IO.Connections;
with Flyology.IO.Connections.Testing;
with Flyology.IO.Sockets;

procedure Connection_Admission_Smoke is
   package Connections renames Flyology.IO.Connections;
   package Sockets renames Flyology.IO.Sockets;
   package Testing renames Flyology.IO.Connections.Testing;

   type Admission_Result is
     (Pending, Accepted, Timed_Out, Cancelled, Closed, Failed);

   protected type Result_Box is
      procedure Set (Value : Admission_Result);
      entry Wait (Value : out Admission_Result);
   private
      Stored : Admission_Result := Pending;
   end Result_Box;

   protected body Result_Box is
      procedure Set (Value : Admission_Result) is
      begin
         Stored := Value;
      end Set;

      entry Wait (Value : out Admission_Result) when Stored /= Pending is
      begin
         Value := Stored;
      end Wait;
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

   procedure Open_Listener
     (Listener : in out Sockets.Socket_Type;
      Address  : out Sockets.Endpoint)
   is
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint
           (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener, Length => 8);
      Address := Sockets.Get_Socket_Name (Listener);
   end Open_Listener;

   procedure Await_Result
     (Box      : in out Result_Box;
      Expected : Admission_Result;
      Label    : String)
   is
      Actual : Admission_Result;
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

   type Wait_Trigger is (Deadline, Token_Request, Manager_Shutdown, Permit);

   procedure Run_Full_Capacity
     (Model   : Flyology.Execution_Model;
      Trigger : Wait_Trigger)
   is
      Manager : aliased Connections.Server (Capacity => 1);
      Token   : aliased Connections.Cancellation_Token;
      Held    : Connections.Connection;
      Held_Socket, Held_Peer : Sockets.Socket_Type;
      Listener, Client : Sockets.Socket_Type;
      Listener_Address : Sockets.Endpoint;
      Result : Result_Box;
      Expected : constant Admission_Result :=
        (case Trigger is
            when Deadline         => Timed_Out,
            when Token_Request    => Cancelled,
            when Manager_Shutdown => Closed,
            when Permit           => Accepted);
   begin
      Sockets.Create_Socket_Pair (Held_Socket, Held_Peer);
      Connections.Take (Manager, Held_Socket, Held);
      Open_Listener (Listener, Listener_Address);
      if Trigger = Permit then
         Sockets.Create_Socket (Client);
         Sockets.Connect_Socket (Client, Listener_Address);
      end if;

      Testing.Reset_Barriers;
      Testing.Arm (Testing.Admission_Wait_Armed);
      declare
         task Acceptor is
            pragma Task_Info (Model);
         end Acceptor;

         task body Acceptor is
            Item : Connections.Connection;
            Peer : Sockets.Endpoint;
         begin
            begin
               Connections.Accept_Connection
                 (Manager,
                  Listener,
                  Item,
                  Peer,
                  Timeout => (if Trigger = Deadline then 0.050 else -1.0),
                  Token   => Token'Access);
               Result.Set (Accepted);
            exception
               when Flyology.IO.Timeout_Error =>
                  Result.Set (Timed_Out);
               when Connections.Operation_Cancelled =>
                  Result.Set (Cancelled);
               when Connections.Admission_Closed =>
                  Result.Set (Closed);
               when others =>
                  Result.Set (Failed);
            end;
         end Acceptor;
      begin
         Testing.Wait_Reached (Testing.Admission_Wait_Armed);
         if Manager.Active /= 1 then
            raise Program_Error with
              "full-capacity admission changed permit ownership";
         end if;

         case Trigger is
            when Deadline =>
               Testing.Release (Testing.Admission_Wait_Armed);
            when Token_Request =>
               Token.Request;
               Testing.Release (Testing.Admission_Wait_Armed);
            when Manager_Shutdown =>
               Manager.Request_Shutdown;
               Testing.Release (Testing.Admission_Wait_Armed);
            when Permit =>
               Held.Close;
               Testing.Release (Testing.Admission_Wait_Armed);
         end case;
         Await_Result
           (Result, Expected,
            "full-capacity " & Trigger'Image & "/" & Model'Image);
      exception
         when others =>
            Testing.Release (Testing.Admission_Wait_Armed);
            Token.Request;
            raise;
      end;

      Held.Close;
      if Trigger = Manager_Shutdown then
         Manager.Await_Drained;
      end if;
      if Manager.Active /= 0 then
         raise Program_Error with
           "full-capacity path leaked an admission permit";
      end if;
      Close_If_Open (Client);
      Close_If_Open (Listener);
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
         Close_If_Open (Client);
         Close_If_Open (Listener);
         Close_If_Open (Held_Socket);
         Close_If_Open (Held_Peer);
         raise;
   end Run_Full_Capacity;

   procedure Run_Acquired_Boundary
     (Model   : Flyology.Execution_Model;
      Trigger : Wait_Trigger)
   is
      Manager : aliased Connections.Server (Capacity => 1);
      Token   : aliased Connections.Cancellation_Token;
      Listener : Sockets.Socket_Type;
      Listener_Address : Sockets.Endpoint;
      Result : Result_Box;
      Expected : constant Admission_Result :=
        (case Trigger is
            when Deadline         => Timed_Out,
            when Token_Request    => Cancelled,
            when Manager_Shutdown => Cancelled,
            when Permit           => Failed);
   begin
      if Trigger = Permit then
         raise Program_Error with "invalid acquired-boundary trigger";
      end if;
      Open_Listener (Listener, Listener_Address);
      Testing.Reset_Barriers;
      Testing.Arm (Testing.Admission_Acquired);
      declare
         task Acceptor is
            pragma Task_Info (Model);
         end Acceptor;

         task body Acceptor is
            Item : Connections.Connection;
            Peer : Sockets.Endpoint;
         begin
            begin
               Connections.Accept_Connection
                 (Manager,
                  Listener,
                  Item,
                  Peer,
                  Timeout => (if Trigger = Deadline then 0.050 else -1.0),
                  Token   => Token'Access);
               Result.Set (Accepted);
            exception
               when Flyology.IO.Timeout_Error =>
                  Result.Set (Timed_Out);
               when Connections.Operation_Cancelled =>
                  Result.Set (Cancelled);
               when Connections.Admission_Closed =>
                  Result.Set (Closed);
               when others =>
                  Result.Set (Failed);
            end;
         end Acceptor;
      begin
         Testing.Wait_Reached (Testing.Admission_Acquired);
         if Manager.Active /= 1 then
            raise Program_Error with
              "acquired-boundary test did not own one permit";
         end if;
         case Trigger is
            when Deadline =>
               delay 0.075;
            when Token_Request =>
               Token.Request;
            when Manager_Shutdown =>
               Manager.Request_Shutdown;
            when Permit =>
               null;
         end case;
         Testing.Release (Testing.Admission_Acquired);
         Await_Result
           (Result, Expected,
            "acquired boundary " & Trigger'Image & "/" & Model'Image);
      exception
         when others =>
            Testing.Release (Testing.Admission_Acquired);
            Token.Request;
            raise;
      end;

      if Trigger = Manager_Shutdown then
         Manager.Await_Drained;
      end if;
      if Manager.Active /= 0 then
         raise Program_Error with
           "acquired-boundary path leaked an admission permit";
      end if;
      Close_If_Open (Listener);
      Testing.Reset_Barriers;
   exception
      when others =>
         Testing.Release (Testing.Admission_Acquired);
         Close_If_Open (Listener);
         raise;
   end Run_Acquired_Boundary;

   procedure Run (Model : Flyology.Execution_Model) is
   begin
      for Trigger in Wait_Trigger loop
         Run_Full_Capacity (Model, Trigger);
      end loop;
      for Trigger in Wait_Trigger range Deadline .. Manager_Shutdown loop
         Run_Acquired_Boundary (Model, Trigger);
      end loop;
   end Run;

begin
   Run (Flyology.Lightweight_Task);
   Run (Flyology.Native_Task);
end Connection_Admission_Smoke;
