with Ada.Unchecked_Deallocation;
with Flyology.Time_Math;
with Flyology.Connection_Policy;
with Flyology.IO.TLS_Driver;
with Flyology.Operations.Drivers;
with Flyology.TLS_Policy;
#if FLYOLOGY_TLS_TEST_HOOKS then
with Flyology.TLS_Test_Hooks;
#end if;
with Interfaces.C;

package body Flyology.IO.TLS is

   procedure Free_Provider is new Ada.Unchecked_Deallocation (Provider'Class, Provider_Access);

   procedure Release (Item : in out Provider_Access) is
   begin
      Free_Provider (Item);
   end Release;
   package Sockets renames Flyology.IO.Sockets;
   package Policy renames Flyology.TLS_Policy;
   package Lease_Policy renames Flyology.Connection_Policy;

   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;
   use type Descriptor;
   use type Flyology.Operations.Driver_Event;

   procedure Free is new Ada.Unchecked_Deallocation (Session'Class, Session_Access);

   --  GNAT implements this as SO_NOSIGPIPE on Darwin and a no-op where send
   --  flags provide the equivalent process-safety behavior.
   procedure Disable_SIGPIPE (Socket : Interfaces.C.int);
   pragma Import (C, Disable_SIGPIPE, "__gnat_disable_sigpipe");

#if FLYOLOGY_TLS_TEST_HOOKS then
   --  Test-only barriers that widen the Take ownership-transfer window so a
   --  test can deliver an abort inside it. Production preprocessing removes
   --  this call site and excludes the Ada state package from the build.
   procedure Test_Barrier (Point : Integer) is
      Did_Arrive : Boolean;
   begin
      Flyology.TLS_Test_Hooks.Arrive (Point, Did_Arrive);
      if Did_Arrive then
         while not Flyology.TLS_Test_Hooks.Released (Point) loop
            delay 0.0;
         end loop;
      end if;
   end Test_Barrier;
#end if;

   type Close_Outcome is record
      FD               : Descriptor := Invalid_Descriptor;
      Generation       : Descriptor_Generation := 0;
      Leader           : Boolean := False;
      Provider_Error   : Boolean := False;
      Socket_Error     : Boolean := False;
      Controller_Error : Boolean := False;
   end record;

   type Close_Guard
     (Item    : not null access Connection;
      Outcome : not null access Close_Outcome)
   is new Ada.Finalization.Limited_Controlled with null record;

   overriding
   procedure Initialize (Guard : in out Close_Guard);
   overriding
   procedure Finalize (Guard : in out Close_Guard);

   protected body Descriptor_Controller is
      procedure Adopt (FD : Descriptor) is
      begin
         if FD < 0 or else Current_FD >= 0 or else Active or else Close_In_Progress then
            raise Program_Error with "TLS descriptor controller already owns a resource";
         end if;
         Wake_Sources.Ensure (Close_Wake);
         Wake_Sources.Ensure (Lease_Wake);
         Current_FD := FD;
         Current_Generation := Current_Generation + 1;
      end Adopt;

      procedure Start_Operation
        (Generation   : not null access Descriptor_Generation;
         State        : not null access Operation_State;
         FD           : out Descriptor;
         Lease_Source : out Descriptor;
         Close_Source : out Descriptor) is
      begin
         if State.all /= Unregistered then
            raise Program_Error with "TLS operation already registered";
         elsif Current_FD < 0 or else Close_In_Progress then
            raise Program_Error with "TLS connection is not open";
         elsif Started_Operations = Natural'Last then
            raise Program_Error with "too many TLS operations";
         end if;
         Started_Operations := Lease_Policy.Started_After_Register (Started_Operations);
         Generation.all := Current_Generation;
         FD := Current_FD;
         Lease_Source := Wake_Sources.Descriptor (Lease_Wake);
         Close_Source := Wake_Sources.Descriptor (Close_Wake);
         State.all := Registered;
      end Start_Operation;

      procedure Try_Acquire
        (Expected_Generation : Descriptor_Generation;
         State               : not null access Operation_State;
         Result              : out Lease_Result;
         FD                  : in out Descriptor;
         Close_Source        : in out Descriptor) is
      begin
         if State.all /= Registered then
            raise Program_Error with "TLS operation is not registered";
         end if;
         case Lease_Policy.Classify_Acquire
                (Generation_Matches => Expected_Generation = Current_Generation,
                 Resources_Open     => Current_FD >= 0,
                 Closing            => Close_In_Progress,
                 Active             => Active)
         is
            when Lease_Policy.Cancel_Lease   =>
               if Started_Operations = 0 then
                  raise Program_Error with "missing TLS operation";
               end if;
               Started_Operations := Lease_Policy.Started_After_Release (Started_Operations);
               State.all := Unregistered;
               Result := Lease_Cancelled;
               return;

            when Lease_Policy.Wait_For_Lease =>
               Result := Lease_Busy;
               return;

            when Lease_Policy.Acquire_Lease  =>
               null;
         end case;
         if Lease_Signalled then
            Wake_Sources.Consume (Lease_Wake);
            Lease_Signalled := False;
         end if;
         Active := True;
         FD := Current_FD;
         Close_Source := Wake_Sources.Descriptor (Close_Wake);
         State.all := Acquired;
         Result := Lease_Acquired;
      end Try_Acquire;

      procedure Abandon_Operation
        (Generation : Descriptor_Generation; State : not null access Operation_State)
      is
         pragma Unreferenced (Generation);
      begin
         if State.all /= Registered or else Started_Operations = 0 then
            raise Program_Error with "stale TLS operation withdrawal";
         end if;
         Started_Operations := Lease_Policy.Started_After_Release (Started_Operations);
         State.all := Unregistered;
         if Lease_Policy.Should_Wake_Next (Active, Close_In_Progress, Started_Operations, Lease_Signalled)
         then
            Wake_Sources.Signal (Lease_Wake);
            Lease_Signalled := True;
         end if;
      end Abandon_Operation;

      procedure Check_Operation (Generation : Descriptor_Generation) is
      begin
         if not Active or else Generation /= Current_Generation then
            raise Program_Error with "stale TLS operation";
         elsif Close_In_Progress then
            raise Operation_Cancelled with "TLS connection closed during its operation";
         end if;
      end Check_Operation;

      procedure Release (Generation : Descriptor_Generation; State : not null access Operation_State) is
      begin
         if State.all /= Acquired
           or else not Active
           or else Generation /= Current_Generation
           or else Started_Operations = 0
         then
            raise Program_Error with "stale TLS operation release";
         end if;
         Active := False;
         Started_Operations := Lease_Policy.Started_After_Release (Started_Operations);
         State.all := Unregistered;
         if Lease_Policy.Should_Wake_Next (Active, Close_In_Progress, Started_Operations, Lease_Signalled)
         then
            Wake_Sources.Signal (Lease_Wake);
            Lease_Signalled := True;
         end if;
      end Release;

      procedure Begin_Close
        (FD : out Descriptor; Generation : out Descriptor_Generation; Leader : out Boolean) is
      begin
         FD := Current_FD;
         Generation := Current_Generation;
         Leader := Policy.Close_Leader (Current_FD >= 0, Close_In_Progress);
         if Leader then
            if Started_Operations > 0 then
               Wake_Sources.Signal (Close_Wake);
            end if;
            --  Publish the close only after the wake is known to be usable. If
            --  Signal raises, a later Close can retry instead of waiting on a
            --  state that no caller can finish.
            Close_In_Progress := True;
         end if;
      end Begin_Close;

      entry Await_Drained when not Active and then Started_Operations = 0 is
      begin
         null;
      end Await_Drained;

      entry Await_Closed when not Close_In_Progress is
      begin
         null;
      end Await_Closed;

      procedure Finish_Close (Generation : Descriptor_Generation) is
      begin
         if not Policy.Finish_Close_Allowed
                  (Close_In_Progress, Active or else Started_Operations /= 0, Generation = Current_Generation)
         then
            raise Program_Error with "stale TLS close completion";
         end if;
         Current_FD := Invalid_Descriptor;
         begin
            Wake_Sources.Release (Lease_Wake);
            Wake_Sources.Release (Close_Wake);
         exception
            when others =>
               Close_In_Progress := False;
               raise;
         end;
         Lease_Signalled := False;
         Close_In_Progress := False;
      end Finish_Close;

      function Is_Open_State return Boolean
      is (Policy.Is_Open (Current_FD >= 0, Close_In_Progress));

      function Close_Requested return Boolean
      is (Close_In_Progress);
   end Descriptor_Controller;

   overriding
   procedure Initialize (Guard : in out Close_Guard) is
   begin
      Guard.Item.Controller.Begin_Close (Guard.Outcome.FD, Guard.Outcome.Generation, Guard.Outcome.Leader);
   end Initialize;

   procedure Release_Operation (Guard : in out Operation_Guard) is
   begin
      case Guard.State is
         when Unregistered =>
            null;

         when Registered   =>
            Guard.Item.Controller.Abandon_Operation (Guard.Generation, Guard.State'Access);

         when Acquired     =>
            Guard.Item.Controller.Release (Guard.Generation, Guard.State'Access);
      end case;
      if Guard.State = Unregistered then
         Guard.Item := null;
      end if;
   end Release_Operation;

   overriding
   procedure Finalize (Guard : in out Operation_Guard) is
   begin
      Release_Operation (Guard);
   end Finalize;

   function Driver_Remaining (State : Driver_State) return Duration
   is (if State.Deadline < 0.0
       then Infinite
       else
         Time_Math.Remaining
           (State.Deadline, Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - State.Started)));

   procedure Release_Driver (State : in out Driver_State) is
      procedure Clear is
      begin
         State.Item := null;
         State.Token := null;
         State.FD := Invalid_Descriptor;
         State.Lease_Source := Invalid_Descriptor;
         State.Close_Source := Invalid_Descriptor;
         State.Deadline := Infinite;
      end Clear;
   begin
      begin
         Release_Operation (State.Guard);
      exception
         when others =>
            if State.Guard.State = Unregistered then
               Clear;
            end if;
            raise;
      end;
      if State.Guard.State = Unregistered then
         Clear;
      end if;
   end Release_Driver;

   procedure Check_Driver (State : in out Driver_State) is
   begin
      if State.Item = null or else State.Guard.State /= Acquired then
         raise Program_Error with "TLS driver is not acquired";
      end if;
      State.Item.Controller.Check_Operation (State.Guard.Generation);
      if State.Token /= null and then State.Token.Requested then
         raise Operation_Cancelled;
      end if;
   end Check_Driver;

   procedure Poll_Driver (State : in out Driver_State; Result : out Lease_Result) is
   begin
      if State.Item = null or else State.Guard.State /= Registered then
         raise Program_Error with "TLS driver is not awaiting acquisition";
      elsif State.Token /= null and then State.Token.Requested then
         raise Operation_Cancelled;
      end if;
      State.Item.Controller.Try_Acquire
        (State.Guard.Generation, State.Guard.State'Access, Result, State.FD, State.Close_Source);
      if Result = Lease_Acquired and then State.Item.Session = null then
         raise Program_Error with "TLS connection has no provider session";
      elsif Result = Lease_Busy and then State.Deadline >= 0.0 and then Driver_Remaining (State) = 0.0 then
         raise Timeout_Error with "TLS driver timed out";
      end if;
   end Poll_Driver;

   procedure Start_Driver
     (State   : in out Driver_State;
      Item    : not null access Connection'Class;
      Result  : out Lease_Result;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token) is
   begin
      if State.Guard.State /= Unregistered then
         raise Program_Error with "TLS driver is already engaged";
      end if;
      begin
         State.Item := Item.all'Unchecked_Access;
         State.Token := (if Token = null then null else Token.all'Unchecked_Access);
         State.Guard.Item := Item.all'Unchecked_Access;
         State.Started := Ada.Real_Time.Clock;
         State.Deadline := Timeout;
         State.Item.Controller.Start_Operation
           (State.Guard.Generation'Access,
            State.Guard.State'Access,
            State.FD,
            State.Lease_Source,
            State.Close_Source);
         Poll_Driver (State, Result);
      exception
         when others =>
            Release_Driver (State);
            raise;
      end;
   end Start_Driver;

   procedure Append_Driver_Token
     (State   : in out Driver_State;
      Sources : in out Flyology.Operations.Drivers.Readiness_Source_Array;
      Count   : in out Natural)
   is
      FD        : Descriptor;
      Cancelled : Boolean;
   begin
      if State.Token /= null then
         State.Token.Wait_Source (FD, Cancelled);
         if Cancelled then
            raise Operation_Cancelled;
         end if;
         Count := Count + 1;
         Sources (Count) := (Descriptor => FD, For_Write => False);
      end if;
   end Append_Driver_Token;

   procedure Arm_Driver_Acquisition
     (State : in out Driver_State; Operation : in out Flyology.Operations.Operation'Class)
   is
      Sources : Flyology.Operations.Drivers.Readiness_Source_Array (1 .. 3);
      Count   : Natural := 2;
   begin
      if State.Guard.State /= Registered then
         raise Program_Error with "TLS driver is not awaiting acquisition";
      end if;
      Sources (1) := (Descriptor => State.Lease_Source, For_Write => False);
      Sources (2) := (Descriptor => State.Close_Source, For_Write => False);
      Append_Driver_Token (State, Sources, Count);
      Flyology.Operations.Drivers.Arm_Readiness (Operation, Sources (1 .. Count));
   end Arm_Driver_Acquisition;

   procedure Arm_Driver_Transport
     (State     : in out Driver_State;
      Operation : in out Flyology.Operations.Operation'Class;
      Status    : Step_Status)
   is
      Sources : Flyology.Operations.Drivers.Readiness_Source_Array (1 .. 3);
      Count   : Natural := 2;
   begin
      if State.Guard.State /= Acquired or else Status not in Want_Read | Want_Write then
         raise Program_Error with "invalid TLS readiness request";
      end if;
      Sources (1) := (Descriptor => State.FD, For_Write => Status = Want_Write);
      Sources (2) := (Descriptor => State.Close_Source, For_Write => False);
      Append_Driver_Token (State, Sources, Count);
      Flyology.Operations.Drivers.Arm_Readiness (Operation, Sources (1 .. Count));
   end Arm_Driver_Transport;

   procedure Arm_Driver_Deadline
     (State : in out Driver_State; Operation : in out Flyology.Operations.Operation'Class) is
   begin
      if State.Guard.State = Unregistered then
         raise Program_Error with "TLS driver is not engaged";
      elsif State.Deadline >= 0.0 then
         Flyology.Operations.Drivers.Arm_Deadline (Operation, Driver_Remaining (State));
      end if;
   end Arm_Driver_Deadline;

   overriding
   procedure Finalize (Guard : in out Close_Guard) is
   begin
      if not Guard.Outcome.Leader then
         return;
      end if;

      Guard.Item.Controller.Await_Drained;
      begin
         Free (Guard.Item.Session);
      exception
         when others =>
            --  A provider finalizer is contractually non-raising. Keep the
            --  remaining close cleanup inside this abort-deferred finalizer.
            Guard.Item.Session := null;
            Guard.Outcome.Provider_Error := True;
      end;
      begin
         if Sockets.Is_Open (Guard.Item.Socket) then
            Sockets.Close_Socket (Guard.Item.Socket);
         end if;
      exception
         when Sockets.Socket_Error =>
            Guard.Outcome.Socket_Error := True;
         when others =>
            Guard.Outcome.Controller_Error := True;
      end;
      begin
         Guard.Item.Controller.Finish_Close (Guard.Outcome.Generation);
      exception
         when others =>
            Guard.Outcome.Controller_Error := True;
      end;
   end Finalize;

   function Remaining (Started : Ada.Real_Time.Time; Timeout : Duration) return Duration is
   begin
      if Timeout < 0.0 then
         return Infinite;
      end if;
      return Time_Math.Remaining (Timeout, Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started));
   end Remaining;

   procedure Await_Ready
     (FD           : Descriptor;
      Status       : Step_Status;
      Started      : Ada.Real_Time.Time;
      Timeout      : Duration;
      Close_Source : Descriptor;
      Token        : access Flyology.Cancellation.Token)
   is
      Token_Source    : Descriptor := Invalid_Descriptor;
      Cancelled       : Boolean := False;
      Interrupts      : Interrupt_Set (1 .. 2);
      Interrupt_Count : Positive := 1;
      Outcome         : Wait_Outcome;
   begin
      Interrupts (1) := Close_Source;
      if Token /= null then
         Token.Wait_Source (Token_Source, Cancelled);
         if Cancelled then
            raise Operation_Cancelled;
         end if;
         Interrupt_Count := 2;
         Interrupts (2) := Token_Source;
      end if;

      Outcome :=
        Wait_Interruptibly
          (FD,
           (if Status = Want_Read then For_Read else For_Write),
           Remaining (Started, Timeout),
           Interrupts (1 .. Interrupt_Count));
      case Outcome is
         when Ready       =>
            null;

         when Timed_Out   =>
            raise Timeout_Error with "TLS operation timed out";

         when Interrupted =>
            raise Operation_Cancelled;
      end case;
   end Await_Ready;

   procedure Check_Cancelled
     (Item       : in out Connection;
      Generation : Descriptor_Generation;
      Token      : access Flyology.Cancellation.Token) is
   begin
      Item.Controller.Check_Operation (Generation);
      if Token /= null and then Token.Requested then
         raise Operation_Cancelled;
      end if;
   end Check_Cancelled;

   procedure Acquire_Operation
     (Item         : in out Connection;
      Started      : Ada.Real_Time.Time;
      Timeout      : Duration;
      Token        : access Flyology.Cancellation.Token;
      FD           : out Descriptor;
      Guard        : in out Operation_Guard;
      Close_Source : out Descriptor)
   is
      Left         : Duration;
      Result       : Lease_Result;
      Lease_Source : Descriptor;
      Interrupts   : Interrupt_Set (1 .. 2);
      Count        : Positive := 1;
      Cancelled    : Boolean := False;
      Outcome      : Wait_Outcome;
   begin
      Guard.Item := Item'Unchecked_Access;
      Item.Controller.Start_Operation
        (Guard.Generation'Access, Guard.State'Access, FD, Lease_Source, Close_Source);
      Interrupts (1) := Close_Source;
      if Token /= null then
         Token.Wait_Source (Interrupts (2), Cancelled);
         if Cancelled then
            raise Operation_Cancelled;
         end if;
         Count := 2;
      end if;

      loop
         if Token /= null and then Token.Requested then
            raise Operation_Cancelled;
         end if;
         Left := Remaining (Started, Timeout);
         Item.Controller.Try_Acquire (Guard.Generation, Guard.State'Access, Result, FD, Close_Source);
         case Result is
            when Lease_Acquired  =>
               return;

            when Lease_Cancelled =>
               raise Operation_Cancelled;

            when Lease_Busy      =>
               Outcome := Wait_Interruptibly (Lease_Source, For_Read, Left, Interrupts (1 .. Count));
               case Outcome is
                  when Ready       =>
                     null;

                  when Timed_Out   =>
                     raise Timeout_Error with "TLS operation timed out waiting for the connection";

                  when Interrupted =>
                     raise Operation_Cancelled;
               end case;
         end case;
      end loop;
   end Acquire_Operation;

   procedure Take_With_Factory
     (Backend     : in out Provider'Class;
      Socket      : in out Sockets.Socket_Type;
      Side        : Role;
      Server_Name : String;
      Factory     : not null access function (FD : Descriptor) return Session_Access;
      Item        : in out Connection)
   is
      FD          : Descriptor := Invalid_Descriptor;
      Transferred : Boolean := False;

      --  Creating the session and transferring the descriptor, the session,
      --  and the socket must not be observable in a half-completed state. Ada
      --  task abort is not an exception, so a handler cannot undo it; RM 9.8
      --  instead defers abort for the whole of a controlled object's
      --  Initialize. Running the transfer there makes an abort deliverable
      --  only before the session exists or after Item owns everything, which
      --  is the same technique Close uses for its two close transitions.
      type Transfer_Guard is new Ada.Finalization.Limited_Controlled with null record;

      overriding
      procedure Initialize (Guard : in out Transfer_Guard);

      overriding
      procedure Initialize (Guard : in out Transfer_Guard) is
         pragma Unreferenced (Guard);
         New_Session : Session_Access := null;
      begin
         New_Session := Factory (FD);
#if FLYOLOGY_TLS_TEST_HOOKS then
         Test_Barrier (0);
#end if;
         if New_Session = null then
            return;
         end if;

         begin
            Item.Controller.Adopt (FD);
         exception
            when others =>
               Free (New_Session);
               raise;
         end;
#if FLYOLOGY_TLS_TEST_HOOKS then
         Test_Barrier (1);
#end if;
         --  Nothing below can fail: Move only rejects an open target, and the
         --  caller precondition above rejects one. The connection therefore
         --  never keeps a descriptor it cannot close.
         Sockets.Move (Socket, Item.Socket);
         Item.Session := New_Session;
         Transferred := True;
      end Initialize;
   begin
      --  Item retains a socket whenever the controller still owns a
      --  descriptor or a previous close failed to release one. Refusing both
      --  keeps the transfer below unable to fail after it adopts.
      case Policy.Classify_Take
             (Socket_Open        => Sockets.Is_Open (Socket),
              Connection_Retains => Is_Open (Item) or else Sockets.Is_Open (Item.Socket),
              Client_Side        => Side = Client,
              Server_Name_Given  => Server_Name'Length /= 0,
              Provider_Available => Is_Available (Backend))
      is
         when Policy.Transfer_Ownership            =>
            null;

         when Policy.Reject_Closed_Socket          =>
            raise Program_Error with "cannot give TLS a closed socket";

         when Policy.Reject_Retained_Socket        =>
            raise Program_Error with "TLS connection already owns a socket";

         when Policy.Reject_Missing_Server_Name    =>
            raise Program_Error with "TLS client requires a server name";

         when Policy.Reject_Unexpected_Server_Name =>
            raise Program_Error with "TLS server does not accept a server name";

         when Policy.Reject_Unavailable_Provider   =>
            raise TLS_Error with Name (Backend) & " provider is unavailable";
      end case;

      Flyology.IO.Sockets.Prepare (Socket);
      FD := Flyology.IO.Sockets.Native_Descriptor (Socket);
      Disable_SIGPIPE (Interfaces.C.int (FD));

      declare
         Guard : Transfer_Guard;
         pragma Unreferenced (Guard);
      begin
         null;
      end;

      if not Transferred then
         raise TLS_Error with Name (Backend) & " returned no TLS session";
      end if;
   end Take_With_Factory;

   procedure Take
     (Backend     : in out Provider'Class;
      Socket      : in out Sockets.Socket_Type;
      Side        : Role;
      Server_Name : String;
      Item        : in out Connection)
   is
      function Factory (FD : Descriptor) return Session_Access
      is (Create_Session (Backend, FD, Side, Server_Name));
   begin
      Take_With_Factory (Backend, Socket, Side, Server_Name, Factory'Access, Item);
   end Take;

   function Query_Session
     (Item : in out Connection; Query : not null access function (Value : Session'Class) return String)
      return String
   is
      Started      : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      FD           : Descriptor;
      Guard        : Operation_Guard;
      Close_Source : Descriptor;
   begin
      Acquire_Operation (Item, Started, Infinite, null, FD, Guard, Close_Source);
      pragma Assert (FD >= 0 and then Close_Source >= 0);
      return Query (Item.Session.all);
   end Query_Session;

   procedure Handshake
     (Item    : in out Connection;
      Timeout : Duration := Infinite;
      Token   : access Flyology.Cancellation.Token := null)
   is
      Started      : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      FD           : Descriptor;
      Guard        : Operation_Guard;
      Close_Source : Descriptor;
      procedure Check is
      begin
         Check_Cancelled (Item, Guard.Generation, Token);
      end Check;
      procedure Await (Status : Step_Status) is
      begin
         Await_Ready (FD, Status, Started, Timeout, Close_Source, Token);
      end Await;
   begin
      Acquire_Operation (Item, Started, Timeout, Token, FD, Guard, Close_Source);
      TLS_Driver.Handshake (Item.Session.all, Check'Access, Await'Access);
   end Handshake;

   procedure Receive
     (Item    : in out Connection;
      Data    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration := Infinite;
      Token   : access Flyology.Cancellation.Token := null)
   is
      Started      : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      FD           : Descriptor;
      Guard        : Operation_Guard;
      Close_Source : Descriptor;
      procedure Check is
      begin
         Check_Cancelled (Item, Guard.Generation, Token);
      end Check;
      procedure Await (Status : Step_Status) is
      begin
         Await_Ready (FD, Status, Started, Timeout, Close_Source, Token);
      end Await;
   begin
      Acquire_Operation (Item, Started, Timeout, Token, FD, Guard, Close_Source);
      TLS_Driver.Receive (Item.Session.all, Data, Last, Check'Access, Await'Access);
   end Receive;

   procedure Receive_Exactly
     (Item    : in out Connection;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite;
      Token   : access Flyology.Cancellation.Token := null)
   is
      Started      : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      FD           : Descriptor;
      Guard        : Operation_Guard;
      Close_Source : Descriptor;
      procedure Check is
      begin
         Check_Cancelled (Item, Guard.Generation, Token);
      end Check;
      procedure Await (Status : Step_Status) is
      begin
         Await_Ready (FD, Status, Started, Timeout, Close_Source, Token);
      end Await;
   begin
      Acquire_Operation (Item, Started, Timeout, Token, FD, Guard, Close_Source);
      TLS_Driver.Receive_Exactly (Item.Session.all, Data, Check'Access, Await'Access);
   end Receive_Exactly;

   procedure Send_All
     (Item    : in out Connection;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite;
      Token   : access Flyology.Cancellation.Token := null)
   is
      Started      : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      FD           : Descriptor;
      Guard        : Operation_Guard;
      Close_Source : Descriptor;
      procedure Check is
      begin
         Check_Cancelled (Item, Guard.Generation, Token);
      end Check;
      procedure Await (Status : Step_Status) is
      begin
         Await_Ready (FD, Status, Started, Timeout, Close_Source, Token);
      end Await;
   begin
      Acquire_Operation (Item, Started, Timeout, Token, FD, Guard, Close_Source);
      TLS_Driver.Send_All (Item.Session.all, Data, Check'Access, Await'Access);
   end Send_All;

   procedure Shutdown
     (Item    : in out Connection;
      Timeout : Duration := Infinite;
      Token   : access Flyology.Cancellation.Token := null)
   is
      Started      : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      FD           : Descriptor;
      Guard        : Operation_Guard;
      Close_Source : Descriptor;
      procedure Check is
      begin
         Check_Cancelled (Item, Guard.Generation, Token);
      end Check;
      procedure Await (Status : Step_Status) is
      begin
         Await_Ready (FD, Status, Started, Timeout, Close_Source, Token);
      end Await;
   begin
      Acquire_Operation (Item, Started, Timeout, Token, FD, Guard, Close_Source);
      TLS_Driver.Shutdown (Item.Session.all, Check'Access, Await'Access);
   end Shutdown;

   procedure Save_Scoped_Failure
     (Item : in out Connection_Operation'Class; Occurrence : Ada.Exceptions.Exception_Occurrence) is
   begin
      Ada.Exceptions.Save_Occurrence (Item.Failure, Occurrence);
      Item.Has_Failure := True;
   end Save_Scoped_Failure;

   procedure Complete_Scoped
     (Item : in out Connection_Operation'Class; Result : Flyology.Operations.Terminal_Outcome)
   is
      Published : Flyology.Operations.Terminal_Outcome := Result;
   begin
      begin
         Release_Driver (Item.State);
      exception
         when Occurrence : others =>
            if not Item.Has_Failure then
               Save_Scoped_Failure (Item, Occurrence);
            end if;
            Published := Flyology.Operations.Failed;
      end;
      Flyology.Operations.Drivers.Complete (Item, Published);
   end Complete_Scoped;

   procedure Drive_Scoped_Provider (Item : in out Connection_Operation'Class) is
      Status : Step_Status := Complete;
      First  : Ada.Streams.Stream_Element_Offset := Item.Cursor;
      Last   : Ada.Streams.Stream_Element_Offset := Item.Cursor;
   begin
      Check_Driver (Item.State);
      case Item.Kind is
         when Handshake_IO                   =>
            TLS_Driver.Handshake_Once (Item.State.Item.Session.all, Status);

         when Shutdown_IO                    =>
            TLS_Driver.Shutdown_Once (Item.State.Item.Session.all, Status);

         when Receive_One | Receive_Complete =>
            if Item.Data.all'Length = 0 then
               Item.Last := Item.Data.all'First - 1;
               Complete_Scoped (Item, Flyology.Operations.Succeeded);
               return;
            end if;
            First := (if Item.Kind = Receive_One then Item.Data.all'First else Item.Cursor);
            TLS_Driver.Receive_Once
              (Item.State.Item.Session.all, Item.Data.all (First .. Item.Data.all'Last), Last, Status);

         when Send_Complete                  =>
            if Item.Send_Data.all'Length = 0 then
               Complete_Scoped (Item, Flyology.Operations.Succeeded);
               return;
            end if;
            TLS_Driver.Send_Once
              (Item.State.Item.Session.all,
               Item.Send_Data.all (First .. Item.Send_Data.all'Last),
               Last,
               Status);
      end case;

      case Status is
         when Want_Read | Want_Write =>
            Arm_Driver_Transport (Item.State, Item, Status);

         when Peer_Closed            =>
            if Item.Kind = Receive_One then
               Item.Last := First - 1;
               Complete_Scoped (Item, Flyology.Operations.Succeeded);
            else
               raise TLS_Error with "TLS peer closed before operation completed";
            end if;

         when Failed                 =>
            raise Program_Error with "TLS provider failure was not raised";

         when Complete               =>
            case Item.Kind is
               when Handshake_IO | Shutdown_IO =>
                  Complete_Scoped (Item, Flyology.Operations.Succeeded);

               when Receive_One                =>
                  Item.Last := Last;
                  Complete_Scoped (Item, Flyology.Operations.Succeeded);

               when Receive_Complete           =>
                  Item.Last := Last;
                  if Last = Item.Data.all'Last then
                     Complete_Scoped (Item, Flyology.Operations.Succeeded);
                  else
                     Item.Cursor := Last + 1;
                     Flyology.Operations.Drivers.Reschedule (Item);
                  end if;

               when Send_Complete              =>
                  if Last = Item.Send_Data.all'Last then
                     Complete_Scoped (Item, Flyology.Operations.Succeeded);
                  else
                     Item.Cursor := Last + 1;
                     Flyology.Operations.Drivers.Reschedule (Item);
                  end if;
            end case;
      end case;
   end Drive_Scoped_Provider;

   procedure Continue_Scoped_Acquisition (Item : in out Connection_Operation'Class) is
      Result : Lease_Result;
   begin
      Poll_Driver (Item.State, Result);
      case Result is
         when Lease_Busy      =>
            Arm_Driver_Acquisition (Item.State, Item);

         when Lease_Cancelled =>
            Complete_Scoped (Item, Flyology.Operations.Cancelled);

         when Lease_Acquired  =>
            Drive_Scoped_Provider (Item);
      end case;
   end Continue_Scoped_Acquisition;

   overriding
   procedure Drive (Item : in out Connection_Operation; Event : Flyology.Operations.Driver_Event) is
      Result : Lease_Result;
   begin
      if Event = Flyology.Operations.Deadline_Reached then
         raise Timeout_Error with "TLS operation timed out";
      elsif Event = Flyology.Operations.Start_Operation then
         Start_Driver (Item.State, Item.State.Item, Result, Item.State.Deadline, Item.State.Token);
         case Result is
            when Lease_Busy      =>
               Arm_Driver_Deadline (Item.State, Item);
               Arm_Driver_Acquisition (Item.State, Item);

            when Lease_Cancelled =>
               Complete_Scoped (Item, Flyology.Operations.Cancelled);

            when Lease_Acquired  =>
               Arm_Driver_Deadline (Item.State, Item);
               Drive_Scoped_Provider (Item);
         end case;
      elsif Event in Flyology.Operations.Source_Ready | Flyology.Operations.Continue_Operation then
         if Item.State.Guard.State = Registered then
            Continue_Scoped_Acquisition (Item);
         elsif Item.State.Guard.State = Acquired then
            Drive_Scoped_Provider (Item);
         else
            raise Program_Error with "TLS operation has no driver state";
         end if;
      else
         raise Program_Error with "invalid TLS operation event";
      end if;
   exception
      when Operation_Cancelled =>
         Complete_Scoped (Item, Flyology.Operations.Cancelled);
      when Occurrence : others =>
         Save_Scoped_Failure (Item, Occurrence);
         Complete_Scoped (Item, Flyology.Operations.Failed);
   end Drive;

   overriding
   procedure Request_Cancellation (Item : in out Connection_Operation) is
   begin
      Complete_Scoped (Item, Flyology.Operations.Cancelled);
   exception
      when others =>
         null;
   end Request_Cancellation;

   procedure Launch_Scoped (Operation : in out Connection_Operation'Class) is
   begin
      Flyology.Operations.Drivers.Start (Operation);
      Flyology.Operations.Drive
        (Flyology.Operations.Operation'Class (Operation), Flyology.Operations.Start_Operation);
   exception
      when others =>
         if Flyology.Operations.Is_Active (Operation) then
            Flyology.Operations.Cancel (Operation);
         end if;
         if Flyology.Operations.Is_Terminal (Operation) then
            Flyology.Operations.Consume (Operation);
         end if;
         raise;
   end Launch_Scoped;

   procedure Start_Scoped
     (Operation : in out Connection_Operation'Class;
      Item      : not null access Connection'Class;
      Kind      : Scoped_TLS_Kind;
      Timeout   : Duration;
      Token     : access Flyology.Cancellation.Token) is
   begin
      if Operation.State.Guard.State /= Unregistered then
         raise Flyology.Operations.Operation_Error with "TLS operation still owns its connection lease";
      end if;
      Operation.State.Item := Item.all'Unchecked_Access;
      Operation.State.Token := (if Token = null then null else Token.all'Unchecked_Access);
      Operation.State.Deadline := Timeout;
      Operation.Kind := Kind;
      Operation.Data := null;
      Operation.Send_Data := null;
      Operation.Cursor := 1;
      Operation.Last := 0;
      Operation.Has_Failure := False;
      Launch_Scoped (Operation);
   end Start_Scoped;

   procedure Start_Scoped_Receive
     (Operation : in out Connection_Operation'Class;
      Item      : not null access Connection'Class;
      Kind      : Scoped_TLS_Kind;
      Data      : not null access Ada.Streams.Stream_Element_Array;
      Timeout   : Duration;
      Token     : access Flyology.Cancellation.Token) is
   begin
      if Operation.State.Guard.State /= Unregistered then
         raise Flyology.Operations.Operation_Error with "TLS operation still owns its connection lease";
      end if;
      Operation.State.Item := Item.all'Unchecked_Access;
      Operation.State.Token := (if Token = null then null else Token.all'Unchecked_Access);
      Operation.State.Deadline := Timeout;
      Operation.Kind := Kind;
      Operation.Data := Data.all'Unchecked_Access;
      Operation.Send_Data := null;
      Operation.Cursor := Data.all'First;
      Operation.Last := Data.all'First - 1;
      Operation.Has_Failure := False;
      Launch_Scoped (Operation);
   end Start_Scoped_Receive;

   procedure Start_Scoped_Send
     (Operation : in out Send_All_Operation;
      Item      : not null access Connection'Class;
      Data      : not null access constant Ada.Streams.Stream_Element_Array;
      Timeout   : Duration;
      Token     : access Flyology.Cancellation.Token) is
   begin
      if Operation.State.Guard.State /= Unregistered then
         raise Flyology.Operations.Operation_Error with "TLS operation still owns its connection lease";
      end if;
      Operation.State.Item := Item.all'Unchecked_Access;
      Operation.State.Token := (if Token = null then null else Token.all'Unchecked_Access);
      Operation.State.Deadline := Timeout;
      Operation.Kind := Send_Complete;
      Operation.Data := null;
      Operation.Send_Data := Data.all'Unchecked_Access;
      Operation.Cursor := Data.all'First;
      Operation.Last := Data.all'First;
      Operation.Has_Failure := False;
      Launch_Scoped (Operation);
   end Start_Scoped_Send;

   function Handshake
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null access Connection'Class;
      Timeout : Duration := Infinite;
      Token   : access Flyology.Cancellation.Token := null) return Handshake_Operation is
   begin
      return Result : Handshake_Operation (Set) do
         Start_Scoped (Result, Item, Handshake_IO, Timeout, Token);
      end return;
   end Handshake;

   procedure Handshake
     (Item      : not null access Connection'Class;
      Timeout   : Duration := Infinite;
      Token     : access Flyology.Cancellation.Token := null;
      Operation : in out Handshake_Operation) is
   begin
      Start_Scoped (Operation, Item, Handshake_IO, Timeout, Token);
   end Handshake;

   function Receive
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null access Connection'Class;
      Data    : not null access Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite;
      Token   : access Flyology.Cancellation.Token := null) return Receive_Operation is
   begin
      return Result : Receive_Operation (Set) do
         Start_Scoped_Receive (Result, Item, Receive_One, Data, Timeout, Token);
      end return;
   end Receive;

   procedure Receive
     (Item      : not null access Connection'Class;
      Data      : not null access Ada.Streams.Stream_Element_Array;
      Timeout   : Duration := Infinite;
      Token     : access Flyology.Cancellation.Token := null;
      Operation : in out Receive_Operation) is
   begin
      Start_Scoped_Receive (Operation, Item, Receive_One, Data, Timeout, Token);
   end Receive;

   function Receive_Exactly
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null access Connection'Class;
      Data    : not null access Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite;
      Token   : access Flyology.Cancellation.Token := null) return Receive_Exactly_Operation is
   begin
      return Result : Receive_Exactly_Operation (Set) do
         Start_Scoped_Receive (Result, Item, Receive_Complete, Data, Timeout, Token);
      end return;
   end Receive_Exactly;

   procedure Receive_Exactly
     (Item      : not null access Connection'Class;
      Data      : not null access Ada.Streams.Stream_Element_Array;
      Timeout   : Duration := Infinite;
      Token     : access Flyology.Cancellation.Token := null;
      Operation : in out Receive_Exactly_Operation) is
   begin
      Start_Scoped_Receive (Operation, Item, Receive_Complete, Data, Timeout, Token);
   end Receive_Exactly;

   function Send_All
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null access Connection'Class;
      Data    : not null access constant Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite;
      Token   : access Flyology.Cancellation.Token := null) return Send_All_Operation is
   begin
      return Result : Send_All_Operation (Set) do
         Start_Scoped_Send (Result, Item, Data, Timeout, Token);
      end return;
   end Send_All;

   procedure Send_All
     (Item      : not null access Connection'Class;
      Data      : not null access constant Ada.Streams.Stream_Element_Array;
      Timeout   : Duration := Infinite;
      Token     : access Flyology.Cancellation.Token := null;
      Operation : in out Send_All_Operation) is
   begin
      Start_Scoped_Send (Operation, Item, Data, Timeout, Token);
   end Send_All;

   function Shutdown
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null access Connection'Class;
      Timeout : Duration := Infinite;
      Token   : access Flyology.Cancellation.Token := null) return Shutdown_Operation is
   begin
      return Result : Shutdown_Operation (Set) do
         Start_Scoped (Result, Item, Shutdown_IO, Timeout, Token);
      end return;
   end Shutdown;

   procedure Shutdown
     (Item      : not null access Connection'Class;
      Timeout   : Duration := Infinite;
      Token     : access Flyology.Cancellation.Token := null;
      Operation : in out Shutdown_Operation) is
   begin
      Start_Scoped (Operation, Item, Shutdown_IO, Timeout, Token);
   end Shutdown;

   procedure Finish_Scoped (Operation : in out Connection_Operation'Class) is
      Result : constant Flyology.Operations.Terminal_Outcome := Flyology.Operations.Outcome (Operation);
      Failed : constant Boolean := Operation.Has_Failure;
   begin
      Flyology.Operations.Consume (Operation);
      case Result is
         when Flyology.Operations.Succeeded =>
            null;

         when Flyology.Operations.Cancelled =>
            raise Operation_Cancelled;

         when Flyology.Operations.Failed    =>
            if Failed then
               Ada.Exceptions.Reraise_Occurrence (Operation.Failure);
            else
               raise Program_Error with "TLS operation failed";
            end if;
      end case;
   end Finish_Scoped;

   procedure Finish (Operation : in out Handshake_Operation) is
   begin
      Finish_Scoped (Operation);
   end Finish;

   procedure Finish (Operation : in out Receive_Operation; Last : out Ada.Streams.Stream_Element_Offset) is
      Saved_Last : constant Ada.Streams.Stream_Element_Offset := Operation.Last;
   begin
      Finish_Scoped (Operation);
      Last := Saved_Last;
   end Finish;

   procedure Finish (Operation : in out Receive_Exactly_Operation) is
   begin
      Finish_Scoped (Operation);
   end Finish;

   procedure Finish (Operation : in out Send_All_Operation) is
   begin
      Finish_Scoped (Operation);
   end Finish;

   procedure Finish (Operation : in out Shutdown_Operation) is
   begin
      Finish_Scoped (Operation);
   end Finish;

   procedure Close (Item : in out Connection) is
      Outcome : aliased Close_Outcome;
   begin
      --  Initialize publishes the leader state and Finalize performs all
      --  leader cleanup. Both controlled hooks are abort-deferred, so an
      --  abort cannot strand Close_In_Progress between those two transitions.
      declare
         Guard : Close_Guard (Item'Unchecked_Access, Outcome'Access);
         pragma Unreferenced (Guard);
      begin
         null;
      end;

      if not Outcome.Leader then
         if Outcome.FD >= 0 then
            Item.Controller.Await_Closed;
         end if;
         return;
      end if;

      if Outcome.Provider_Error then
         raise TLS_Error with "TLS provider session finalization failed";
      elsif Outcome.Socket_Error then
         raise Sockets.Socket_Error with "TLS socket close failed";
      elsif Outcome.Controller_Error then
         raise Program_Error with "TLS connection controller cleanup failed";
      end if;
   end Close;

   function Is_Open (Item : Connection) return Boolean
   is (Item.Controller.Is_Open_State);

   overriding
   procedure Finalize (Item : in out Connection) is
   begin
      begin
         Close (Item);
      exception
         when others =>
            null;
      end;
   end Finalize;

end Flyology.IO.TLS;
