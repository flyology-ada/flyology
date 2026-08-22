with Flyology;
with Flyology.Capacity;
with Flyology.IO;
with Flyology.IO.Connections;
with Flyology.IO.Connections.Testing;
with Flyology.IO.Sockets;
with Interfaces.C;

procedure Connection_Admission_Smoke is
   package Connections renames Flyology.IO.Connections;
   package Sockets renames Flyology.IO.Sockets;
   package Testing renames Flyology.IO.Connections.Testing;

   use type Flyology.Capacity.Acquire_Result;
   use type Interfaces.C.int;

   function Open_FD_Count return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_open_fd_count";

   type Admission_Result is (Pending, Accepted, Timed_Out, Cancelled, Closed, Failed);

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

   procedure Open_Listener (Listener : in out Sockets.Socket_Type; Address : out Sockets.Endpoint) is
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Bind_Socket (Listener, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener, Length => 8);
      Address := Sockets.Get_Socket_Name (Listener);
   end Open_Listener;

   procedure Await_Result (Box : in out Result_Box; Expected : Admission_Result; Label : String) is
      Actual : Admission_Result;
   begin
      select
         Box.Wait (Actual);
      or
         delay 2.0;
         raise Program_Error with Label & " did not finish";
      end select;
      if Actual /= Expected then
         raise Program_Error with Label & " returned " & Actual'Image & " instead of " & Expected'Image;
      end if;
   end Await_Result;

   type Wait_Trigger is (Deadline, Token_Request, Manager_Shutdown, Permit);

   procedure Run_Full_Capacity (Model : Flyology.Execution_Model; Trigger : Wait_Trigger) is
      Manager                : aliased Connections.Server (Capacity => 1);
      Token                  : aliased Connections.Cancellation_Token;
      Held                   : Connections.Connection;
      Held_Socket, Held_Peer : Sockets.Socket_Type;
      Listener, Client       : Sockets.Socket_Type;
      Listener_Address       : Sockets.Endpoint;
      Result                 : Result_Box;
      Expected               : constant Admission_Result :=
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
            raise Program_Error with "full-capacity admission changed permit ownership";
         end if;

         case Trigger is
            when Deadline         =>
               Testing.Release (Testing.Admission_Wait_Armed);

            when Token_Request    =>
               Token.Request;
               Testing.Release (Testing.Admission_Wait_Armed);

            when Manager_Shutdown =>
               Manager.Request_Shutdown;
               Testing.Release (Testing.Admission_Wait_Armed);

            when Permit           =>
               Held.Close;
               Testing.Release (Testing.Admission_Wait_Armed);
         end case;
         Await_Result (Result, Expected, "full-capacity " & Trigger'Image & "/" & Model'Image);
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
         raise Program_Error with "full-capacity path leaked an admission permit";
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

   procedure Run_Acquired_Boundary (Model : Flyology.Execution_Model; Trigger : Wait_Trigger) is
      Manager          : aliased Connections.Server (Capacity => 1);
      Token            : aliased Connections.Cancellation_Token;
      Listener         : Sockets.Socket_Type;
      Listener_Address : Sockets.Endpoint;
      Result           : Result_Box;
      Expected         : constant Admission_Result :=
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
            raise Program_Error with "acquired-boundary test did not own one permit";
         end if;
         case Trigger is
            when Deadline         =>
               delay 0.075;

            when Token_Request    =>
               Token.Request;

            when Manager_Shutdown =>
               Manager.Request_Shutdown;

            when Permit           =>
               null;
         end case;
         Testing.Release (Testing.Admission_Acquired);
         Await_Result (Result, Expected, "acquired boundary " & Trigger'Image & "/" & Model'Image);
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
         raise Program_Error with "acquired-boundary path leaked an admission permit";
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

   type Abort_Path is (Accept_Path, Take_Path);
   type Abort_Boundary is (Permit_Boundary, Adopt_Boundary);

   procedure Run_Abort_Boundary
     (Model : Flyology.Execution_Model; Path : Abort_Path; Boundary : Abort_Boundary; Shutdown : Boolean)
   is
      Before : constant Interfaces.C.int := Open_FD_Count;
   begin
      declare
         Manager           : aliased Connections.Server (Capacity => 1);
         Listener, Client  : Sockets.Socket_Type;
         Listener_Address  : Sockets.Endpoint;
         Taken, Taken_Peer : Sockets.Socket_Type;
         Point             : constant Testing.Barrier_Point :=
           (case Path is
              when Accept_Path =>
                (if Boundary = Permit_Boundary then Testing.Admission_Acquired else Testing.Accept_Adopted),
              when Take_Path   =>
                (if Boundary = Permit_Boundary
                 then Testing.Take_Admission_Acquired
                 else Testing.Take_Adopted));
      begin
         if Path = Accept_Path then
            Open_Listener (Listener, Listener_Address);
            if Boundary = Adopt_Boundary then
               Sockets.Create_Socket (Client);
               Sockets.Connect_Socket (Client, Listener_Address);
            end if;
         else
            Sockets.Create_Socket_Pair (Taken, Taken_Peer);
         end if;

         Testing.Reset_Barriers;
         Testing.Arm (Point);
         declare
            task Worker is
               pragma Task_Info (Model);
            end Worker;

            task body Worker is
               Item : Connections.Connection;
               Peer : Sockets.Endpoint;
            begin
               if Path = Accept_Path then
                  Connections.Accept_Connection (Manager, Listener, Item, Peer, Token => null);
               else
                  Connections.Take (Manager, Taken, Item);
               end if;
            end Worker;
         begin
            Testing.Wait_Reached (Point);
            if Manager.Active /= 1 then
               raise Program_Error with "abort seam did not hold exactly one permit";
            end if;
            if Shutdown then
               Manager.Request_Shutdown;
            end if;
            abort Worker;
            Testing.Release (Point);
         exception
            when others =>
               Testing.Release (Point);
               abort Worker;
               raise;
         end;

         if Shutdown then
            Manager.Await_Drained;
         end if;
         if Manager.Active /= 0 then
            raise Program_Error with "abort seam leaked a permit";
         end if;
         if not Shutdown then
            declare
               Result : Flyology.Capacity.Acquire_Result;
            begin
               Manager.Try_Acquire (Result);
               if Result /= Flyology.Capacity.Permit_Acquired then
                  raise Program_Error with "abort seam did not restore admission capacity";
               end if;
               Manager.Release;
            end;
         end if;

         Close_If_Open (Taken);
         Close_If_Open (Taken_Peer);
         Close_If_Open (Client);
         Close_If_Open (Listener);
         Testing.Reset_Barriers;
      exception
         when others =>
            Testing.Release (Point);
            Close_If_Open (Taken);
            Close_If_Open (Taken_Peer);
            Close_If_Open (Client);
            Close_If_Open (Listener);
            raise;
      end;
      if Open_FD_Count /= Before then
         raise Program_Error
           with "abort seam leaked a descriptor on " & Path'Image & "/" & Boundary'Image & "/" & Model'Image;
      end if;
   end Run_Abort_Boundary;

   procedure Run_Abort_Boundaries (Model : Flyology.Execution_Model) is
   begin
      for Path in Abort_Path loop
         for Boundary in Abort_Boundary loop
            Run_Abort_Boundary (Model, Path, Boundary, Shutdown => False);
            Run_Abort_Boundary (Model, Path, Boundary, Shutdown => True);
         end loop;
      end loop;
   end Run_Abort_Boundaries;

   procedure Run_Raw_Accept_Abort (Model : Flyology.Execution_Model) is
      Before : constant Interfaces.C.int := Open_FD_Count;
      Point  : constant Testing.Barrier_Point := Testing.Raw_Accept_Returned;
   begin
      declare
         Manager          : aliased Connections.Server (Capacity => 1);
         Listener, Client : Sockets.Socket_Type;
         Listener_Address : Sockets.Endpoint;
      begin
         Open_Listener (Listener, Listener_Address);
         Sockets.Create_Socket (Client);
         Sockets.Connect_Socket (Client, Listener_Address);
         Testing.Reset_Barriers;
         Testing.Arm (Point);
         declare
            task Worker is
               pragma Task_Info (Model);
            end Worker;

            task body Worker is
               Item : Connections.Connection;
               Peer : Sockets.Endpoint;
            begin
               Connections.Accept_Connection (Manager, Listener, Item, Peer, Token => null);
            end Worker;
         begin
            Testing.Wait_Reached (Point);
            if Manager.Active /= 1 then
               raise Program_Error with "raw accept boundary did not hold one permit";
            end if;
            abort Worker;
            Testing.Release (Point);
         exception
            when others =>
               Testing.Release (Point);
               abort Worker;
               raise;
         end;

         if Manager.Active /= 0 then
            raise Program_Error with "raw accept boundary leaked an admission permit";
         end if;
         declare
            Result : Flyology.Capacity.Acquire_Result;
         begin
            Manager.Try_Acquire (Result);
            pragma Assert (Result = Flyology.Capacity.Permit_Acquired);
            Manager.Release;
         end;
         Close_If_Open (Client);
         Close_If_Open (Listener);
         Testing.Reset_Barriers;
      exception
         when others =>
            Testing.Release (Point);
            Close_If_Open (Client);
            Close_If_Open (Listener);
            raise;
      end;
      if Open_FD_Count /= Before then
         raise Program_Error with "raw accept boundary leaked a descriptor in " & Model'Image;
      end if;
   end Run_Raw_Accept_Abort;

   procedure Run_Release_Wake_Failure (Model : Flyology.Execution_Model) is
      Before : constant Interfaces.C.int := Open_FD_Count;
      Point  : constant Testing.Barrier_Point := Testing.Accept_Socket_Owned;
   begin
      declare
         Manager          : aliased Connections.Server (Capacity => 1);
         Listener, Client : Sockets.Socket_Type;
         Listener_Address : Sockets.Endpoint;
      begin
         Open_Listener (Listener, Listener_Address);
         Sockets.Create_Socket (Client);
         Sockets.Connect_Socket (Client, Listener_Address);
         Testing.Reset_Barriers;
         Testing.Arm (Point);
         declare
            task Worker is
               pragma Task_Info (Model);
            end Worker;

            task body Worker is
               Item : Connections.Connection;
               Peer : Sockets.Endpoint;
            begin
               Connections.Accept_Connection (Manager, Listener, Item, Peer, Token => null);
            end Worker;
         begin
            Testing.Wait_Reached (Point);
            declare
               FD          : Interfaces.C.int;
               Can_Acquire : Boolean;
            begin
               Manager.Acquire_Wait_Source (FD, Can_Acquire);
               pragma Assert (FD >= 0 and then not Can_Acquire);
            end;
            Testing.Fail_Next_Release_Wake;
            abort Worker;
            Testing.Release (Point);
         exception
            when others =>
               Testing.Release (Point);
               abort Worker;
               raise;
         end;

         if Manager.Active /= 0 then
            raise Program_Error with "release-wake failure leaked an admission permit";
         end if;
         declare
            Result : Flyology.Capacity.Acquire_Result;
         begin
            Manager.Try_Acquire (Result);
            pragma Assert (Result = Flyology.Capacity.Permit_Acquired);
            Manager.Release;
         end;
         Close_If_Open (Client);
         Close_If_Open (Listener);
         Testing.Reset_Barriers;
      exception
         when others =>
            Testing.Release (Point);
            Close_If_Open (Client);
            Close_If_Open (Listener);
            raise;
      end;
      if Open_FD_Count /= Before then
         raise Program_Error with "release-wake failure skipped accepted socket close in " & Model'Image;
      end if;
   end Run_Release_Wake_Failure;

begin
   Run (Flyology.Lightweight_Task);
   Run (Flyology.Native_Task);
   Run_Abort_Boundaries (Flyology.Lightweight_Task);
   Run_Abort_Boundaries (Flyology.Native_Task);
   Run_Raw_Accept_Abort (Flyology.Lightweight_Task);
   Run_Raw_Accept_Abort (Flyology.Native_Task);
   Run_Release_Wake_Failure (Flyology.Lightweight_Task);
   Run_Release_Wake_Failure (Flyology.Native_Task);
end Connection_Admission_Smoke;
