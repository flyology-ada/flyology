with Ada.Real_Time;
with Ada.Unchecked_Deallocation;
with Flyology.Connection_Policy;
with Flyology.IO.TLS_Driver;
with Flyology.Time_Math;
with Interfaces.C;

package body Flyology.IO.Connections is
   package Policy renames Flyology.Connection_Policy;
   package Sockets renames Flyology.IO.Sockets;
   package TLS renames Flyology.IO.TLS;

   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;
   use type Flyology.Capacity.Acquire_Result;
   use type Interfaces.C.int;
   use type TLS.Session_Access;
   use type TLS.Role;
   use type TLS.Step_Status;

   procedure Free is new Ada.Unchecked_Deallocation
     (TLS.Session'Class, TLS.Session_Access);

   --  GNAT implements this as SO_NOSIGPIPE on Darwin and a no-op where send
   --  flags provide the equivalent process-safety behavior.
   procedure Disable_SIGPIPE (Socket : Interfaces.C.int);
   pragma Import (C, Disable_SIGPIPE, "__gnat_disable_sigpipe");

   type Operation_Guard (Item : not null access Connection) is
     new Ada.Finalization.Limited_Controlled with record
      Generation : aliased Descriptor_Generation := 0;
      State      : aliased Operation_State := Unregistered;
      Socket     : Sockets.Socket_Type;
   end record;

   overriding procedure Finalize (Guard : in out Operation_Guard);

   --  The gate and descriptor controller update Armed in their protected
   --  ownership transitions. Socket holds an accepted descriptor until the
   --  same adoption transition moves it into the Connection.
   type Admission_Guard (Owner : not null Server_Access) is
     new Ada.Finalization.Limited_Controlled with record
      Armed  : aliased Boolean := False;
      Socket : Sockets.Socket_Type;
   end record;

   overriding procedure Finalize (Guard : in out Admission_Guard);

   type Upgrade_Cleanup_Guard (Item : not null access Connection) is
     new Ada.Finalization.Limited_Controlled with record
      Armed : aliased Boolean := False;
   end record;

   type Session_Setup_Guard is
     new Ada.Finalization.Limited_Controlled with record
      Value : TLS.Session_Access := null;
   end record;

   overriding procedure Finalize (Guard : in out Upgrade_Cleanup_Guard);
   overriding procedure Finalize (Guard : in out Session_Setup_Guard);

   procedure Disarm (Guard : in out Upgrade_Cleanup_Guard) is
   begin
      Guard.Armed := False;
   end Disarm;

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
   function Test_Barrier_Arrive_Once
     (Point : Interfaces.C.int) return Interfaces.C.int
     with Import,
          Convention => C,
          External_Name => "flyology_test_connection_barrier_arrive_once";

   procedure Test_Barrier (Point : Interfaces.C.int) is
   begin
      if Test_Barrier_Arrive (Point) /= 0 then
         while Test_Barrier_Released (Point) = 0 loop
            delay 0.0;
         end loop;
      end if;
   end Test_Barrier;

   procedure Test_One_Shot_Barrier (Point : Interfaces.C.int) is
   begin
      if Test_Barrier_Arrive_Once (Point) /= 0 then
         while Test_Barrier_Released (Point) = 0 loop
            delay 0.0;
         end loop;
      end if;
   end Test_One_Shot_Barrier;
#end if;

   protected body Descriptor_Controller is
      procedure Adopt
        (FD            : Descriptor;
         Socket        : in out Sockets.Socket_Type;
         Owner         : Server_Access;
         Cleanup_Armed : not null access Boolean)
      is
      begin
         if FD < 0
           or else not Sockets.Is_Open (Socket)
           or else Flyology.IO.Sockets.Native_Descriptor (Socket) /= FD
           or else Owner = null
           or else Current_FD >= 0
           or else Active
           or else Closing
           or else not Cleanup_Armed.all
         then
            raise Program_Error with
              "descriptor controller already owns a resource";
         end if;
         Wake_Sources.Ensure (Lease_Wake);
         Wake_Sources.Ensure (Close_Wake);
         Sockets.Move (Socket, Current_Socket);
         Current_Owner := Owner;
         Current_FD := FD;
         Current_Generation := Current_Generation + 1;
         Current_Transport := Plain_Transport;
         --  The Connection now owns both resources. A pending abort cannot
         --  leave the protected action until the cleanup obligation reflects
         --  that transfer.
         Cleanup_Armed.all := False;
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
         if Current_Transport = TLS_Upgrading then
            raise Operation_Cancelled with
              "connection transport is being upgraded";
         elsif Current_FD < 0
           or else Closing
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
         Socket       : in out Sockets.Socket_Type;
         Owner        : out Server_Access;
         Transport    : out Transport_Kind)
      is
      begin
         if State.all /= Registered then
            raise Program_Error with "connection operation is not registered";
         end if;
         case Policy.Classify_Acquire
           (Generation_Matches => Expected_Generation = Current_Generation,
            Resources_Open     =>
              Current_FD >= 0
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
               Transport := No_Transport;
               return;
            when Policy.Wait_For_Lease =>
               Result := Lease_Busy;
               Transport := No_Transport;
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
         Sockets.Move (Current_Socket, Socket);
         Owner := Current_Owner;
         Transport := Current_Transport;
         --  Active and the guard state become visible in one protected action.
         --  Finalization after any abort at the call boundary will Release.
         State.all := Acquired;
         Result := Lease_Acquired;
      end Try_Acquire;

      procedure Abandon_Operation (Generation : Descriptor_Generation) is
      begin
         pragma Unreferenced (Generation);
         if Started_Operations = 0 then
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

      procedure Begin_TLS_Upgrade
        (Generation    : in out Descriptor_Generation;
         Cleanup_Armed : not null access Boolean)
      is
      begin
         if not Active
           or else Generation /= Current_Generation
           or else Current_Transport /= Plain_Transport
         then
            raise Program_Error with
              "connection TLS upgrade requires an active plaintext transport";
         elsif Closing then
            raise Operation_Cancelled with
              "connection closed before its TLS upgrade transition";
         end if;
         Current_Transport := TLS_Upgrading;
         Current_Generation := Current_Generation + 1;
         Generation := Current_Generation;
         --  Publish the cleanup obligation before the protected-call abort
         --  completion point, matching operation registration and acquisition.
         Cleanup_Armed.all := True;
      end Begin_TLS_Upgrade;

      procedure Finish_TLS_Upgrade
        (Generation : Descriptor_Generation)
      is
      begin
         if not Active
           or else Generation /= Current_Generation
           or else Current_Transport /= TLS_Upgrading
         then
            raise Program_Error with "invalid TLS upgrade completion";
         elsif Closing then
            raise Operation_Cancelled with
              "connection closed during its TLS upgrade";
         end if;
         Current_Transport := TLS_Transport;
      end Finish_TLS_Upgrade;

      procedure Release
        (Generation : Descriptor_Generation;
         Socket     : in out Sockets.Socket_Type)
      is
      begin
         if not Active
           or else Generation /= Current_Generation
           or else Started_Operations = 0
         then
            raise Program_Error with "stale descriptor operation release";
         end if;
         if not Sockets.Is_Open (Socket) then
            raise Program_Error with "active operation lost socket ownership";
         end if;
         Sockets.Move (Socket, Current_Socket);
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
        (Socket : in out Sockets.Socket_Type;
         Owner  : out Server_Access)
        when not Active and then Started_Operations = 0
      is
      begin
         if not Closing
           or else Current_FD < 0
           or else not Sockets.Is_Open (Current_Socket)
           or else Current_Owner = null
         then
            raise Program_Error with "invalid descriptor close handoff";
         end if;
         Sockets.Move (Current_Socket, Socket);
         Owner := Current_Owner;
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
            not Sockets.Is_Open (Current_Socket)
              and then Current_Owner = null)
         then
            raise Program_Error with "stale descriptor close completion";
         end if;
         Current_FD := Invalid_Descriptor;
         Current_Transport := No_Transport;
         Wake_Sources.Release (Lease_Wake);
         Wake_Sources.Release (Close_Wake);
         Lease_Signalled := False;
         Closing := False;
      end Finish_Close;

      function Is_Open_State return Boolean is
        (Policy.Is_Open (Current_FD >= 0, Closing));

      function Waiting_Count return Natural is
        (Policy.Waiting_Operations (Started_Operations, Active));

      function Lease_Active return Boolean is (Active);

      function Close_Pending return Boolean is (Closing);

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
            Guard.Item.Controller.Release (Guard.Generation, Guard.Socket);
            Guard.State := Unregistered;
      end case;
   end Finalize;

   overriding procedure Finalize (Guard : in out Admission_Guard) is
   begin
      if Guard.Armed then
         Guard.Owner.Release (Guard.Armed'Access);
      end if;
      --  Release capacity first. A fallible descriptor close cannot strand a
      --  permit, and adoption has already moved Socket when it disarms Guard.
      if Sockets.Is_Open (Guard.Socket) then
         Sockets.Close_Socket (Guard.Socket);
      end if;
   end Finalize;

   overriding procedure Finalize (Guard : in out Upgrade_Cleanup_Guard) is
   begin
      if Guard.Armed then
         begin
            Close (Guard.Item.all);
         exception
            --  The upgrade exception remains primary. Close still makes the
            --  connection terminal and releases admission before raising.
            when others =>
               null;
         end;
      end if;
   end Finalize;

   overriding procedure Finalize (Guard : in out Session_Setup_Guard) is
   begin
      if Guard.Value /= null then
         begin
            Free (Guard.Value);
         exception
            when others =>
               Guard.Value := null;
         end;
      end if;
   end Finalize;
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
      Owner         : out Server_Access;
      Transport     : out Transport_Kind)
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
      --  Unlike the general barrier above, only the first registration parks.
      --  A competing upgrade can therefore advance the transport generation.
      Test_One_Shot_Barrier (6);
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
            Guard.Socket,
            Owner,
            Transport);
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

   procedure Check_TLS_Operation
     (Item       : in out Connection;
      Generation : Descriptor_Generation;
      Owner      : not null Server_Access;
      Token      : access Cancellation_Token)
   is
   begin
      Item.Controller.Check_Operation (Generation);
      if Owner.Shutdown_Requested
        or else (Token /= null and then Token.Requested)
      then
         raise Operation_Cancelled;
      end if;
   end Check_TLS_Operation;

   procedure Await_TLS_Ready
     (FD           : Descriptor;
      Status       : TLS.Step_Status;
      Started      : Ada.Real_Time.Time;
      Timeout      : Duration;
      Close_Source : Descriptor;
      Owner        : not null Server_Access;
      Token        : access Cancellation_Token)
   is
      Interrupts      : Interrupt_Set (1 .. 3);
      Interrupt_Count : Natural;
      Outcome         : Wait_Outcome;
   begin
      Interrupts (1) := Close_Source;
      Interrupt_Sources
        (Owner, Token, Interrupts (2 .. 3), Interrupt_Count);
      Outcome := Wait_Interruptibly
        (FD,
         (if Status = TLS.Want_Read then For_Read else For_Write),
         Remaining (Started, Timeout),
         Interrupts (1 .. Interrupt_Count + 1));
      case Outcome is
         when Ready =>
            null;
         when Timed_Out =>
            raise Timeout_Error with "TLS connection operation timed out";
         when Interrupted =>
            raise Operation_Cancelled;
      end case;
   end Await_TLS_Ready;

   procedure Reserve
     (Manager : aliased in out Server;
      Guard   : in out Admission_Guard)
   is
      Accepted : Boolean;
   begin
      Manager.Acquire (Accepted, Guard.Armed'Access);
      if not Accepted then
         raise Admission_Closed;
      end if;
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
      Test_Barrier (10);
#end if;
   end Reserve;

   procedure Reserve_Interruptibly
     (Manager : aliased in out Server;
      Started : Ada.Real_Time.Time;
      Timeout : Duration;
      Token   : access Cancellation_Token;
      Guard   : in out Admission_Guard)
   is
      Result      : Flyology.Capacity.Acquire_Result;
      Acquire_FD  : Descriptor;
      Token_FD    : Descriptor;
      Can_Acquire : Boolean;
      Cancelled   : Boolean;
      Outcome     : Wait_Outcome;
      Interrupts  : Interrupt_Set (1 .. 1);
   begin
      loop
         Manager.Try_Acquire (Result, Guard.Armed'Access);
         case Result is
            when Flyology.Capacity.Permit_Acquired =>
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
               Test_Barrier (8);
#end if;
               return;
            when Flyology.Capacity.Gate_Closed =>
               raise Admission_Closed;
            when Flyology.Capacity.Gate_Full =>
               null;
            when Flyology.Capacity.Acquire_Timed_Out =>
               raise Program_Error with
                 "nonblocking admission returned a timed result";
         end case;

         --  Try_Acquire and Acquire_Wait_Source observe the gate under the
         --  same protected lock. A release in between makes Can_Acquire true;
         --  a later release leaves persistent readiness for this wait.
         Manager.Acquire_Wait_Source (Acquire_FD, Can_Acquire);
         if not Can_Acquire then
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
            Test_Barrier (9);
#end if;
            if Token = null then
               Outcome := Wait_Interruptibly
                 (Acquire_FD, For_Read, Remaining (Started, Timeout));
            else
               Token.Wait_Source (Token_FD, Cancelled);
               if Cancelled then
                  raise Operation_Cancelled with
                    "connection admission was cancelled";
               end if;
               Interrupts (1) := Token_FD;
               Outcome := Wait_Interruptibly
                 (Acquire_FD, For_Read, Remaining (Started, Timeout),
                  Interrupts);
            end if;

            case Outcome is
               when Ready =>
                  null;
               when Timed_Out =>
                  raise Timeout_Error with
                    "connection admission timed out";
               when Interrupted =>
                  raise Operation_Cancelled with
                    "connection admission was cancelled";
            end case;
         end if;
      end loop;
   end Reserve_Interruptibly;

   procedure Take
     (Manager : aliased in out Server;
      Socket  : in out Sockets.Socket_Type;
      Item    : in out Connection)
   is
      Guard : Admission_Guard (Manager'Unchecked_Access);
   begin
      if not Sockets.Is_Open (Socket) then
         raise Program_Error with "cannot own a closed socket";
      elsif Is_Open (Item) then
         raise Program_Error with "connection already owns a socket";
      end if;

      Reserve (Manager, Guard);
      Item.Controller.Adopt
        (Flyology.IO.Sockets.Native_Descriptor (Socket),
         Socket,
         Guard.Owner,
         Guard.Armed'Access);
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
      Test_Barrier (12);
#end if;
   end Take;

   procedure Upgrade_TLS
     (Item        : in out Connection;
      Backend     : in out TLS.Provider'Class;
      Side        : TLS.Role;
      Server_Name : String;
      Timeout     : Duration;
      Token       : access Cancellation_Token)
   is
      Started      : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Cleanup      : Upgrade_Cleanup_Guard (Item'Unchecked_Access);
      Guard        : Operation_Guard (Item'Unchecked_Access);
      Session_Hold : Session_Setup_Guard;
      FD           : Descriptor;
      Close_Source : Descriptor;
      Owner        : Server_Access;
      Transport    : Transport_Kind;
      Available    : Boolean;

      procedure Check_Setup_Deadline is
      begin
         --  Provider and socket setup calls are synchronous. A positive
         --  deadline is checked at every return boundary; zero retains the
         --  established immediate-attempt behavior.
         if Timeout > 0.0 and then Remaining (Started, Timeout) = 0.0 then
            raise Timeout_Error with "TLS provider setup timed out";
         end if;
      end Check_Setup_Deadline;

      procedure Check is
      begin
         Check_TLS_Operation
           (Item, Guard.Generation, Owner, Token);
      end Check;

      procedure Await (Status : TLS.Step_Status) is
      begin
         Await_TLS_Ready
           (FD, Status, Started, Timeout, Close_Source, Owner, Token);
      end Await;
   begin
      if Side = TLS.Client and then Server_Name'Length = 0 then
         raise Program_Error with "TLS client requires a server name";
      elsif Side = TLS.Server and then Server_Name'Length /= 0 then
         raise Program_Error with "TLS server does not accept a server name";
      end if;

      Acquire_Operation
        (Item, Started, Timeout, Token,
         FD, Guard, Close_Source, Owner, Transport);
      if Transport /= Plain_Transport then
         raise Program_Error with
           "connection TLS upgrade requires a plaintext transport";
      end if;

      Item.Controller.Begin_TLS_Upgrade
        (Guard.Generation, Cleanup.Armed'Access);

      Available := TLS.Is_Available (Backend);
      Check_Setup_Deadline;
      if not Available then
         raise TLS.TLS_Error with
           TLS.Name (Backend) & " provider is unavailable";
      end if;
      Sockets.Prepare (Guard.Socket);
      Check_Setup_Deadline;
      FD := Sockets.Native_Descriptor (Guard.Socket);
      Disable_SIGPIPE (Interfaces.C.int (FD));
      Check_Setup_Deadline;
      Session_Hold.Value :=
        TLS.Create_Session (Backend, FD, Side, Server_Name);
      Check_Setup_Deadline;
      if Session_Hold.Value = null then
         raise TLS.TLS_Error with
           TLS.Name (Backend) & " returned no TLS session";
      end if;
      Item.TLS_Session := Session_Hold.Value;
      Session_Hold.Value := null;
      Item.TLS_Shutdown_Complete := False;
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
      Test_Barrier (7);
#end if;

      TLS_Driver.Handshake
        (Item.TLS_Session.all, Check'Access, Await'Access);
      Item.Controller.Finish_TLS_Upgrade (Guard.Generation);
      Disarm (Cleanup);
   end Upgrade_TLS;

   procedure Shutdown_TLS
     (Item    : in out Connection;
      Timeout : Duration;
      Token   : access Cancellation_Token)
   is
      Started      : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Guard        : Operation_Guard (Item'Unchecked_Access);
      FD           : Descriptor;
      Close_Source : Descriptor;
      Owner        : Server_Access;
      Transport    : Transport_Kind;

      procedure Check is
      begin
         Check_TLS_Operation
           (Item, Guard.Generation, Owner, Token);
      end Check;

      procedure Await (Status : TLS.Step_Status) is
      begin
         Await_TLS_Ready
           (FD, Status, Started, Timeout, Close_Source, Owner, Token);
      end Await;
   begin
      Acquire_Operation
        (Item, Started, Timeout, Token,
         FD, Guard, Close_Source, Owner, Transport);
      if Transport /= TLS_Transport or else Item.TLS_Session = null then
         raise Program_Error with "connection transport does not use TLS";
      elsif Item.TLS_Shutdown_Complete then
         return;
      end if;
      TLS_Driver.Shutdown
        (Item.TLS_Session.all, Check'Access, Await'Access);
      Item.TLS_Shutdown_Complete := True;
   end Shutdown_TLS;

   procedure Accept_Connection
     (Manager              : aliased in out Server;
      Listener             : Sockets.Socket_Type;
      Item                 : in out Connection;
      Address              : out Sockets.Endpoint;
      Timeout              : Duration := Infinite;
      Cancellation_Quantum : Duration := 0.050;
      Token                : access Cancellation_Token := null)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Guard   : Admission_Guard (Manager'Unchecked_Access);
      Interrupts : Interrupt_Set (1 .. 2);
      Interrupt_Count : Natural;
      pragma Unreferenced (Cancellation_Quantum);
   begin
      if Is_Open (Item) then
         raise Program_Error with "connection already owns a socket";
      end if;
      Reserve_Interruptibly (Manager, Started, Timeout, Token, Guard);

      Interrupt_Sources
        (Guard.Owner, Token, Interrupts, Interrupt_Count);

      begin
         Flyology.IO.Sockets.Accept_Connection
           (Listener, Guard.Socket, Address, Remaining (Started, Timeout),
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
        (Flyology.IO.Sockets.Native_Descriptor (Guard.Socket),
         Guard.Socket,
         Guard.Owner,
         Guard.Armed'Access);
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
      Test_Barrier (11);
#end if;
   end Accept_Connection;

   procedure Close (Item : in out Connection) is
      FD         : Descriptor;
      Generation : Descriptor_Generation;
      Leader     : Boolean;
      Socket     : Sockets.Socket_Type;
      Owner      : Server_Access;
      Provider_Error : Boolean := False;
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
      begin
         Free (Item.TLS_Session);
      exception
         when others =>
            Item.TLS_Session := null;
            Provider_Error := True;
      end;
      Item.TLS_Shutdown_Complete := False;
      if Sockets.Is_Open (Socket) then
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
      if Provider_Error then
         raise TLS.TLS_Error with "TLS provider session finalization failed";
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
      Owner : Server_Access;
      Transport : Transport_Kind;
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      pragma Unreferenced (Cancellation_Quantum);
      procedure Check is
      begin
         Check_TLS_Operation
           (Item, Guard.Generation, Owner, Token);
      end Check;
      procedure Await (Status : TLS.Step_Status) is
      begin
         Await_TLS_Ready
           (FD, Status, Started, Timeout, Interrupts (1), Owner, Token);
      end Await;
   begin
      Acquire_Operation
        (Item, Started, Timeout, Token,
         FD, Guard, Interrupts (1), Owner, Transport);
      pragma Assert
        (FD = Flyology.IO.Sockets.Native_Descriptor (Guard.Socket));
      if Transport = TLS_Transport then
         if Item.TLS_Session = null then
            raise Program_Error with "TLS transport has no provider session";
         end if;
         TLS_Driver.Receive
           (Item.TLS_Session.all, Data, Last, Check'Access, Await'Access);
         return;
      elsif Transport /= Plain_Transport then
         raise Operation_Cancelled;
      end if;
      Interrupt_Sources
        (Owner, Token, Interrupts (2 .. 3), Interrupt_Count);
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
      Test_Barrier (3);
#end if;
      begin
         Flyology.IO.Sockets.Receive
           (Guard.Socket, Data, Last, Remaining (Started, Timeout),
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
      Owner          : Server_Access;
      Transport      : Transport_Kind;
      pragma Unreferenced (Cancellation_Quantum);
      procedure Check is
      begin
         Check_TLS_Operation
           (Item, Guard.Generation, Owner, Token);
      end Check;
      procedure Await (Status : TLS.Step_Status) is
      begin
         Await_TLS_Ready
           (FD, Status, Started, Timeout, Interrupts (1), Owner, Token);
      end Await;
   begin
      Acquire_Operation
        (Item, Started, Timeout, Token,
         FD, Guard, Interrupts (1), Owner, Transport);
      pragma Assert
        (FD = Flyology.IO.Sockets.Native_Descriptor (Guard.Socket));
      if Transport = TLS_Transport then
         if Item.TLS_Session = null then
            raise Program_Error with "TLS transport has no provider session";
         end if;
         TLS_Driver.Receive_Exactly
           (Item.TLS_Session.all, Data, Check'Access, Await'Access);
         return;
      elsif Transport /= Plain_Transport then
         raise Operation_Cancelled;
      end if;
      begin
         while First <= Data'Last loop
            Item.Controller.Check_Operation (Guard.Generation);
            Interrupt_Sources
              (Owner, Token, Interrupts (2 .. 3), Interrupt_Count);
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
            Test_Barrier (3);
#end if;
            Flyology.IO.Sockets.Receive
              (Guard.Socket,
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
      Owner : Server_Access;
      Transport : Transport_Kind;
      pragma Unreferenced (Cancellation_Quantum);
      procedure Check is
      begin
         Check_TLS_Operation
           (Item, Guard.Generation, Owner, Token);
      end Check;
      procedure Await (Status : TLS.Step_Status) is
      begin
         Await_TLS_Ready
           (FD, Status, Started, Timeout, Interrupts (1), Owner, Token);
      end Await;
   begin
      Acquire_Operation
        (Item, Started, Timeout, Token,
         FD, Guard, Interrupts (1), Owner, Transport);
      pragma Assert
        (FD = Flyology.IO.Sockets.Native_Descriptor (Guard.Socket));
      if Transport = TLS_Transport then
         if Item.TLS_Session = null then
            raise Program_Error with "TLS transport has no provider session";
         end if;
         TLS_Driver.Send_All
           (Item.TLS_Session.all, Data, Check'Access, Await'Access);
         return;
      elsif Transport /= Plain_Transport then
         raise Operation_Cancelled;
      end if;
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
                 (Guard.Socket,
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
