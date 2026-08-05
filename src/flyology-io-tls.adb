with Ada.Real_Time;
with Ada.Unchecked_Deallocation;
with Flyology.Time_Math;
with Flyology.TLS_Policy;
with Interfaces.C;

package body Flyology.IO.TLS is

   procedure Free_Provider is new Ada.Unchecked_Deallocation
     (Provider'Class, Provider_Access);

   procedure Release (Item : in out Provider_Access) is
   begin
      Free_Provider (Item);
   end Release;
   package Sockets renames Flyology.IO.Sockets;
   package Policy renames Flyology.TLS_Policy;

   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;
   use type Descriptor;

   procedure Free is new Ada.Unchecked_Deallocation
     (Session'Class, Session_Access);

   --  GNAT implements this as SO_NOSIGPIPE on Darwin and a no-op where send
   --  flags provide the equivalent process-safety behavior.
   procedure Disable_SIGPIPE (Socket : Interfaces.C.int);
   pragma Import (C, Disable_SIGPIPE, "__gnat_disable_sigpipe");

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

   type Operation_Guard (Item : not null access Connection) is
     new Ada.Finalization.Limited_Controlled with record
      Generation : aliased Descriptor_Generation := 0;
      Armed      : aliased Boolean := False;
   end record;

   overriding procedure Initialize (Guard : in out Close_Guard);
   overriding procedure Finalize (Guard : in out Close_Guard);
   overriding procedure Finalize (Guard : in out Operation_Guard);

   protected body Descriptor_Controller is
      procedure Adopt (FD : Descriptor) is
      begin
         if FD < 0
           or else Current_FD >= 0
           or else Active
           or else Close_In_Progress
         then
            raise Program_Error with
              "TLS descriptor controller already owns a resource";
         end if;
         Wake_Sources.Ensure (Close_Wake);
         Current_FD := FD;
         Current_Generation := Current_Generation + 1;
      end Adopt;

      entry Acquire
        (Expected     : Descriptor_Generation;
         FD           : out Descriptor;
         Generation   : not null access Descriptor_Generation;
         Armed        : not null access Boolean;
         Close_Source : out Descriptor;
         Result       : out Acquire_Result)
        when not Active
      is
      begin
         FD := Invalid_Descriptor;
         Generation.all := Current_Generation;
         Armed.all := False;
         Close_Source := Invalid_Descriptor;
         case Policy.Classify_Acquire
           (Generation_Matches => Expected = Current_Generation,
            Closing            => Close_In_Progress,
            Descriptor_Open    => Current_FD >= 0)
         is
            when Policy.Reject_Replaced =>
               Result := Replaced;
            when Policy.Reject_Closing =>
               Result := Closing;
            when Policy.Reject_Closed =>
               Result := Closed;
            when Policy.Acquire_Operation =>
               Result := Acquired;
               Active := True;
               FD := Current_FD;
               Close_Source := Wake_Sources.Descriptor (Close_Wake);
               --  Arm cleanup while abort is still deferred by the protected
               --  action. The end of this entry call is an abort completion
               --  point, so arming after return would leave an ownership gap.
               Armed.all := True;
         end case;
      end Acquire;

      procedure Release (Generation : Descriptor_Generation) is
      begin
         if not Active or else Generation /= Current_Generation then
            raise Program_Error with "stale TLS operation release";
         end if;
         Active := False;
      end Release;

      procedure Begin_Close
        (FD         : out Descriptor;
         Generation : out Descriptor_Generation;
         Leader     : out Boolean)
      is
      begin
         FD := Current_FD;
         Generation := Current_Generation;
         Leader := Policy.Close_Leader
           (Current_FD >= 0, Close_In_Progress);
         if Leader then
            if Active then
               Wake_Sources.Signal (Close_Wake);
            end if;
            --  Publish the close only after the wake is known to be usable. If
            --  Signal raises, a later Close can retry instead of waiting on a
            --  state that no caller can finish.
            Close_In_Progress := True;
         end if;
      end Begin_Close;

      entry Await_Drained when not Active is
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
           (Close_In_Progress,
            Active,
            Generation = Current_Generation)
         then
            raise Program_Error with "stale TLS close completion";
         end if;
         Current_FD := Invalid_Descriptor;
         begin
            Wake_Sources.Release (Close_Wake);
         exception
            when others =>
               Close_In_Progress := False;
               raise;
         end;
         Close_In_Progress := False;
      end Finish_Close;

      procedure Snapshot_Acquisition
        (State      : out Acquire_Result;
         Generation : out Descriptor_Generation)
      is
      begin
         Generation := Current_Generation;
         case Policy.Classify_Acquire
           (Generation_Matches => True,
            Closing            => Close_In_Progress,
            Descriptor_Open    => Current_FD >= 0)
         is
            when Policy.Reject_Closing =>
               State := Closing;
            when Policy.Reject_Closed =>
               State := Closed;
            when Policy.Acquire_Operation =>
               State := Acquired;
            when Policy.Reject_Replaced =>
               raise Program_Error with "invalid TLS acquisition snapshot";
         end case;
      end Snapshot_Acquisition;

      function Is_Open_State return Boolean is
        (Policy.Is_Open (Current_FD >= 0, Close_In_Progress));

      function Close_Requested return Boolean is (Close_In_Progress);
   end Descriptor_Controller;

   overriding procedure Initialize (Guard : in out Close_Guard) is
   begin
      Guard.Item.Controller.Begin_Close
        (Guard.Outcome.FD,
         Guard.Outcome.Generation,
         Guard.Outcome.Leader);
   end Initialize;

   overriding procedure Finalize (Guard : in out Operation_Guard) is
   begin
      if Guard.Armed then
         Guard.Item.Controller.Release (Guard.Generation);
         Guard.Armed := False;
      end if;
   end Finalize;

   overriding procedure Finalize (Guard : in out Close_Guard) is
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

   function Invalid_Progress_Bound
     (First : Ada.Streams.Stream_Element_Offset;
      Last  : Ada.Streams.Stream_Element_Offset)
      return Ada.Streams.Stream_Element_Offset
   is
      Choice : constant Policy.Sentinel_Choice :=
        Policy.Invalid_Progress_Sentinel (First, Last);
   begin
      if not Choice.Available then
         raise TLS_Error with
           "TLS buffer range leaves no invalid progress sentinel";
      end if;
      return Choice.Value;
   end Invalid_Progress_Bound;

   procedure Await_Ready
     (FD           : Descriptor;
      Status       : Step_Status;
      Started      : Ada.Real_Time.Time;
      Timeout      : Duration;
      Close_Source : Descriptor;
      Token        : access Flyology.Cancellation.Token)
   is
      Token_Source : Descriptor := Invalid_Descriptor;
      Cancelled    : Boolean := False;
      Interrupts   : Interrupt_Set (1 .. 2);
      Interrupt_Count : Positive := 1;
      Outcome      : Wait_Outcome;
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

      Outcome := Wait_Interruptibly
         (FD,
          (if Status = Want_Read then For_Read else For_Write),
          Remaining (Started, Timeout),
         Interrupts (1 .. Interrupt_Count));
      case Outcome is
         when Ready =>
            null;
         when Timed_Out =>
            raise Timeout_Error with "TLS operation timed out";
         when Interrupted =>
            raise Operation_Cancelled;
      end case;
   end Await_Ready;

   procedure Check_Cancelled
     (Item  : Connection;
      Token : access Flyology.Cancellation.Token)
   is
   begin
      if Item.Controller.Close_Requested
        or else (Token /= null and then Token.Requested)
      then
         raise Operation_Cancelled;
      end if;
   end Check_Cancelled;

   procedure Snapshot_Operation
     (Item       : in out Connection;
      Generation : out Descriptor_Generation)
   is
      State : Acquire_Result;
   begin
      Item.Controller.Snapshot_Acquisition (State, Generation);
      case State is
         when Acquired =>
            null;
         when Closing =>
            raise Operation_Cancelled;
         when Closed =>
            raise Program_Error with "TLS connection is not open";
         when Replaced =>
            raise Program_Error with "invalid TLS acquisition snapshot";
      end case;
   end Snapshot_Operation;

   procedure Acquire_Operation
     (Item         : in out Connection;
      Started      : Ada.Real_Time.Time;
      Timeout      : Duration;
      Token        : access Flyology.Cancellation.Token;
      FD           : out Descriptor;
      Guard        : in out Operation_Guard;
      Close_Source : out Descriptor)
   is
      Wait_Slice    : Duration;
      Left          : Duration;
      Acquire_State : Acquire_Result;
      Expected      : Descriptor_Generation;
   begin
      Snapshot_Operation (Item, Expected);

      loop
         Check_Cancelled (Item, Token);
         Left := Remaining (Started, Timeout);
         if Left = 0.0 then
            select
               Item.Controller.Acquire
                 (Expected,
                  FD,
                  Guard.Generation'Access,
                  Guard.Armed'Access,
                  Close_Source,
                  Acquire_State);
               case Acquire_State is
                  when Acquired =>
                     return;
                  when Closing | Closed | Replaced =>
                     raise Operation_Cancelled;
               end case;
            else
               raise Timeout_Error with
                 "TLS operation timed out waiting for the connection";
            end select;
         end if;

         Wait_Slice :=
           (if Left < 0.0 then 0.010 else Duration'Min (Left, 0.010));
         select
            Item.Controller.Acquire
              (Expected,
               FD,
               Guard.Generation'Access,
               Guard.Armed'Access,
               Close_Source,
               Acquire_State);
            case Acquire_State is
               when Acquired =>
                  return;
               when Closing | Closed | Replaced =>
                  raise Operation_Cancelled;
            end case;
         or
            delay Wait_Slice;
         end select;
      end loop;
   end Acquire_Operation;

   procedure Raise_Provider_Error (Item : Session'Class) is
   begin
      raise TLS_Error with Error_Message (Item);
   end Raise_Provider_Error;

   procedure Take
     (Backend     : in out Provider'Class;
      Socket      : in out Sockets.Socket_Type;
      Side        : Role;
      Server_Name : String;
      Item        : in out Connection)
   is
      FD          : Descriptor;
      New_Session : Session_Access := null;
   begin
      if not Sockets.Is_Open (Socket) then
         raise Program_Error with "cannot give TLS a closed socket";
      elsif Is_Open (Item) then
         raise Program_Error with "TLS connection already owns a socket";
      elsif Side = Client and then Server_Name'Length = 0 then
         raise Program_Error with "TLS client requires a server name";
      elsif Side = Server and then Server_Name'Length /= 0 then
         raise Program_Error with "TLS server does not accept a server name";
      elsif not Is_Available (Backend) then
         raise TLS_Error with Name (Backend) & " provider is unavailable";
      end if;

      Flyology.IO.Sockets.Prepare (Socket);
      FD := Flyology.IO.Sockets.Native_Descriptor (Socket);
      Disable_SIGPIPE (Interfaces.C.int (FD));
      New_Session := Create_Session (Backend, FD, Side, Server_Name);
      if New_Session = null then
         raise TLS_Error with Name (Backend) & " returned no TLS session";
      end if;

      begin
         Item.Controller.Adopt (FD);
         Item.Session := New_Session;
         Sockets.Move (Socket, Item.Socket);
      exception
         when others =>
            Free (New_Session);
            raise;
      end;
   end Take;

   procedure Handshake
     (Item    : in out Connection;
      Timeout : Duration := Infinite;
      Token   : access Flyology.Cancellation.Token := null)
   is
      Started      : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      FD           : Descriptor;
      Guard        : Operation_Guard (Item'Unchecked_Access);
      Close_Source : Descriptor;
      Status       : Step_Status;
   begin
      Acquire_Operation
        (Item, Started, Timeout, Token, FD, Guard, Close_Source);
      loop
         Check_Cancelled (Item, Token);
         Status := Handshake_Step (Item.Session.all);
         case Status is
            when Complete =>
               exit;
            when Want_Read | Want_Write =>
               Await_Ready
                 (FD, Status, Started, Timeout, Close_Source, Token);
            when Peer_Closed =>
               raise TLS_Error with "TLS peer closed during handshake";
            when Failed =>
               Raise_Provider_Error (Item.Session.all);
         end case;
      end loop;
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
      Guard        : Operation_Guard (Item'Unchecked_Access);
      Close_Source : Descriptor;
      Status       : Step_Status;
      Before_Last  : Ada.Streams.Stream_Element_Offset;
   begin
      Last := Data'First - 1;
      Acquire_Operation
        (Item, Started, Timeout, Token, FD, Guard, Close_Source);
      if Data'Length = 0 then
         return;
      end if;
      loop
         Check_Cancelled (Item, Token);
         Before_Last := Last;
         Status := Receive_Step (Item.Session.all, Data, Last);
         case Status is
            when Complete =>
               if not Policy.Complete_Progress_Valid
                 (Data'First, Data'Last, Last)
               then
                  raise TLS_Error with
                    "TLS provider returned an invalid receive bound";
               end if;
               exit;
            when Peer_Closed =>
               if not Policy.Progress_Preserved (Before_Last, Last) then
                  raise TLS_Error with
                    "TLS provider changed receive output on peer close";
               end if;
               exit;
            when Want_Read | Want_Write =>
               if not Policy.Progress_Preserved (Before_Last, Last) then
                  raise TLS_Error with
                    "TLS provider changed receive output while waiting";
               end if;
               Await_Ready
                 (FD, Status, Started, Timeout, Close_Source, Token);
            when Failed =>
               Raise_Provider_Error (Item.Session.all);
         end case;
      end loop;
   end Receive;

   procedure Receive_Exactly
     (Item    : in out Connection;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite;
      Token   : access Flyology.Cancellation.Token := null)
   is
      Started      : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      FD           : Descriptor;
      Guard        : Operation_Guard (Item'Unchecked_Access);
      Close_Source : Descriptor;
      Status       : Step_Status;
      First        : Ada.Streams.Stream_Element_Offset := Data'First;
      Last         : Ada.Streams.Stream_Element_Offset;
      Before_Last  : Ada.Streams.Stream_Element_Offset;
   begin
      Acquire_Operation
        (Item, Started, Timeout, Token, FD, Guard, Close_Source);
      if Data'Length = 0 then
         return;
      end if;
      while First <= Data'Last loop
         Check_Cancelled (Item, Token);
         Before_Last := Invalid_Progress_Bound (First, Data'Last);
         Last := Before_Last;
         Status := Receive_Step
           (Item.Session.all, Data (First .. Data'Last), Last);
         case Status is
            when Complete =>
               if not Policy.Complete_Progress_Valid
                 (First, Data'Last, Last)
               then
                  raise TLS_Error with
                    "TLS provider made no receive progress";
               end if;
               exit when Last = Data'Last;
               First := Policy.Next_Offset (Last);
            when Want_Read | Want_Write =>
               if not Policy.Progress_Preserved (Before_Last, Last) then
                  raise TLS_Error with
                    "TLS provider changed receive output while waiting";
               end if;
               Await_Ready
                 (FD, Status, Started, Timeout, Close_Source, Token);
            when Peer_Closed =>
               if not Policy.Progress_Preserved (Before_Last, Last) then
                  raise TLS_Error with
                    "TLS provider changed receive output on peer close";
               end if;
               raise TLS_Error with
                 "TLS peer closed before receive completed";
            when Failed =>
               Raise_Provider_Error (Item.Session.all);
         end case;
      end loop;
   end Receive_Exactly;

   procedure Send_All
     (Item    : in out Connection;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite;
      Token   : access Flyology.Cancellation.Token := null)
   is
      Started      : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      FD           : Descriptor;
      Guard        : Operation_Guard (Item'Unchecked_Access);
      Close_Source : Descriptor;
      Status       : Step_Status;
      First        : Ada.Streams.Stream_Element_Offset := Data'First;
      Last         : Ada.Streams.Stream_Element_Offset;
      Before_Last  : Ada.Streams.Stream_Element_Offset;
   begin
      Acquire_Operation
        (Item, Started, Timeout, Token, FD, Guard, Close_Source);
      if Data'Length = 0 then
         return;
      end if;
      while First <= Data'Last loop
         Check_Cancelled (Item, Token);
         Before_Last := Invalid_Progress_Bound (First, Data'Last);
         Last := Before_Last;
         Status := Send_Step
           (Item.Session.all, Data (First .. Data'Last), Last);
         case Status is
            when Complete =>
               if not Policy.Complete_Progress_Valid
                 (First, Data'Last, Last)
               then
                  raise TLS_Error with "TLS provider made no send progress";
               end if;
               exit when Last = Data'Last;
               First := Policy.Next_Offset (Last);
            when Want_Read | Want_Write =>
               if not Policy.Progress_Preserved (Before_Last, Last) then
                  raise TLS_Error with
                    "TLS provider changed send output while waiting";
               end if;
               Await_Ready
                 (FD, Status, Started, Timeout, Close_Source, Token);
            when Peer_Closed =>
               if not Policy.Progress_Preserved (Before_Last, Last) then
                  raise TLS_Error with
                    "TLS provider changed send output on peer close";
               end if;
               raise TLS_Error with
                 "TLS peer closed before send completed";
            when Failed =>
               Raise_Provider_Error (Item.Session.all);
         end case;
      end loop;
   end Send_All;

   procedure Shutdown
     (Item    : in out Connection;
      Timeout : Duration := Infinite;
      Token   : access Flyology.Cancellation.Token := null)
   is
      Started      : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      FD           : Descriptor;
      Guard        : Operation_Guard (Item'Unchecked_Access);
      Close_Source : Descriptor;
      Status       : Step_Status;
   begin
      Acquire_Operation
        (Item, Started, Timeout, Token, FD, Guard, Close_Source);
      loop
         Check_Cancelled (Item, Token);
         Status := Shutdown_Step (Item.Session.all);
         case Status is
            when Complete =>
               exit;
            when Want_Read | Want_Write =>
               Await_Ready
                 (FD, Status, Started, Timeout, Close_Source, Token);
            when Peer_Closed =>
               raise TLS_Error with
                 "TLS peer closed before shutdown completed";
            when Failed =>
               Raise_Provider_Error (Item.Session.all);
         end case;
      end loop;
   end Shutdown;

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

   function Is_Open (Item : Connection) return Boolean is
     (Item.Controller.Is_Open_State);

   overriding procedure Finalize (Item : in out Connection) is
   begin
      begin
         Close (Item);
      exception
         when others =>
            null;
      end;
   end Finalize;

end Flyology.IO.TLS;
