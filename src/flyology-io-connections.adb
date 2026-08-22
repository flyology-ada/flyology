with Ada.Exceptions;
with Ada.Unchecked_Deallocation;
with Flyology.Connection_Policy;
with Flyology.IO.TLS_Driver;
with Flyology.Operations.Drivers;
with Flyology.Socket_Policy;
with Flyology.Time_Math;
with Interfaces.C;
with System.Soft_Links;

package body Flyology.IO.Connections is
   package Policy renames Flyology.Connection_Policy;
   package Sockets renames Flyology.IO.Sockets;
   package TLS renames Flyology.IO.TLS;

   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;
   use type Flyology.Capacity.Acquire_Result;
   use type Flyology.Operations.Driver_Event;
   use type Flyology.Operations.Terminal_Outcome;
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

   --  Result of one close attempt. Close leadership is taken in Initialize
   --  and discharged in Finalize, so every terminal transition happens inside
   --  an abort-deferred controlled operation. The outcome outlives the guard
   --  and carries whatever must still be reported to the caller.
   type Close_Outcome is limited record
      FD             : Descriptor := Invalid_Descriptor;
      Generation     : Descriptor_Generation := 0;
      Leader         : Boolean := False;
      Provider_Error : Boolean := False;
      Failed         : Boolean := False;
      Failure        : Ada.Exceptions.Exception_Occurrence;
   end record;

   type Close_Guard
     (Item    : not null access Connection;
      Outcome : not null access Close_Outcome)
   is new Ada.Finalization.Limited_Controlled with null record;

   overriding procedure Initialize (Guard : in out Close_Guard);
   overriding procedure Finalize (Guard : in out Close_Guard);

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
   function Test_Receive_Limit
     (Requested : Interfaces.C.int) return Interfaces.C.int
     with Import,
          Convention => C,
          External_Name => "flyology_test_connection_receive_limit";

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
         FD           : out Descriptor;
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
         FD := Current_FD;
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

      procedure Abandon_Operation
        (Generation : Descriptor_Generation;
         State      : not null access Operation_State)
      is
      begin
         pragma Unreferenced (Generation);
         if State.all /= Registered or else Started_Operations = 0 then
            raise Program_Error with "stale connection operation withdrawal";
         end if;
         Started_Operations :=
           Policy.Started_After_Release (Started_Operations);
         --  Publish discharge of the caller's obligation in the same
         --  protected action and before the fallible wake notification.
         State.all := Unregistered;
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
         Socket     : in out Sockets.Socket_Type;
         State      : not null access Operation_State)
      is
      begin
         if State.all /= Acquired
           or else not Active
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
         --  As with abandonment, make the guard non-owning before a wake can
         --  fail. Validation failures leave it owning so finalization retries.
         State.all := Unregistered;
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
            if Policy.Close_Wake_Required (Leader, Started_Operations) then
               Wake_Sources.Signal (Close_Wake);
            end if;
            --  Publish the close only after the wake is known to be usable.
            --  A failed signal leaves no leadership behind, so a later Close
            --  can retry instead of waiting for a completion that the failed
            --  attempt can no longer perform.
            Closing := True;
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

   procedure Release_Operation (Guard : in out Operation_Guard) is
   begin
      case Guard.State is
         when Unregistered =>
            null;
         when Registered =>
            Guard.Item.Controller.Abandon_Operation
              (Guard.Generation, Guard.State'Access);
         when Acquired =>
            Guard.Item.Controller.Release
              (Guard.Generation, Guard.Socket, Guard.State'Access);
      end case;
   end Release_Operation;

   overriding procedure Finalize (Guard : in out Operation_Guard) is
   begin
      Release_Operation (Guard);
   end Finalize;

   procedure Release_Operation (Guard : in out Scoped_Operation_Guard) is
   begin
      case Guard.State is
         when Unregistered =>
            null;
         when Registered =>
            Guard.Item.Controller.Abandon_Operation
              (Guard.Generation, Guard.State'Access);
         when Acquired =>
            Guard.Item.Controller.Release
              (Guard.Generation, Guard.Socket, Guard.State'Access);
      end case;
      if Guard.State = Unregistered then
         Guard.Item := null;
      end if;
   exception
      when others =>
         --  Drop the retained Item only when the controller has atomically
         --  discharged the guard. Otherwise finalization must retry.
         if Guard.State = Unregistered then
            Guard.Item := null;
         end if;
         raise;
   end Release_Operation;

   procedure Release_Admission_Ownership
     (Owner  : Server_Access;
      Armed  : aliased in out Boolean;
      Socket : in out Sockets.Socket_Type)
   is
      Failure : Ada.Exceptions.Exception_Occurrence;
      Failed  : Boolean := False;
   begin
      if Armed then
         begin
            if Owner = null then
               raise Program_Error with
                 "admission cleanup has no owning manager";
            end if;
            Owner.Release (Armed'Access);
         exception
            when Occurrence : others =>
               Ada.Exceptions.Save_Occurrence (Failure, Occurrence);
               Failed := True;
         end;
      end if;
      --  Both obligations are attempted independently. Release clears Armed
      --  in the protected action before its fallible wake, and Close_Socket
      --  invalidates Socket even when close reports an error.
      if Sockets.Is_Open (Socket) then
         begin
            Sockets.Close_Socket (Socket);
         exception
            when Occurrence : others =>
               if not Failed then
                  Ada.Exceptions.Save_Occurrence (Failure, Occurrence);
                  Failed := True;
               end if;
         end;
      end if;
      if Failed then
         Ada.Exceptions.Reraise_Occurrence (Failure);
      end if;
   end Release_Admission_Ownership;

   overriding procedure Finalize (Guard : in out Admission_Guard) is
   begin
      Release_Admission_Ownership
        (Guard.Owner, Guard.Armed, Guard.Socket);
   end Finalize;

   overriding procedure Finalize (Item : in out Pending_Connect_Owner) is
   begin
      Release_Admission_Ownership
        (Item.Manager, Item.Armed, Item.Socket);
      if not Item.Armed and then not Sockets.Is_Open (Item.Socket) then
         Item.Manager := null;
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

   overriding procedure Initialize (Guard : in out Close_Guard) is
   begin
      Guard.Item.Controller.Begin_Close
        (Guard.Outcome.FD,
         Guard.Outcome.Generation,
         Guard.Outcome.Leader);
   end Initialize;

   overriding procedure Finalize (Guard : in out Close_Guard) is
      Socket : Sockets.Socket_Type;
      Owner  : Server_Access;

      procedure Record_Failure
        (Occurrence : Ada.Exceptions.Exception_Occurrence)
      is
      begin
         if not Guard.Outcome.Failed then
            Ada.Exceptions.Save_Occurrence (Guard.Outcome.Failure, Occurrence);
            Guard.Outcome.Failed := True;
         end if;
      end Record_Failure;
   begin
      if not Guard.Outcome.Leader then
         return;
      end if;

      --  The exact generation remains allocated until its sole operation has
      --  observed Close_Wake and acknowledged release. Only then may the OS
      --  recycle the integer descriptor.
      Guard.Item.Controller.Await_Drained (Socket, Owner);
      begin
         Free (Guard.Item.TLS_Session);
      exception
         when others =>
            Guard.Item.TLS_Session := null;
            Guard.Outcome.Provider_Error := True;
      end;
      Guard.Item.TLS_Shutdown_Complete := False;
      --  Each remaining obligation is attempted independently and the first
      --  failure is reported. Close_Socket invalidates Socket even when close
      --  reports an error, and Finish_Close is the only operation that ends
      --  close leadership.
      if Sockets.Is_Open (Socket) then
         begin
            Sockets.Close_Socket (Socket);
         exception
            when Occurrence : others =>
               Record_Failure (Occurrence);
         end;
      end if;
      begin
         Guard.Item.Controller.Finish_Close (Guard.Outcome.Generation);
      exception
         when Occurrence : others =>
            Record_Failure (Occurrence);
      end;
      if Owner /= null then
         begin
            Owner.Release;
         exception
            when Occurrence : others =>
               Record_Failure (Occurrence);
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
     (Item          : not null Connection_Access;
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
         FD,
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

   --  A bound Connection borrows exactly the Server named by its
   --  discriminant, which the compiler has already checked outlives it.
   --  Admitting it through any other Server would reinstate an unchecked
   --  borrow, so reject that before any permit is reserved.
   procedure Check_Binding
     (Item    : Connection'Class;
      Manager : Server_Access) is
   begin
      if not Policy.Binding_Accepted
        (Bound   => Item.Manager /= null,
         Matches => Item.Manager = Manager)
      then
         raise Program_Error with
           "connection is bound to a different admission controller";
      end if;
   end Check_Binding;

   procedure Take
     (Manager : aliased in out Server;
      Socket  : in out Sockets.Socket_Type;
      Item    : in out Connection)
   is
      Guard : Admission_Guard (Manager'Unchecked_Access);
   begin
      Check_Binding (Item, Guard.Owner);
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

   procedure Connect
     (Manager : aliased in out Server;
      Server  : Sockets.Endpoint;
      Item    : in out Connection;
      Timeout : Duration := Infinite;
      Token   : access Cancellation_Token := null)
   is
      Started         : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Guard           : Admission_Guard (Manager'Unchecked_Access);
      Interrupts      : Interrupt_Set (1 .. 2);
      Interrupt_Count : Natural;
   begin
      Check_Binding (Item, Guard.Owner);
      if Is_Open (Item) then
         raise Program_Error with "connection already owns a socket";
      end if;
      Reserve_Interruptibly (Manager, Started, Timeout, Token, Guard);

      Sockets.Create_Socket
        (Guard.Socket, Family => Server.Family, Mode => Sockets.Socket_Stream);
      Interrupt_Sources
        (Guard.Owner, Token, Interrupts, Interrupt_Count);
      begin
         Sockets.Connect
           (Guard.Socket, Server, Remaining (Started, Timeout),
            Interrupts (1 .. Interrupt_Count));
      exception
         when Sockets.Operation_Interrupted =>
            raise Operation_Cancelled;
      end;
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
      Test_Barrier (18);
#end if;
      if Manager.Shutdown_Requested
        or else (Token /= null and then Token.Requested)
      then
         raise Operation_Cancelled;
      end if;
      Item.Controller.Adopt
        (Sockets.Native_Descriptor (Guard.Socket),
         Guard.Socket,
         Guard.Owner,
         Guard.Armed'Access);
   end Connect;

   procedure Complete_Managed_Connect
     (Item    : in out Connect_Operation;
      Result  : Flyology.Operations.Terminal_Outcome;
      Failure : Connect_Failure := No_Connect_Failure)
   is
   begin
      if Result /= Flyology.Operations.Succeeded then
         begin
            Release_Admission_Ownership
              (Item.State.Resources.Manager,
               Item.State.Resources.Armed,
               Item.State.Resources.Socket);
            Item.State.Resources.Manager := null;
         exception
            when others =>
               if not Item.State.Resources.Armed
                 and then not Sockets.Is_Open (Item.State.Resources.Socket)
               then
                  Item.State.Resources.Manager := null;
               end if;
               Item.State.Failure := Connect_Cleanup_Failure;
               Flyology.Operations.Drivers.Complete
                 (Item, Flyology.Operations.Failed);
               return;
         end;
      end if;
      Item.State.Failure := Failure;
      if Result = Flyology.Operations.Succeeded then
         Item.State.Phase := Connection_Ready;
      end if;
      Flyology.Operations.Drivers.Complete (Item, Result);
   end Complete_Managed_Connect;

   procedure Arm_Admission_Sources
     (Item       : in out Connect_Operation;
      Acquire_FD : Descriptor)
   is
      Token_FD  : Descriptor := Invalid_Descriptor;
      Cancelled : Boolean := False;
   begin
      if Item.State.Token = null then
         Flyology.Operations.Drivers.Arm_Readiness
           (Item, Acquire_FD, For_Write => False);
      else
         Item.State.Token.Wait_Source (Token_FD, Cancelled);
         if Cancelled then
            Complete_Managed_Connect
              (Item, Flyology.Operations.Cancelled);
            return;
         end if;
         Flyology.Operations.Drivers.Arm_Readiness
           (Item,
            (1 => (Descriptor => Acquire_FD, For_Write => False),
             2 => (Descriptor => Token_FD, For_Write => False)));
      end if;
   exception
      when others =>
         Complete_Managed_Connect
           (Item, Flyology.Operations.Failed, Connect_State_Failure);
   end Arm_Admission_Sources;

   procedure Start_Managed_Connect_Child
     (Item : in out Connect_Operation)
   is
      Interrupts : Interrupt_Set (1 .. 2);
      Count      : Natural;

      procedure Cancel_Unlinked_Child is
      begin
         if Flyology.Operations.Is_Active (Item.State.Child) then
            Flyology.Operations.Cancel (Item.State.Child);
         end if;
         if Flyology.Operations.Is_Terminal (Item.State.Child) then
            begin
               Sockets.Finish (Item.State.Child);
            exception
               when others =>
                  null;
            end;
            if Flyology.Operations.Id (Item.State.Child) /= 0 then
               Flyology.Operations.Release (Item.State.Child);
            end if;
         end if;
         Item.State.Child_Live := False;
      end Cancel_Unlinked_Child;
   begin
      Interrupt_Sources
        (Item.State.Resources.Manager, Item.State.Token, Interrupts, Count);
      Sockets.Create_Socket
        (Item.State.Resources.Socket,
         Family => Item.State.Destination.Family,
         Mode   => Sockets.Socket_Stream);
      Item.State.Phase := Waiting_For_Connect;

      --  Starting the child and publishing its continuation relation form one
      --  ownership transition. An abort before the relation is visible must
      --  not leave either an unowned child or a parent with no wait source.
      System.Soft_Links.Abort_Defer.all;
      begin
         Sockets.Connect
           (Socket     => Item.State.Resources.Socket'Access,
            Server     => Item.State.Destination,
            Timeout    => Remaining (Item.State.Started, Item.State.Timeout),
            Operation  => Item.State.Child,
            Interrupts => Interrupts (1 .. Count));
         Item.State.Child_Live := True;
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
         Test_Barrier (19);
#end if;
         Flyology.Operations.Continue_After (Item, Item.State.Child);
      exception
         when others =>
            Cancel_Unlinked_Child;
            System.Soft_Links.Abort_Undefer.all;
            raise;
      end;
      System.Soft_Links.Abort_Undefer.all;
   exception
      when Operation_Cancelled =>
         Complete_Managed_Connect
           (Item, Flyology.Operations.Cancelled);
      when Flyology.Operations.Capacity_Error =>
         Complete_Managed_Connect
           (Item, Flyology.Operations.Failed, Connect_Capacity_Failure);
      when Sockets.Socket_Error =>
         Complete_Managed_Connect
           (Item, Flyology.Operations.Failed, Connect_Socket_Failure);
      when others =>
         Complete_Managed_Connect
           (Item, Flyology.Operations.Failed, Connect_State_Failure);
   end Start_Managed_Connect_Child;

   procedure Try_Managed_Admission
     (Item : in out Connect_Operation)
   is
      Result      : Flyology.Capacity.Acquire_Result;
      Acquire_FD  : Descriptor;
      Can_Acquire : Boolean;
   begin
      Item.State.Resources.Manager.Try_Acquire
        (Result, Item.State.Resources.Armed'Access);
      case Result is
         when Flyology.Capacity.Permit_Acquired =>
            if Item.State.Resources.Manager.Shutdown_Requested
              or else
                (Item.State.Token /= null and then Item.State.Token.Requested)
            then
               Complete_Managed_Connect
                 (Item, Flyology.Operations.Cancelled);
            else
               Start_Managed_Connect_Child (Item);
            end if;
         when Flyology.Capacity.Gate_Closed =>
            Complete_Managed_Connect
              (Item, Flyology.Operations.Failed, Admission_Failure);
         when Flyology.Capacity.Gate_Full =>
            Item.State.Resources.Manager.Acquire_Wait_Source
              (Acquire_FD, Can_Acquire);
            if Can_Acquire then
               Flyology.Operations.Drivers.Reschedule (Item);
            else
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
               Test_Barrier (9);
#end if;
               Arm_Admission_Sources (Item, Acquire_FD);
            end if;
         when Flyology.Capacity.Acquire_Timed_Out =>
            Complete_Managed_Connect
              (Item, Flyology.Operations.Failed, Connect_State_Failure);
      end case;
   exception
      when others =>
         Complete_Managed_Connect
           (Item, Flyology.Operations.Failed, Connect_State_Failure);
   end Try_Managed_Admission;

   procedure Finish_Managed_Connect_Child
     (Item : in out Connect_Operation)
   is
      Succeeded   : Boolean := False;
      Interrupted : Boolean := False;
      Timed_Out   : Boolean := False;
      Socket_Failed : Boolean := False;
   begin
      --  Consuming the typed child detaches the parent's dependency; releasing
      --  the slot and clearing Child_Live must therefore be abort-atomic with
      --  that detach.
      System.Soft_Links.Abort_Defer.all;
      begin
         begin
            Sockets.Finish (Item.State.Child);
            Succeeded := True;
         exception
            when Sockets.Operation_Interrupted =>
               Interrupted := True;
            when Timeout_Error =>
               Timed_Out := True;
            when Sockets.Socket_Error =>
               Socket_Failed := True;
            when others =>
               null;
         end;
         Flyology.Operations.Release (Item.State.Child);
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
         Test_Barrier (20);
#end if;
         Item.State.Child_Live := False;
      exception
         when others =>
            System.Soft_Links.Abort_Undefer.all;
            raise;
      end;
      System.Soft_Links.Abort_Undefer.all;
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
      if Succeeded then
         Test_Barrier (18);
      end if;
#end if;

      if Item.State.Cancelling then
         Complete_Managed_Connect
           (Item,
            (if Item.State.Timed_Out
             then Flyology.Operations.Failed
             else Flyology.Operations.Cancelled),
            (if Item.State.Timed_Out
             then Connect_Timeout_Failure
             else No_Connect_Failure));
      elsif Interrupted
        or else Item.State.Resources.Manager.Shutdown_Requested
        or else
          (Item.State.Token /= null and then Item.State.Token.Requested)
      then
         Complete_Managed_Connect
           (Item, Flyology.Operations.Cancelled);
      elsif Timed_Out then
         Complete_Managed_Connect
           (Item, Flyology.Operations.Failed, Connect_Timeout_Failure);
      elsif Socket_Failed then
         Complete_Managed_Connect
           (Item, Flyology.Operations.Failed, Connect_Socket_Failure);
      elsif Succeeded then
         Complete_Managed_Connect
           (Item, Flyology.Operations.Succeeded);
      else
         Complete_Managed_Connect
           (Item, Flyology.Operations.Failed, Connect_State_Failure);
      end if;
   exception
      when others =>
         Item.State.Child_Live := False;
         Complete_Managed_Connect
           (Item, Flyology.Operations.Failed, Connect_State_Failure);
   end Finish_Managed_Connect_Child;

   overriding procedure Drive
     (Item  : in out Connect_Operation;
      Event : Flyology.Operations.Driver_Event)
   is
   begin
      if Event = Flyology.Operations.Deadline_Reached then
         Item.State.Cancelling := True;
         Item.State.Timed_Out := True;
         if Item.State.Child_Live then
            Flyology.Operations.Cancel (Item.State.Child);
         else
            Complete_Managed_Connect
              (Item, Flyology.Operations.Failed, Connect_Timeout_Failure);
         end if;
      elsif Event = Flyology.Operations.Dependency_Changed
        and then Item.State.Child_Live
      then
         Finish_Managed_Connect_Child (Item);
      elsif Item.State.Phase = Waiting_For_Admission
        and then Event in
          Flyology.Operations.Start_Operation |
          Flyology.Operations.Source_Ready |
          Flyology.Operations.Continue_Operation
      then
         Try_Managed_Admission (Item);
      else
         Complete_Managed_Connect
           (Item, Flyology.Operations.Failed, Connect_State_Failure);
      end if;
   exception
      when others =>
         if Item.State.Child_Live then
            Item.State.Cancelling := True;
            Flyology.Operations.Cancel (Item.State.Child);
         else
            Complete_Managed_Connect
              (Item, Flyology.Operations.Failed, Connect_State_Failure);
         end if;
   end Drive;

   overriding procedure Request_Cancellation
     (Item : in out Connect_Operation)
   is
   begin
      Item.State.Cancelling := True;
      if Item.State.Child_Live then
         Flyology.Operations.Cancel (Item.State.Child);
      else
         Complete_Managed_Connect
           (Item, Flyology.Operations.Cancelled);
      end if;
   exception
      when others =>
         if not Item.State.Child_Live then
            Complete_Managed_Connect
              (Item, Flyology.Operations.Failed, Connect_State_Failure);
         end if;
   end Request_Cancellation;

   procedure Start_Scoped_Managed_Connect
     (Operation : in out Connect_Operation;
      Manager   : not null access Server;
      Server    : Sockets.Endpoint;
      Timeout   : Duration;
      Token     : access Cancellation_Token)
   is
   begin
      if Operation.State.Resources.Armed
        or else Sockets.Is_Open (Operation.State.Resources.Socket)
        or else Operation.State.Child_Live
      then
         raise Flyology.Operations.Operation_Error with
           "managed connect operation still owns resources";
      end if;
      Operation.State.Resources.Manager := Manager.all'Unchecked_Access;
      Operation.State.Token :=
        (if Token = null then null else Token.all'Unchecked_Access);
      Operation.State.Destination := Server;
      Operation.State.Started := Ada.Real_Time.Clock;
      Operation.State.Timeout := Timeout;
      Operation.State.Phase := Waiting_For_Admission;
      Operation.State.Child_Live := False;
      Operation.State.Cancelling := False;
      Operation.State.Timed_Out := False;
      Operation.State.Failure := No_Connect_Failure;
      Flyology.Operations.Drivers.Start (Operation);
      if Timeout >= 0.0 then
         Flyology.Operations.Drivers.Arm_Deadline (Operation, Timeout);
      end if;
      Flyology.Operations.Drive
        (Flyology.Operations.Operation'Class (Operation),
         Flyology.Operations.Start_Operation);
   exception
      when others =>
         if Flyology.Operations.Is_Active (Operation) then
            Flyology.Operations.Cancel (Operation);
         end if;
         if Flyology.Operations.Is_Terminal (Operation) then
            Flyology.Operations.Consume (Operation);
         end if;
         raise;
   end Start_Scoped_Managed_Connect;

   function Connect
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Manager : not null access Server;
      Server  : Sockets.Endpoint;
      Timeout : Duration := Infinite;
      Token   : access Cancellation_Token := null) return Connect_Operation
   is
   begin
      return Result : Connect_Operation (Set) do
         Start_Scoped_Managed_Connect
           (Result, Manager, Server, Timeout, Token);
      end return;
   end Connect;

   procedure Connect
     (Manager   : not null access Server;
      Server    : Sockets.Endpoint;
      Timeout   : Duration := Infinite;
      Token     : access Cancellation_Token := null;
      Operation : in out Connect_Operation)
   is
   begin
      Start_Scoped_Managed_Connect
        (Operation, Manager, Server, Timeout, Token);
   end Connect;

   procedure Finish
     (Operation : in out Connect_Operation;
      Item      : in out Connection'Class)
   is
      Result : constant Flyology.Operations.Terminal_Outcome :=
        Flyology.Operations.Outcome (Operation);
      Failure : constant Connect_Failure := Operation.State.Failure;
   begin
      if Result = Flyology.Operations.Succeeded then
         Check_Binding (Item, Operation.State.Resources.Manager);
         if Is_Open (Item) then
            raise Program_Error with "connection target is open";
         end if;
         Item.Controller.Adopt
           (Sockets.Native_Descriptor (Operation.State.Resources.Socket),
            Operation.State.Resources.Socket,
            Operation.State.Resources.Manager,
            Operation.State.Resources.Armed'Access);
         Operation.State.Resources.Manager := null;
         Flyology.Operations.Consume (Operation);
         return;
      end if;

      Flyology.Operations.Consume (Operation);
      if Result = Flyology.Operations.Cancelled then
         raise Operation_Cancelled;
      end if;
      case Failure is
         when Admission_Failure =>
            raise Admission_Closed;
         when Connect_Timeout_Failure =>
            raise Timeout_Error with "managed connection attempt timed out";
         when Connect_Socket_Failure =>
            raise Sockets.Socket_Error with
              "managed connection socket attempt failed";
         when Connect_Capacity_Failure =>
            raise Flyology.Operations.Capacity_Error with
              "managed connection requires a child operation slot";
         when Connect_Cleanup_Failure =>
            raise Program_Error with "managed connection cleanup failed";
         when Connect_State_Failure | No_Connect_Failure =>
            raise Program_Error with "managed connection operation failed";
      end case;
   end Finish;

   procedure Upgrade_TLS
     (Item        : in out Connection;
      Backend     : in out TLS.Provider'Class;
      Side        : TLS.Role;
      Server_Name : String;
      Factory     : not null access function
        (FD : Descriptor) return TLS.Session_Access;
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
        (Item'Unchecked_Access, Started, Timeout, Token,
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
      Session_Hold.Value := Factory (FD);
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

   function Query_TLS_Session
     (Item  : in out Connection;
      Query : not null access function
        (Value : TLS.Session'Class) return String) return String
   is
      Started      : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Guard        : Operation_Guard (Item'Unchecked_Access);
      FD           : Descriptor;
      Close_Source : Descriptor;
      Owner        : Server_Access;
      Transport    : Transport_Kind;
   begin
      Acquire_Operation
        (Item'Unchecked_Access, Started, Infinite, null,
         FD, Guard, Close_Source, Owner, Transport);
      pragma Assert
        (FD >= 0 and then Close_Source >= 0 and then Owner /= null);
      if Transport /= TLS_Transport or else Item.TLS_Session = null then
         raise Program_Error with "connection transport does not use TLS";
      end if;
      return Query (Item.TLS_Session.all);
   end Query_TLS_Session;

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
        (Item'Unchecked_Access, Started, Timeout, Token,
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
      Check_Binding (Item, Guard.Owner);
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
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
      Test_Barrier (14);
#end if;
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
      Outcome : aliased Close_Outcome;
   begin
      --  Initialize takes close leadership and Finalize discharges it. Both
      --  controlled operations defer abort, so an aborted leader still hands
      --  the socket out, closes it, ends the close, and releases admission
      --  instead of stranding every later Close in Await_Closed.
      declare
         Guard : Close_Guard (Item'Unchecked_Access, Outcome'Access);
         pragma Unreferenced (Guard);
      begin
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
         if Outcome.Leader then
            Test_Barrier (17);
         end if;
#end if;
         null;
      end;

      case Policy.Classify_Close
        (Leader          => Outcome.Leader,
         Descriptor_Open => Outcome.FD >= 0,
         Cleanup_Failed  => Outcome.Failed,
         Provider_Failed => Outcome.Provider_Error)
      is
         when Policy.Close_Finished =>
            null;
         when Policy.Await_Leader =>
            Item.Controller.Await_Closed;
         when Policy.Raise_Cleanup_Failure =>
            Ada.Exceptions.Reraise_Occurrence (Outcome.Failure);
         when Policy.Raise_Provider_Error =>
            raise TLS.TLS_Error with
              "TLS provider session finalization failed";
      end case;
   end Close;

   function Is_Open (Item : Connection) return Boolean is
     (Item.Controller.Is_Open_State);

   procedure Arm_Connection_Sources
     (Item         : in out Connection_Operation'Class;
      Primary      : Descriptor;
      Primary_Write : Boolean;
      Lifecycle    : Descriptor)
   is
      Interrupts : Interrupt_Set (1 .. 2);
      Interrupt_Count : Natural;
      Sources : Flyology.Operations.Drivers.Readiness_Source_Array (1 .. 4);
      Count : Natural := 2;
   begin
      Interrupt_Sources
        (Item.Owner, Item.Token, Interrupts, Interrupt_Count);
      Sources (1) := (Descriptor => Primary, For_Write => Primary_Write);
      Sources (2) := (Descriptor => Lifecycle, For_Write => False);
      for Index in 1 .. Interrupt_Count loop
         Count := Count + 1;
         Sources (Count) :=
           (Descriptor => Interrupts (Index), For_Write => False);
      end loop;
      Flyology.Operations.Drivers.Arm_Readiness
        (Item, Sources (1 .. Count));
   end Arm_Connection_Sources;

   procedure Complete_Connection_Operation
     (Item   : in out Connection_Operation'Class;
      Result : Flyology.Operations.Terminal_Outcome)
   is
      Published : Flyology.Operations.Terminal_Outcome := Result;
      Close_After_Release : constant Boolean :=
        Item.Kind = Upgrade_TLS_Transport
        and then Item.Upgrade_Started
        and then Result /= Flyology.Operations.Succeeded;
   begin
      if Item.Pending_TLS_Session /= null then
         Free (Item.Pending_TLS_Session);
      end if;
      begin
         Release_Operation (Item.Guard);
      exception
         when others =>
            Item.Failure := Cleanup_Failure;
            Published := Flyology.Operations.Failed;
      end;
      if Close_After_Release and then Item.Guard.State = Unregistered then
         begin
            Close (Item.Item.all);
         exception
            --  Preserve the operation's provider/deadline/cancellation
            --  result. Close has already made ownership terminal before it
            --  can report a cleanup error, matching synchronous Upgrade.
            when others =>
               null;
         end;
      end if;
      Item.Upgrade_Started := False;
      Flyology.Operations.Drivers.Complete (Item, Published);
   end Complete_Connection_Operation;

   procedure Fail_Connection_Operation
     (Item   : in out Connection_Operation'Class;
      Reason : Scoped_IO_Failure) is
   begin
      Item.Failure := Reason;
      Complete_Connection_Operation (Item, Flyology.Operations.Failed);
   end Fail_Connection_Operation;

   procedure Drive_Transport (Item : in out Connection_Operation'Class) is
      Sending : constant Boolean := Item.Kind = Send_Complete;
      Data_First : constant Ada.Streams.Stream_Element_Offset :=
        (if Item.Kind = Upgrade_TLS_Transport then 1
         elsif Sending then Item.Send_Data.all'First
         else Item.Data.all'First);
      Data_Last : constant Ada.Streams.Stream_Element_Offset :=
        (if Item.Kind = Upgrade_TLS_Transport then 0
         elsif Sending then Item.Send_Data.all'Last
         else Item.Data.all'Last);
      First : constant Ada.Streams.Stream_Element_Offset :=
        (if Item.Kind = Receive_One then Data_First else Item.Cursor);
      Last : Ada.Streams.Stream_Element_Offset := First - 1;
      Status : TLS.Step_Status := TLS.Complete;
      Retry_Attempt : Natural := 0;

      procedure Arm_Transport (For_Write : Boolean) is
      begin
         Arm_Connection_Sources
           (Item, Item.FD, For_Write, Item.Close_Source);
      end Arm_Transport;

      procedure Complete_Progress is
      begin
         Item.Last := Last;
         if Item.Kind = Receive_One then
            Complete_Connection_Operation
              (Item, Flyology.Operations.Succeeded);
         elsif Last < First then
            Fail_Connection_Operation
              (Item,
               (if Sending
                then No_Progress_Failure
                else Peer_Closed_Failure));
         else
            Item.Cursor := Last + 1;
            if Item.Cursor > Data_Last then
               Complete_Connection_Operation
                 (Item, Flyology.Operations.Succeeded);
            elsif Item.Transport = TLS_Transport then
               Flyology.Operations.Drivers.Reschedule (Item);
            else
               Arm_Transport (Sending);
            end if;
         end if;
      end Complete_Progress;
   begin
      Check_TLS_Operation
        (Item.Item.all, Item.Guard.Generation, Item.Owner, Item.Token);
      if Item.Kind = Upgrade_TLS_Transport then
         if not Item.Upgrade_Started then
            if Item.Transport /= Plain_Transport
              or else Item.Pending_TLS_Session = null
              or else Item.Item.TLS_Session /= null
            then
               Fail_Connection_Operation (Item, State_Failure);
               return;
            end if;
            Item.Item.Controller.Begin_TLS_Upgrade
              (Item.Guard.Generation, Item.Upgrade_Started'Access);
            Item.Item.TLS_Session := Item.Pending_TLS_Session;
            Item.Pending_TLS_Session := null;
            Item.Item.TLS_Shutdown_Complete := False;
            Item.Transport := TLS_Upgrading;
         end if;

         Status := TLS.Handshake_Step (Item.Item.TLS_Session.all);
         case Status is
            when TLS.Complete =>
               Item.Item.Controller.Finish_TLS_Upgrade
                 (Item.Guard.Generation);
               Item.Transport := TLS_Transport;
               Item.Upgrade_Started := False;
               Complete_Connection_Operation
                 (Item, Flyology.Operations.Succeeded);
            when TLS.Want_Read =>
               Arm_Transport (False);
            when TLS.Want_Write =>
               Arm_Transport (True);
            when TLS.Peer_Closed | TLS.Failed =>
               Fail_Connection_Operation (Item, TLS_Failure);
         end case;
         return;
      end if;
      if First > Data_Last then
         Item.Last := Data_First - 1;
         Complete_Connection_Operation
           (Item, Flyology.Operations.Succeeded);
         return;
      end if;

      case Item.Transport is
         when TLS_Transport =>
            if Item.Item.TLS_Session = null then
               Fail_Connection_Operation (Item, State_Failure);
               return;
            elsif Sending then
               TLS_Driver.Send_Once
                 (Item.Item.TLS_Session.all,
                  Item.Send_Data.all (First .. Data_Last),
                  Last,
                  Status);
            else
               TLS_Driver.Receive_Once
                 (Item.Item.TLS_Session.all,
                  Item.Data.all (First .. Data_Last),
                  Last,
                  Status);
            end if;
            case Status is
               when TLS.Complete =>
                  Complete_Progress;
               when TLS.Want_Read =>
                  Arm_Transport (False);
               when TLS.Want_Write =>
                  Arm_Transport (True);
               when TLS.Peer_Closed =>
                  Item.Last := First - 1;
                  if Item.Kind = Receive_One then
                     Complete_Connection_Operation
                       (Item, Flyology.Operations.Succeeded);
                  else
                     Fail_Connection_Operation
                       (Item, TLS_Failure);
                  end if;
               when TLS.Failed =>
                  --  TLS_Driver raises before returning this status.
                  Fail_Connection_Operation (Item, TLS_Failure);
            end case;
         when Plain_Transport =>
            loop
               begin
                  if Sending then
                     Sockets.Send_Socket
                       (Item.Guard.Socket,
                        Item.Send_Data.all (First .. Data_Last),
                        Last);
                  else
                     Sockets.Receive_Socket
                       (Item.Guard.Socket,
                        Item.Data.all (First .. Data_Last),
                        Last);
                  end if;
                  exit;
               exception
                  when Occurrence : Sockets.Socket_Error =>
                     case Sockets.Resolve_Exception (Occurrence) is
                        when Sockets.Resource_Temporarily_Unavailable =>
                           Arm_Transport (Sending);
                           return;
                        when Sockets.No_Buffer_Space_Available =>
                           if Sending then
                              Arm_Transport (True);
                           else
                              Fail_Connection_Operation
                                (Item, Socket_Failure);
                           end if;
                           return;
                        when Sockets.Interrupted_System_Call =>
                           Retry_Attempt := Retry_Attempt + 1;
                           if not Flyology.Socket_Policy.Retry_IO_Immediately
                             (Retry_Attempt)
                           then
                              Arm_Transport (Sending);
                              return;
                           end if;
                        when others =>
                           Fail_Connection_Operation (Item, Socket_Failure);
                           return;
                     end case;
               end;
            end loop;
            Complete_Progress;
         when No_Transport | TLS_Upgrading =>
            Fail_Connection_Operation (Item, State_Failure);
      end case;
   exception
      when Operation_Cancelled =>
         Complete_Connection_Operation
           (Item, Flyology.Operations.Cancelled);
      when TLS.TLS_Error =>
         Fail_Connection_Operation (Item, TLS_Failure);
      when Sockets.Socket_Error =>
         Fail_Connection_Operation (Item, Socket_Failure);
      when others =>
         Fail_Connection_Operation (Item, State_Failure);
   end Drive_Transport;

   procedure Try_Scoped_Acquire
     (Item : in out Connection_Operation'Class)
   is
      Result : Lease_Result;
   begin
      --  Observe persistent lifecycle state before attempting the lease. The
      --  same sources are armed below under their respective protected-state
      --  recheck protocols, so no transition can be lost in between.
      declare
         Interrupts : Interrupt_Set (1 .. 2);
         Count : Natural;
      begin
         Interrupt_Sources (Item.Owner, Item.Token, Interrupts, Count);
      end;
      Item.Item.Controller.Try_Acquire
        (Item.Guard.Generation,
         Item.Guard.State'Access,
         Result,
         Item.FD,
         Item.Close_Source,
         Item.Guard.Socket,
         Item.Owner,
         Item.Transport);
      case Result is
         when Lease_Busy =>
            Arm_Connection_Sources
              (Item,
               Item.Lease_Source,
               False,
               Item.Initial_Close_Source);
         when Lease_Cancelled =>
            Complete_Connection_Operation
              (Item, Flyology.Operations.Cancelled);
         when Lease_Acquired =>
            Sockets.Prepare (Item.Guard.Socket);
            Drive_Transport (Item);
      end case;
   exception
      when Operation_Cancelled =>
         Complete_Connection_Operation
           (Item, Flyology.Operations.Cancelled);
      when Sockets.Socket_Error =>
         Fail_Connection_Operation (Item, Socket_Failure);
      when others =>
         Fail_Connection_Operation (Item, State_Failure);
   end Try_Scoped_Acquire;

   overriding procedure Drive
     (Item  : in out Connection_Operation;
      Event : Flyology.Operations.Driver_Event)
   is
   begin
      if Event = Flyology.Operations.Deadline_Reached then
         Fail_Connection_Operation (Item, Deadline_Failure);
      elsif Event = Flyology.Operations.Start_Operation then
         begin
            Item.Item.Controller.Start_Operation
              (Item.Guard.Generation'Access,
               Item.Guard.State'Access,
               Item.FD,
               Item.Lease_Source,
               Item.Initial_Close_Source,
               Item.Owner);
            Try_Scoped_Acquire (Item);
         exception
            when Operation_Cancelled =>
               Complete_Connection_Operation
                 (Item, Flyology.Operations.Cancelled);
            when others =>
               Fail_Connection_Operation (Item, State_Failure);
         end;
      elsif Event in
        Flyology.Operations.Source_Ready |
        Flyology.Operations.Continue_Operation
      then
         if Item.Guard.State = Registered then
            Try_Scoped_Acquire (Item);
         elsif Item.Guard.State = Acquired then
            Drive_Transport (Item);
         else
            Fail_Connection_Operation (Item, State_Failure);
         end if;
      else
         Fail_Connection_Operation (Item, State_Failure);
      end if;
   end Drive;

   overriding procedure Request_Cancellation
     (Item : in out Connection_Operation) is
   begin
      Complete_Connection_Operation
        (Item, Flyology.Operations.Cancelled);
   exception
      when others =>
         --  Complete_Connection_Operation retains cleanup failure itself;
         --  cancellation must never propagate out of the provider primitive.
         null;
   end Request_Cancellation;

   procedure Start_Scoped_IO
     (Operation  : in out Connection_Operation'Class;
      Item       : not null access Connection'Class;
      Kind       : Scoped_IO_Kind;
      Data       : not null access Ada.Streams.Stream_Element_Array;
      Timeout    : Duration;
      Token      : access Cancellation_Token)
   is
   begin
      if Operation.Guard.State /= Unregistered then
         raise Flyology.Operations.Operation_Error with
           "connection operation still owns a lease";
      end if;
      Operation.Item := Item.all'Unchecked_Access;
      Operation.Token :=
        (if Token = null then null else Token.all'Unchecked_Access);
      Operation.Guard.Item := Item.all'Unchecked_Access;
      Operation.Kind := Kind;
      Operation.Data := Data.all'Unchecked_Access;
      Operation.Send_Data := null;
      Operation.Cursor := Data.all'First;
      Operation.Last := Data.all'First - 1;
      Operation.Lease_Source := Invalid_Descriptor;
      Operation.Initial_Close_Source := Invalid_Descriptor;
      Operation.Close_Source := Invalid_Descriptor;
      Operation.Owner := null;
      Operation.FD := Invalid_Descriptor;
      Operation.Transport := No_Transport;
      Operation.Pending_TLS_Session := null;
      Operation.Upgrade_Started := False;
      Operation.Failure := No_Failure;
      Flyology.Operations.Drivers.Start (Operation);
      if Timeout >= 0.0 then
         Flyology.Operations.Drivers.Arm_Deadline (Operation, Timeout);
      end if;
      Flyology.Operations.Drive
        (Flyology.Operations.Operation'Class (Operation),
         Flyology.Operations.Start_Operation);
   exception
      when others =>
         if Flyology.Operations.Is_Active (Operation) then
            Flyology.Operations.Cancel (Operation);
         end if;
         if Flyology.Operations.Is_Terminal (Operation) then
            Flyology.Operations.Consume (Operation);
         end if;
         raise;
   end Start_Scoped_IO;

   procedure Start_Scoped_Send
     (Operation  : in out Send_All_Operation;
      Item       : not null access Connection'Class;
      Data       : not null access constant Ada.Streams.Stream_Element_Array;
      Timeout    : Duration;
      Token      : access Cancellation_Token)
   is
   begin
      if Operation.Guard.State /= Unregistered then
         raise Flyology.Operations.Operation_Error with
           "connection operation still owns a lease";
      end if;
      Operation.Item := Item.all'Unchecked_Access;
      Operation.Token :=
        (if Token = null then null else Token.all'Unchecked_Access);
      Operation.Guard.Item := Item.all'Unchecked_Access;
      Operation.Kind := Send_Complete;
      Operation.Data := null;
      Operation.Send_Data := Data.all'Unchecked_Access;
      Operation.Cursor := Data.all'First;
      Operation.Last := Data.all'First - 1;
      Operation.Lease_Source := Invalid_Descriptor;
      Operation.Initial_Close_Source := Invalid_Descriptor;
      Operation.Close_Source := Invalid_Descriptor;
      Operation.Owner := null;
      Operation.FD := Invalid_Descriptor;
      Operation.Transport := No_Transport;
      Operation.Pending_TLS_Session := null;
      Operation.Upgrade_Started := False;
      Operation.Failure := No_Failure;
      Flyology.Operations.Drivers.Start (Operation);
      if Timeout >= 0.0 then
         Flyology.Operations.Drivers.Arm_Deadline (Operation, Timeout);
      end if;
      Flyology.Operations.Drive
        (Flyology.Operations.Operation'Class (Operation),
         Flyology.Operations.Start_Operation);
   exception
      when others =>
         if Flyology.Operations.Is_Active (Operation) then
            Flyology.Operations.Cancel (Operation);
         end if;
         if Flyology.Operations.Is_Terminal (Operation) then
            Flyology.Operations.Consume (Operation);
         end if;
         raise;
   end Start_Scoped_Send;

   procedure Start_Scoped_TLS_Upgrade
     (Operation : in out Connection_Operation'Class;
      Item      : not null access Connection'Class;
      Factory   : not null access function
        (FD : Flyology.IO.Descriptor) return Flyology.IO.TLS.Session_Access;
      Timeout   : Duration;
      Token     : access Cancellation_Token)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   begin
      if Operation.Guard.State /= Unregistered then
         raise Flyology.Operations.Operation_Error with
           "connection operation still owns a lease";
      end if;
      Operation.Item := Item.all'Unchecked_Access;
      Operation.Token :=
        (if Token = null then null else Token.all'Unchecked_Access);
      Operation.Guard.Item := Item.all'Unchecked_Access;
      Operation.Kind := Upgrade_TLS_Transport;
      Operation.Data := null;
      Operation.Send_Data := null;
      Operation.Cursor := 1;
      Operation.Last := 0;
      Operation.Lease_Source := Invalid_Descriptor;
      Operation.Initial_Close_Source := Invalid_Descriptor;
      Operation.Close_Source := Invalid_Descriptor;
      Operation.Owner := null;
      Operation.FD := Invalid_Descriptor;
      Operation.Transport := No_Transport;
      Operation.Pending_TLS_Session := null;
      Operation.Upgrade_Started := False;
      Operation.Failure := No_Failure;

      Flyology.Operations.Drivers.Start (Operation);
      if Timeout >= 0.0 then
         Flyology.Operations.Drivers.Arm_Deadline (Operation, Timeout);
      end if;

      begin
         --  Registration gives the eager provider factory a generation-safe
         --  descriptor without retaining its nested callback past this call.
         Operation.Item.Controller.Start_Operation
           (Operation.Guard.Generation'Access,
            Operation.Guard.State'Access,
            Operation.FD,
            Operation.Lease_Source,
            Operation.Initial_Close_Source,
            Operation.Owner);
         Disable_SIGPIPE (Interfaces.C.int (Operation.FD));
         Operation.Pending_TLS_Session := Factory (Operation.FD);
         if Operation.Pending_TLS_Session = null then
            Fail_Connection_Operation (Operation, TLS_Failure);
            return;
         elsif Timeout > 0.0
           and then Remaining (Started, Timeout) = 0.0
         then
            Fail_Connection_Operation (Operation, Deadline_Failure);
            return;
         end if;
         Try_Scoped_Acquire (Operation);
      exception
         when Operation_Cancelled =>
            Complete_Connection_Operation
              (Operation, Flyology.Operations.Cancelled);
         when TLS.TLS_Error =>
            Fail_Connection_Operation (Operation, TLS_Failure);
         when Sockets.Socket_Error =>
            Fail_Connection_Operation (Operation, Socket_Failure);
         when others =>
            Fail_Connection_Operation (Operation, State_Failure);
      end;
   exception
      when others =>
         if Flyology.Operations.Is_Active (Operation) then
            Flyology.Operations.Cancel (Operation);
         end if;
         if Flyology.Operations.Is_Terminal (Operation) then
            Flyology.Operations.Consume (Operation);
         end if;
         raise;
   end Start_Scoped_TLS_Upgrade;

   function Receive
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null access Connection'Class;
      Data    : not null access Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite;
      Token   : access Cancellation_Token := null) return Receive_Operation
   is
   begin
      return Result : Receive_Operation (Set) do
         Start_Scoped_IO
           (Result, Item, Receive_One, Data, Timeout, Token);
      end return;
   end Receive;

   procedure Receive
     (Item      : not null access Connection'Class;
      Data      : not null access Ada.Streams.Stream_Element_Array;
      Timeout   : Duration := Infinite;
      Token     : access Cancellation_Token := null;
      Operation : in out Receive_Operation) is
   begin
      Start_Scoped_IO
        (Operation, Item, Receive_One, Data, Timeout, Token);
   end Receive;

   function Receive_Exactly
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null access Connection'Class;
      Data    : not null access Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite;
      Token   : access Cancellation_Token := null)
      return Receive_Exactly_Operation
   is
   begin
      return Result : Receive_Exactly_Operation (Set) do
         Start_Scoped_IO
           (Result, Item, Receive_Complete, Data, Timeout, Token);
      end return;
   end Receive_Exactly;

   procedure Receive_Exactly
     (Item      : not null access Connection'Class;
      Data      : not null access Ada.Streams.Stream_Element_Array;
      Timeout   : Duration := Infinite;
      Token     : access Cancellation_Token := null;
      Operation : in out Receive_Exactly_Operation) is
   begin
      Start_Scoped_IO
        (Operation, Item, Receive_Complete, Data, Timeout, Token);
   end Receive_Exactly;

   function Send_All
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null access Connection'Class;
      Data    : not null access constant Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite;
      Token   : access Cancellation_Token := null) return Send_All_Operation
   is
   begin
      return Result : Send_All_Operation (Set) do
         Start_Scoped_Send (Result, Item, Data, Timeout, Token);
      end return;
   end Send_All;

   procedure Send_All
     (Item      : not null access Connection'Class;
      Data      : not null access constant Ada.Streams.Stream_Element_Array;
      Timeout   : Duration := Infinite;
      Token     : access Cancellation_Token := null;
      Operation : in out Send_All_Operation) is
   begin
      Start_Scoped_Send (Operation, Item, Data, Timeout, Token);
   end Send_All;

   procedure Finish_Connection_Operation
     (Item : in out Connection_Operation'Class)
   is
      Result : constant Flyology.Operations.Terminal_Outcome :=
        Flyology.Operations.Outcome (Item);
      Failure : constant Scoped_IO_Failure := Item.Failure;
   begin
      Flyology.Operations.Consume (Item);
      case Result is
         when Flyology.Operations.Succeeded =>
            null;
         when Flyology.Operations.Cancelled =>
            raise Operation_Cancelled;
         when Flyology.Operations.Failed =>
            case Failure is
               when Deadline_Failure =>
                  raise Timeout_Error with "connection operation timed out";
               when Socket_Failure =>
                  raise Sockets.Socket_Error with
                    "scoped connection socket operation failed";
               when TLS_Failure =>
                  raise TLS.TLS_Error with
                    "scoped connection TLS operation failed";
               when Peer_Closed_Failure =>
                  raise Device_Error with
                    "connection closed while receiving";
               when No_Progress_Failure =>
                  raise Device_Error with
                    "connection closed while sending";
               when State_Failure =>
                  raise Program_Error with
                    "scoped connection state is invalid";
               when Cleanup_Failure =>
                  raise Program_Error with
                    "scoped connection cleanup failed";
               when No_Failure =>
                  raise Program_Error with
                    "scoped connection operation failed";
            end case;
      end case;
   end Finish_Connection_Operation;

   procedure Finish
     (Operation : in out Receive_Operation;
      Last      : out Ada.Streams.Stream_Element_Offset)
   is
      Saved_Last : constant Ada.Streams.Stream_Element_Offset :=
        Operation.Last;
   begin
      Finish_Connection_Operation (Operation);
      Last := Saved_Last;
   end Finish;

   procedure Finish (Operation : in out Receive_Exactly_Operation) is
   begin
      Finish_Connection_Operation (Operation);
   end Finish;

   procedure Finish (Operation : in out Send_All_Operation) is
   begin
      Finish_Connection_Operation (Operation);
   end Finish;

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
        (Item'Unchecked_Access, Started, Timeout, Token,
         FD, Guard, Interrupts (1), Owner, Transport);
      pragma Assert
        (FD = Flyology.IO.Sockets.Native_Descriptor (Guard.Socket));
      if Transport = TLS_Transport then
         if Item.TLS_Session = null then
            raise Program_Error with "TLS transport has no provider session";
         end if;
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
         declare
            Limit : constant Interfaces.C.int :=
              Test_Receive_Limit (Interfaces.C.int (Data'Length));
         begin
            TLS_Driver.Receive
              (Item.TLS_Session.all,
               Data
                 (Data'First ..
                    Data'First +
                      Ada.Streams.Stream_Element_Offset (Limit) - 1),
               Last, Check'Access, Await'Access);
         end;
#else
         TLS_Driver.Receive
           (Item.TLS_Session.all, Data, Last, Check'Access, Await'Access);
#end if;
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
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
         declare
            Limit : constant Interfaces.C.int :=
              Test_Receive_Limit (Interfaces.C.int (Data'Length));
         begin
            Flyology.IO.Sockets.Receive
              (Guard.Socket,
               Data
                 (Data'First ..
                    Data'First +
                      Ada.Streams.Stream_Element_Offset (Limit) - 1),
               Last, Remaining (Started, Timeout),
               Interrupts (1 .. Interrupt_Count + 1));
         end;
#else
         Flyology.IO.Sockets.Receive
           (Guard.Socket, Data, Last, Remaining (Started, Timeout),
            Interrupts (1 .. Interrupt_Count + 1));
#end if;
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
        (Item'Unchecked_Access, Started, Timeout, Token,
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
        (Item'Unchecked_Access, Started, Timeout, Token,
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
