with Ada.Real_Time;
with Flyology.Connection_Policy;
with Flyology.IO.Sockets;
with Flyology.Time_Math;
with Interfaces.C;

package body Flyology.IO.Connections is
   package Policy renames Flyology.Connection_Policy;
   package Sockets renames GNAT.Sockets;

   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.C.int;
   use type Sockets.Socket_Type;

   type Operation_Guard (Item : not null access Connection) is
     new Ada.Finalization.Limited_Controlled with record
      Generation : aliased Descriptor_Generation := 0;
      State      : aliased Operation_State := Unregistered;
   end record;

   overriding procedure Finalize (Guard : in out Operation_Guard);

#if FLYOLOGY_CONNECTION_TEST_HOOKS then
   function Test_Barrier_Arrive
     (Point : Interfaces.C.int) return Interfaces.C.int
     with Import,
          Convention => C,
          External_Name => "flyology_test_connection_barrier_arrive";
   function Test_Barrier_Released
     (Point : Interfaces.C.int) return Interfaces.C.int
     with Import,
          Convention => C,
          External_Name => "flyology_test_connection_barrier_released";

   procedure Test_Barrier (Point : Interfaces.C.int) is
   begin
      if Test_Barrier_Arrive (Point) /= 0 then
         while Test_Barrier_Released (Point) = 0 loop
            delay 0.0;
         end loop;
      end if;
   end Test_Barrier;
#end if;

   protected body Descriptor_Controller is
      procedure Adopt
        (FD     : Descriptor;
         Socket : Sockets.Socket_Type;
         Owner  : Server_Access)
      is
      begin
         if FD < 0
           or else Socket = Sockets.No_Socket
           or else Flyology.IO.Sockets.Native_Descriptor (Socket) /= FD
           or else Owner = null
           or else Current_FD >= 0
           or else Active
           or else Closing
         then
            raise Program_Error with
              "descriptor controller already owns a resource";
         end if;
         Wake_Sources.Ensure (Lease_Wake);
         Wake_Sources.Ensure (Close_Wake);
         Current_Socket := Socket;
         Current_Owner := Owner;
         Current_FD := FD;
         Current_Generation := Current_Generation + 1;
      end Adopt;

      procedure Start_Operation
        (Generation   : not null access Descriptor_Generation;
         State        : not null access Operation_State;
         Lease_Source : out Descriptor;
         Close_Source : out Descriptor;
         Owner        : out Server_Access)
      is
      begin
         if State.all /= Unregistered then
            raise Program_Error with "connection operation already registered";
         end if;
         if Current_FD < 0
           or else Closing
           or else Current_Socket = Sockets.No_Socket
           or else Current_Owner = null
         then
            raise Program_Error with "connection is not open";
         elsif Started_Operations = Natural'Last then
            raise Program_Error with "too many connection operations";
         end if;
         Started_Operations :=
           Policy.Started_After_Register (Started_Operations);
         Generation.all := Current_Generation;
         Lease_Source := Wake_Sources.Descriptor (Lease_Wake);
         Close_Source := Wake_Sources.Descriptor (Close_Wake);
         Owner := Current_Owner;
         --  Publish the cleanup obligation before leaving the protected
         --  action. A pending abort can therefore only observe a state whose
         --  matching controller count already exists.
         State.all := Registered;
      end Start_Operation;

      procedure Try_Acquire
        (Expected_Generation : Descriptor_Generation;
         State        : not null access Operation_State;
         Result       : out Lease_Result;
         FD           : out Descriptor;
         Close_Source : out Descriptor;
         Socket       : out Sockets.Socket_Type;
         Owner        : out Server_Access)
      is
      begin
         if State.all /= Registered then
            raise Program_Error with "connection operation is not registered";
         end if;
         case Policy.Classify_Acquire
           (Generation_Matches => Expected_Generation = Current_Generation,
            Resources_Open     =>
              Current_FD >= 0
              and then Current_Socket /= Sockets.No_Socket
              and then Current_Owner /= null,
            Closing            => Closing,
            Active             => Active)
         is
            when Policy.Cancel_Lease =>
               if Started_Operations = 0 then
                  raise Program_Error with "missing connection operation";
               end if;
               Started_Operations :=
                 Policy.Started_After_Release (Started_Operations);
               State.all := Unregistered;
               Result := Lease_Cancelled;
               return;
            when Policy.Wait_For_Lease =>
               Result := Lease_Busy;
               return;
            when Policy.Acquire_Lease =>
               null;
         end case;
         if Lease_Signalled then
            Wake_Sources.Consume (Lease_Wake);
            Lease_Signalled := False;
         end if;
         Active := True;
         FD := Current_FD;
         Close_Source := Wake_Sources.Descriptor (Close_Wake);
         Socket := Current_Socket;
         Owner := Current_Owner;
         --  Active and the guard state become visible in one protected action.
         --  Finalization after any abort at the call boundary will Release.
         State.all := Acquired;
         Result := Lease_Acquired;
      end Try_Acquire;

      procedure Abandon_Operation (Generation : Descriptor_Generation) is
      begin
         if Generation /= Current_Generation or else Started_Operations = 0
         then
            raise Program_Error with "stale connection operation withdrawal";
         end if;
         Started_Operations :=
           Policy.Started_After_Release (Started_Operations);
         if Policy.Should_Wake_Next
           (Active, Closing, Started_Operations, Lease_Signalled)
         then
            Wake_Sources.Signal (Lease_Wake);
            Lease_Signalled := True;
         end if;
      end Abandon_Operation;

      procedure Check_Operation (Generation : Descriptor_Generation) is
      begin
         if not Active or else Generation /= Current_Generation then
            raise Program_Error with "stale descriptor operation";
         elsif Closing then
            raise Operation_Cancelled with
              "connection closed during its operation";
         end if;
      end Check_Operation;

      procedure Release (Generation : Descriptor_Generation) is
      begin
         if not Active
           or else Generation /= Current_Generation
           or else Started_Operations = 0
         then
            raise Program_Error with "stale descriptor operation release";
         end if;
         Active := False;
         Started_Operations :=
           Policy.Started_After_Release (Started_Operations);
         if Policy.Should_Wake_Next
           (Active, Closing, Started_Operations, Lease_Signalled)
         then
            Wake_Sources.Signal (Lease_Wake);
            Lease_Signalled := True;
         end if;
      end Release;

      procedure Begin_Close
        (FD         : out Descriptor;
         Generation : out Descriptor_Generation;
         Leader     : out Boolean)
      is
      begin
         FD := Current_FD;
         Generation := Current_Generation;
         Leader := Policy.Close_Leader (Current_FD >= 0, Closing);
         if Leader then
            Closing := True;
            if Policy.Close_Wake_Required (Leader, Started_Operations) then
               Wake_Sources.Signal (Close_Wake);
            end if;
         end if;
      end Begin_Close;

      entry Await_Drained
        (Socket : out Sockets.Socket_Type;
         Owner  : out Server_Access)
        when not Active and then Started_Operations = 0
      is
      begin
         if not Closing
           or else Current_FD < 0
           or else Current_Socket = Sockets.No_Socket
           or else Current_Owner = null
         then
            raise Program_Error with "invalid descriptor close handoff";
         end if;
         Socket := Current_Socket;
         Owner := Current_Owner;
         Current_Socket := Sockets.No_Socket;
         Current_Owner := null;
      end Await_Drained;

      entry Await_Closed when not Closing is
      begin
         null;
      end Await_Closed;

      procedure Finish_Close (Generation : Descriptor_Generation) is
      begin
         if not Policy.Finish_Close_Allowed
           (Closing,
            Active,
            Started_Operations,
            Generation = Current_Generation,
            Current_Socket = Sockets.No_Socket and then Current_Owner = null)
         then
            raise Program_Error with "stale descriptor close completion";
         end if;
         Current_FD := Invalid_Descriptor;
         Wake_Sources.Release (Lease_Wake);
         Wake_Sources.Release (Close_Wake);
         Lease_Signalled := False;
         Closing := False;
      end Finish_Close;

      function Is_Open_State return Boolean is
        (Policy.Is_Open (Current_FD >= 0, Closing));

#if FLYOLOGY_CONNECTION_TEST_HOOKS then
      function Test_Waiting_Operations return Natural is
        (Policy.Waiting_Operations (Started_Operations, Active));

      function Test_Operation_Active return Boolean is (Active);

      function Test_Close_Requested return Boolean is (Closing);
#end if;

   end Descriptor_Controller;

   overriding procedure Finalize (Guard : in out Operation_Guard) is
   begin
      case Guard.State is
         when Unregistered =>
            null;
         when Registered =>
            Guard.Item.Controller.Abandon_Operation (Guard.Generation);
            Guard.State := Unregistered;
         when Acquired =>
            Guard.Item.Controller.Release (Guard.Generation);
            Guard.State := Unregistered;
      end case;
   end Finalize;
   protected body Server is
      entry Acquire (Accepted : out Boolean)
        when Stopping or else Active_Count < Capacity
      is
      begin
         Accepted := not Stopping;
         if Accepted then
            Active_Count := Policy.Started_After_Register (Active_Count);
         end if;
      end Acquire;

      procedure Release is
      begin
         if Active_Count = 0 then
            raise Program_Error with "connection permit released twice";
         end if;
         Active_Count := Policy.Started_After_Release (Active_Count);
      end Release;

      procedure Request_Shutdown is
      begin
         if not Stopping then
            Wake_Sources.Signal (Wake);
            Stopping := True;
         end if;
      end Request_Shutdown;

      entry Await_Drained when Stopping and then Active_Count = 0 is
      begin
         null;
      end Await_Drained;

      function Shutdown_Requested return Boolean is (Stopping);
      function Active return Natural is (Active_Count);
      function Waiting return Natural is (Acquire'Count);

      procedure Wait_Source
        (FD : out Descriptor; Already_Requested : out Boolean)
      is
      begin
         Already_Requested := Stopping;
         if Stopping then
            FD := Invalid_Descriptor;
         else
            Wake_Sources.Ensure (Wake);
            FD := Wake_Sources.Descriptor (Wake);
         end if;
      end Wait_Source;
   end Server;

   function Remaining
     (Started : Ada.Real_Time.Time;
      Timeout : Duration) return Duration
   is
   begin
      if Timeout < 0.0 then
         return Infinite;
      end if;
      return Time_Math.Remaining
        (Timeout,
         Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started));
   end Remaining;

   procedure Interrupt_Sources
     (Owner   : not null Server_Access;
      Token   : access Cancellation_Token;
      Sources : out Interrupt_Set;
      Count   : out Natural)
   is
      Shutdown : Boolean;
      Cancel   : Boolean := False;
   begin
      Sources := (others => Invalid_Descriptor);
      Count := 1;
      Owner.Wait_Source (Sources (Sources'First), Shutdown);
      if Token /= null then
         Count := 2;
         Token.Wait_Source (Sources (Sources'First + 1), Cancel);
      end if;
      if Shutdown or else Cancel then
         raise Operation_Cancelled;
      end if;
   end Interrupt_Sources;

   procedure Acquire_Operation
     (Item          : in out Connection;
      Started       : Ada.Real_Time.Time;
      Timeout       : Duration;
      Token         : access Cancellation_Token;
      FD            : out Descriptor;
      Guard         : in out Operation_Guard;
      Close_Source  : out Descriptor;
      Socket        : out Sockets.Socket_Type;
      Owner         : out Server_Access)
   is
      Lease_Source : Descriptor;
      Initial_Close_Source : Descriptor;
      Initial_Owner : Server_Access;
      Interrupts : Interrupt_Set (1 .. 3);
      Interrupt_Count : Natural;
      Outcome : Wait_Outcome := Timed_Out;
      Result : Lease_Result := Lease_Busy;
   begin
      Item.Controller.Start_Operation
        (Guard.Generation'Access,
         Guard.State'Access,
         Lease_Source,
         Initial_Close_Source,
         Initial_Owner);
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
      Test_Barrier (0);
#end if;
      loop
         Interrupts (1) := Initial_Close_Source;
         Interrupt_Sources
           (Initial_Owner, Token, Interrupts (2 .. 3), Interrupt_Count);
         Item.Controller.Try_Acquire
           (Guard.Generation,
            Guard.State'Access,
            Result,
            FD,
            Close_Source,
            Socket,
            Owner);
         case Result is
            when Lease_Acquired =>
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
               Test_Barrier (1);
#end if;
               return;
            when Lease_Cancelled =>
               raise Operation_Cancelled with
                 "connection closed while waiting for its operation lease";
            when Lease_Busy =>
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
               Test_Barrier (4);
#else
               null;
#end if;
         end case;

         --  Try_Acquire observes Active under the controller lock before this
         --  wait is armed. Release makes Lease_Source readable under the same
         --  lock, so readiness persists across the registration window.
         Outcome := Wait_Interruptibly
           (Lease_Source,
            For_Read,
            Remaining (Started, Timeout),
            Interrupts (1 .. Interrupt_Count + 1));
         if Outcome /= Ready then
            case Outcome is
               when Timed_Out =>
                  raise Timeout_Error with
                    "connection operation lease timed out";
               when Interrupted =>
                  raise Operation_Cancelled with
                    "connection operation lease was cancelled";
               when Ready =>
                  null;
            end case;
         end if;
      end loop;
   end Acquire_Operation;

   procedure Reserve
     (Manager : aliased in out Server;
      Owner   : out Server_Access)
   is
      Accepted : Boolean;
   begin
      Manager.Acquire (Accepted);
      if not Accepted then
         raise Admission_Closed;
      end if;
      Owner := Manager'Unchecked_Access;
   end Reserve;

   procedure Take
     (Manager : aliased in out Server;
      Socket  : in out Sockets.Socket_Type;
      Item    : in out Connection)
   is
      Owner    : Server_Access;
      Reserved : Boolean := False;
   begin
      if Socket = Sockets.No_Socket then
         raise Program_Error with "cannot own No_Socket";
      elsif Is_Open (Item) then
         raise Program_Error with "connection already owns a socket";
      end if;

      Reserve (Manager, Owner);
      Reserved := True;
      begin
         Item.Controller.Adopt
           (Flyology.IO.Sockets.Native_Descriptor (Socket),
            Socket,
            Owner);
         Reserved := False;
         Socket := Sockets.No_Socket;
      exception
         when others =>
            if Reserved then
               Owner.Release;
            end if;
            raise;
      end;
   end Take;

   procedure Accept_Connection
     (Manager              : aliased in out Server;
      Listener             : Sockets.Socket_Type;
      Item                 : in out Connection;
      Address              : out Sockets.Sock_Addr_Type;
      Timeout              : Duration := Infinite;
      Cancellation_Quantum : Duration := 0.050;
      Token                : access Cancellation_Token := null)
   is
      Owner    : Server_Access;
      Socket   : Sockets.Socket_Type := Sockets.No_Socket;
      Reserved : Boolean := False;
      Interrupts : Interrupt_Set (1 .. 2);
      Interrupt_Count : Natural;
      pragma Unreferenced (Cancellation_Quantum);
   begin
      if Is_Open (Item) then
         raise Program_Error with "connection already owns a socket";
      end if;
      Reserve (Manager, Owner);
      Reserved := True;

      Interrupt_Sources
        (Owner, Token, Interrupts, Interrupt_Count);

      begin
         Flyology.IO.Sockets.Accept_Connection
           (Listener, Socket, Address, Timeout,
            Interrupts (1 .. Interrupt_Count));
      exception
         when Flyology.IO.Sockets.Operation_Interrupted =>
            raise Operation_Cancelled;
      end;
      if Manager.Shutdown_Requested
        or else (Token /= null and then Token.Requested)
      then
         raise Operation_Cancelled;
      end if;
      Item.Controller.Adopt
        (Flyology.IO.Sockets.Native_Descriptor (Socket), Socket, Owner);
      Reserved := False;
   exception
      when others =>
         if Reserved then
            Owner.Release;
         end if;
         --  Capacity is released before a fallible cleanup close so a close
         --  error cannot strand the admission permit.
         if Socket /= Sockets.No_Socket then
            Sockets.Close_Socket (Socket);
         end if;
         raise;
   end Accept_Connection;

   procedure Close (Item : in out Connection) is
      FD         : Descriptor;
      Generation : Descriptor_Generation;
      Leader     : Boolean;
      Socket     : Sockets.Socket_Type;
      Owner      : Server_Access;
   begin
      Item.Controller.Begin_Close (FD, Generation, Leader);
      if not Leader then
         if FD >= 0 then
            Item.Controller.Await_Closed;
         end if;
         return;
      end if;

      --  The exact generation remains allocated until its sole operation has
      --  observed Close_Wake and acknowledged release. Only then may the OS
      --  recycle the integer descriptor.
      Item.Controller.Await_Drained (Socket, Owner);
      if Socket /= Sockets.No_Socket then
         begin
            Sockets.Close_Socket (Socket);
         exception
            when others =>
               Item.Controller.Finish_Close (Generation);
               if Owner /= null then
                  Owner.Release;
               end if;
               raise;
         end;
      end if;
      Item.Controller.Finish_Close (Generation);
      if Owner /= null then
         Owner.Release;
      end if;
   end Close;

   function Is_Open (Item : Connection) return Boolean is
     (Item.Controller.Is_Open_State);

   procedure Receive
     (Item                 : in out Connection;
      Data                 : out Ada.Streams.Stream_Element_Array;
      Last                 : out Ada.Streams.Stream_Element_Offset;
      Timeout              : Duration := Infinite;
      Cancellation_Quantum : Duration := 0.050;
      Token                : access Cancellation_Token := null)
   is
      Interrupts : Interrupt_Set (1 .. 3);
      Interrupt_Count : Natural;
      FD : Descriptor;
      Guard : Operation_Guard (Item'Unchecked_Access);
      Socket : Sockets.Socket_Type;
      Owner : Server_Access;
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      pragma Unreferenced (Cancellation_Quantum);
   begin
      Acquire_Operation
        (Item, Started, Timeout, Token,
         FD, Guard, Interrupts (1), Socket, Owner);
      pragma Assert (FD = Flyology.IO.Sockets.Native_Descriptor (Socket));
      Interrupt_Sources
        (Owner, Token, Interrupts (2 .. 3), Interrupt_Count);
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
      Test_Barrier (3);
#end if;
      begin
         Flyology.IO.Sockets.Receive
           (Socket, Data, Last, Remaining (Started, Timeout),
            Interrupts (1 .. Interrupt_Count + 1));
      exception
         when Flyology.IO.Sockets.Operation_Interrupted =>
            raise Operation_Cancelled;
      end;
   end Receive;

   procedure Receive_Exactly
     (Item                 : in out Connection;
      Data                 : out Ada.Streams.Stream_Element_Array;
      Timeout              : Duration := Infinite;
      Cancellation_Quantum : Duration := 0.050;
      Token                : access Cancellation_Token := null)
   is
      Started        : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      First          : Ada.Streams.Stream_Element_Offset := Data'First;
      Last           : Ada.Streams.Stream_Element_Offset;
      Interrupts     : Interrupt_Set (1 .. 3);
      Interrupt_Count : Natural;
      FD             : Descriptor;
      Guard          : Operation_Guard (Item'Unchecked_Access);
      Socket         : Sockets.Socket_Type;
      Owner          : Server_Access;
      pragma Unreferenced (Cancellation_Quantum);
   begin
      Acquire_Operation
        (Item, Started, Timeout, Token,
         FD, Guard, Interrupts (1), Socket, Owner);
      pragma Assert (FD = Flyology.IO.Sockets.Native_Descriptor (Socket));
      begin
         while First <= Data'Last loop
            Item.Controller.Check_Operation (Guard.Generation);
            Interrupt_Sources
              (Owner, Token, Interrupts (2 .. 3), Interrupt_Count);
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
            Test_Barrier (3);
#end if;
            Flyology.IO.Sockets.Receive
              (Socket,
               Data (First .. Data'Last),
               Last,
               Remaining (Started, Timeout),
               Interrupts (1 .. Interrupt_Count + 1));
            if Last < First then
               raise Device_Error with "connection closed while receiving";
            end if;
            First := Last + 1;
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
            if First <= Data'Last then
               Test_Barrier (5);
            end if;
#end if;
         end loop;
      exception
         when Flyology.IO.Sockets.Operation_Interrupted =>
            raise Operation_Cancelled;
      end;
   end Receive_Exactly;

   procedure Send_All
     (Item                 : in out Connection;
      Data                 : Ada.Streams.Stream_Element_Array;
      Timeout              : Duration := Infinite;
      Cancellation_Quantum : Duration := 0.050;
      Token                : access Cancellation_Token := null)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      First   : Ada.Streams.Stream_Element_Offset := Data'First;
      Last    : Ada.Streams.Stream_Element_Offset;
      Interrupts : Interrupt_Set (1 .. 3);
      Interrupt_Count : Natural;
      FD : Descriptor;
      Guard : Operation_Guard (Item'Unchecked_Access);
      Socket : Sockets.Socket_Type;
      Owner : Server_Access;
      pragma Unreferenced (Cancellation_Quantum);
   begin
      Acquire_Operation
        (Item, Started, Timeout, Token,
         FD, Guard, Interrupts (1), Socket, Owner);
      pragma Assert (FD = Flyology.IO.Sockets.Native_Descriptor (Socket));
      begin
         while First <= Data'Last loop
            Item.Controller.Check_Operation (Guard.Generation);
            Interrupt_Sources
              (Owner, Token, Interrupts (2 .. 3), Interrupt_Count);
            declare
               Chunk_Last : constant Ada.Streams.Stream_Element_Offset :=
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
                 First;
#else
                 Data'Last;
#end if;
            begin
               Flyology.IO.Sockets.Send
                 (Socket,
                  Data (First .. Chunk_Last),
                  Last,
                  Remaining (Started, Timeout),
                  Interrupts (1 .. Interrupt_Count + 1));
            end;
            if Last < First then
               raise Device_Error with "connection closed while sending";
            end if;
            First := Last + 1;
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
            if First <= Data'Last then
               Test_Barrier (2);
            end if;
#end if;
         end loop;
      exception
         when Flyology.IO.Sockets.Operation_Interrupted =>
            raise Operation_Cancelled;
      end;
   end Send_All;

   overriding procedure Finalize (Item : in out Connection) is
   begin
      Close (Item);
   exception
      --  Close clears ownership and releases admission even when the OS close
      --  reports an error. Finalization must not mask an enclosing exception.
      when others =>
         null;
   end Finalize;

end Flyology.IO.Connections;
