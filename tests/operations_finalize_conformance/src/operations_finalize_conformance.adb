with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Completion_Set_Finalize_Model;
with Completion_Set_Finalize_TLS_Provider;
with Flyology;
with Flyology.IO.Connections;
with Flyology.IO.Connections.TLS;
with Flyology.IO.DNS;
with Flyology.IO.Sockets;
with Flyology.IO.TLS;
with Flyology.IO.Timers;
with Flyology.Operations;
with Flyology.Operations.Drivers;
with Flyology_TLA.Command_Line;
with Flyology_TLA.Replay;
with Flyology_TLA.Traces;

procedure Operations_Finalize_Conformance is
   package Model renames Completion_Set_Finalize_Model;
   package Connections renames Flyology.IO.Connections;
   package Connection_TLS renames Flyology.IO.Connections.TLS;
   package DNS renames Flyology.IO.DNS;
   package Operations renames Flyology.Operations;
   package Replay_TLS renames Completion_Set_Finalize_TLS_Provider;
   package Drivers renames Flyology.Operations.Drivers;
   package Sockets renames Flyology.IO.Sockets;
   package TLS renames Flyology.IO.TLS;
   package Timers renames Flyology.IO.Timers;

   use Ada.Strings.Unbounded;
   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Model.Input_Event_Type;
   use type Operations.Driver_Event;
   use type Operations.Terminal_Outcome;

   Limits : constant Flyology_TLA.Traces.Load_Limits :=
     (Maximum_File_Bytes   => 1_000_000,
      Maximum_Steps        => 16,
      Maximum_JSON_Depth   => 32,
      Maximum_Object_Names => 512,
      Maximum_Name_Bytes   => 4_096,
      Maximum_String_Bytes => 4_096,
      Maximum_Value_Bytes  => 32_768);

   protected type Cancellation_Barrier is
      procedure Note_Cancellation;
      procedure Note_Source_Ready;
      entry Wait_For_Cancellation;
      function Cancellation_Was_Requested return Boolean;
      function Source_Ready_Count return Natural;
   private
      Reached             : Boolean := False;
      Source_Ready_Drives : Natural := 0;
   end Cancellation_Barrier;

   protected body Cancellation_Barrier is
      procedure Note_Cancellation is
      begin
         Reached := True;
      end Note_Cancellation;

      procedure Note_Source_Ready is
      begin
         Source_Ready_Drives := Source_Ready_Drives + 1;
      end Note_Source_Ready;

      entry Wait_For_Cancellation when Reached is
      begin
         null;
      end Wait_For_Cancellation;

      function Cancellation_Was_Requested return Boolean is
      begin
         return Reached;
      end Cancellation_Was_Requested;

      function Source_Ready_Count return Natural is
      begin
         return Source_Ready_Drives;
      end Source_Ready_Count;
   end Cancellation_Barrier;

   type Immediate_Operation
     (Owner : not null access Operations.Completion_Set'Class)
   is new Operations.Operation (Owner) with null record;

   overriding
   procedure Drive
     (Item : in out Immediate_Operation; Event : Operations.Driver_Event);

   overriding
   procedure Request_Cancellation (Item : in out Immediate_Operation);

   type Delayed_Operation
     (Owner   : not null access Operations.Completion_Set'Class;
      Barrier : not null access Cancellation_Barrier)
   is new Operations.Operation (Owner) with null record;

   overriding
   procedure Drive
     (Item : in out Delayed_Operation; Event : Operations.Driver_Event);

   overriding
   procedure Request_Cancellation (Item : in out Delayed_Operation);

   procedure Drive
     (Item : in out Immediate_Operation; Event : Operations.Driver_Event)
   is
      pragma Unreferenced (Event);
   begin
      Drivers.Complete (Item, Operations.Succeeded);
   end Drive;

   procedure Request_Cancellation (Item : in out Immediate_Operation) is
   begin
      Drivers.Complete (Item, Operations.Cancelled);
   exception
      when others =>
         null;
   end Request_Cancellation;

   procedure Drive
     (Item : in out Delayed_Operation; Event : Operations.Driver_Event) is
   begin
      if Event = Operations.Source_Ready then
         Item.Barrier.Note_Source_Ready;
         Drivers.Complete (Item, Operations.Cancelled);
      else
         Drivers.Complete (Item, Operations.Failed);
      end if;
   end Drive;

   procedure Request_Cancellation (Item : in out Delayed_Operation) is
   begin
      Item.Barrier.Note_Cancellation;
   exception
      when others =>
         null;
   end Request_Cancellation;

   function Start_Immediate
     (Set : not null access Operations.Completion_Set'Class)
      return Immediate_Operation is
   begin
      return Result : Immediate_Operation (Set) do
         Drivers.Start (Result);
         Drive (Result, Operations.Start_Operation);
      end return;
   end Start_Immediate;

   function Start_Delayed
     (Set        : not null access Operations.Completion_Set'Class;
      Barrier    : not null access Cancellation_Barrier;
      Descriptor : Flyology.IO.Descriptor) return Delayed_Operation is
   begin
      return Result : Delayed_Operation (Set, Barrier) do
         Drivers.Start (Result);
         Drivers.Arm_Readiness (Result, Descriptor, For_Write => False);
      end return;
   end Start_Delayed;

   type Finalize_Observation is record
      Returned               : Boolean;
      Cancellation_Requested : Boolean;
      Target_Driven          : Boolean;
      Other_Preserved        : Boolean;
      Other_Replayable       : Boolean;
   end record;

   function Failure_Detail
     (Actual : Finalize_Observation) return Unbounded_String
   is
      Result : Unbounded_String :=
        To_Unbounded_String ("failed observations:");

      procedure Note (Name : String) is
      begin
         Append (Result, " " & Name);
      end Note;
   begin
      if not Actual.Returned then
         Note ("Returned");
      end if;
      if not Actual.Cancellation_Requested then
         Note ("Cancellation_Requested");
      end if;
      if not Actual.Target_Driven then
         Note ("Target_Driven");
      end if;
      if not Actual.Other_Preserved then
         Note ("Other_Preserved");
      end if;
      if not Actual.Other_Replayable then
         Note ("Other_Replayable");
      end if;
      return Result;
   end Failure_Detail;

   function Execute_Finalize return Finalize_Observation is
      Returned               : Boolean := False
      with Atomic;
      Cancellation_Requested : Boolean := False
      with Atomic;
      Target_Driven          : Boolean := False
      with Atomic;
      Other_Preserved        : Boolean := False
      with Atomic;
      Other_Replayable       : Boolean := False
      with Atomic;
   begin
      declare
         task Worker is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Worker;

         task body Worker is
            Left, Right : aliased Sockets.Socket_Type;
            Barrier     : aliased Cancellation_Barrier;
         begin
            Sockets.Create_Socket_Pair (Left, Right);
            declare
               task Signaler;

               task body Signaler is
                  Byte : constant Ada.Streams.Stream_Element_Array := [1 => 1];
                  Last : Ada.Streams.Stream_Element_Offset;
               begin
                  Barrier.Wait_For_Cancellation;
                  Sockets.Send_Socket (Right, Byte, Last);
                  if Last /= Byte'Last then
                     raise Program_Error with "completion signal was short";
                  end if;
               end Signaler;

               Set   : aliased Operations.Completion_Set (2);
               Other : Immediate_Operation := Start_Immediate (Set'Access);
            begin
               declare
                  Target : Delayed_Operation :=
                    Start_Delayed
                      (Set'Access,
                       Barrier'Access,
                       Sockets.Native_Descriptor (Left));
                  pragma Unreferenced (Target);
               begin
                  null;
               end;

               Returned := True;
               Cancellation_Requested := Barrier.Cancellation_Was_Requested;
               Target_Driven := Barrier.Source_Ready_Count = 1;

               declare
                  Batch : Operations.Completion_Batch (Set.Capacity);
               begin
                  Other_Preserved :=
                    Operations.Pending_Count (Set) = 0
                    and then Operations.Terminal_Count (Set) = 1;
                  Operations.Wait_Some (Set, Batch);
                  Other_Replayable :=
                    Other_Preserved
                    and then Batch.Count = 1
                    and then Natural (Batch.Ids (1)) = Operations.Id (Other);
               end;
               Operations.Consume (Other);
            end;
            Sockets.Close_Socket (Left);
            Sockets.Close_Socket (Right);
         exception
            when others =>
               Other_Replayable := False;
         end Worker;
      begin
         null;
      end;
      return
        (Returned               => Returned,
         Cancellation_Requested => Cancellation_Requested,
         Target_Driven          => Target_Driven,
         Other_Preserved        => Other_Preserved,
         Other_Replayable       => Other_Replayable);
   end Execute_Finalize;

   type Disposal_Mode is (Typed_Finish, Generic_Consume, Controlled_Finalize);

   type Driver_Failure_Observation is record
      Returned            : Boolean;
      Peer_Drainable      : Boolean;
      Close_Deferred      : Boolean;
      Cleanup_Before_Peer : Boolean;
      Closed              : Boolean;
      Failure_Retained    : Boolean;
      Result_Discarded    : Boolean;
   end record;

   function Driver_Failure_Detail
     (Actual : Driver_Failure_Observation; Mode : Disposal_Mode)
      return Unbounded_String
   is
      Result : Unbounded_String :=
        To_Unbounded_String ("failed driver observations:");

      procedure Note (Name : String) is
      begin
         Append (Result, " " & Name);
      end Note;
   begin
      if not Actual.Returned then
         Note ("Returned");
      end if;
      if not Actual.Peer_Drainable then
         Note ("Peer_Drainable");
      end if;
      if not Actual.Close_Deferred then
         Note ("Close_Deferred");
      end if;
      if not Actual.Cleanup_Before_Peer then
         Note ("Cleanup_Before_Peer");
      end if;
      if not Actual.Closed then
         Note ("Closed");
      end if;
      if Mode = Typed_Finish and then not Actual.Failure_Retained then
         Note ("Failure_Retained");
      end if;
      if Mode /= Typed_Finish and then not Actual.Result_Discarded then
         Note ("Result_Discarded");
      end if;
      return Result;
   end Driver_Failure_Detail;

   function Execute_Driver_Failure
     (Mode : Disposal_Mode) return Driver_Failure_Observation
   is
      Manager             : aliased Connections.Server (Capacity => 1);
      Item                : aliased Connections.Connection (Manager'Access);
      Socket, Peer        : Sockets.Socket_Type;
      Backend             : aliased Replay_TLS.Provider;
      Holding_Data        : aliased Ada.Streams.Stream_Element_Array :=
        [1 => 0];
      Pending_Data        : aliased Ada.Streams.Stream_Element_Array :=
        [1 => 0];
      Last                : Ada.Streams.Stream_Element_Offset;
      Sent                : Ada.Streams.Stream_Element_Offset;
      Holding_Cancelled   : Boolean := False;
      Returned            : Boolean := False;
      Peer_Drainable      : Boolean := False;
      Close_Deferred      : Boolean := False;
      Cleanup_Before_Peer : Boolean := False;
      Closed              : Boolean := False;
      Failure_Retained    : Boolean := False;
      Result_Discarded    : Boolean := False;
   begin
      Sockets.Create_Socket_Pair (Socket, Peer);
      Connections.Take (Manager, Socket, Item);
      declare
         Holding_Set : aliased Operations.Completion_Set (1);
         Peer_Set    : aliased Operations.Completion_Set (1);
         Upgrade_Set : aliased Operations.Completion_Set (1);
         Holding     : Connections.Receive_Operation :=
           Connections.Receive
             (Holding_Set'Access,
              Item'Access,
              Holding_Data'Access,
              Timeout => Flyology.IO.Infinite);
         Pending     : Connections.Receive_Operation :=
           Connections.Receive
             (Peer_Set'Access,
              Item'Access,
              Pending_Data'Access,
              Timeout => Flyology.IO.Infinite);
      begin
         Operations.Cancel (Holding);
         Operations.Wait_All (Holding_Set);
         begin
            Connections.Finish (Holding, Last);
         exception
            when Connections.Operation_Cancelled =>
               Holding_Cancelled := True;
         end;

         declare
            Upgrade : Connection_TLS.Upgrade_Operation :=
              Connection_TLS.Upgrade
                (Upgrade_Set'Access,
                 Item'Access,
                 Backend'Access,
                 TLS.Server,
                 "",
                 Timeout => Flyology.IO.Infinite);
         begin
            Sockets.Send_Socket (Peer, [1 => 1], Sent);
            if Sent /= 1 then
               raise Program_Error with "failed-upgrade signal was short";
            end if;
            Operations.Wait_All (Upgrade_Set);
            Returned := True;
            Close_Deferred := Connections.Is_Open (Item);

            case Mode is
               when Typed_Finish        =>
                  begin
                     Connection_TLS.Finish (Upgrade);
                  exception
                     when TLS.TLS_Error =>
                        Failure_Retained := True;
                  end;
                  Cleanup_Before_Peer := True;

               when Generic_Consume     =>
                  Operations.Consume (Upgrade);
                  Result_Discarded := True;
                  Cleanup_Before_Peer := True;

               when Controlled_Finalize =>
                  Result_Discarded := True;
            end case;
         end;
         if Mode = Controlled_Finalize then
            Cleanup_Before_Peer := True;
         end if;
         Operations.Cancel (Pending);
         Operations.Wait_All (Peer_Set);
         begin
            Connections.Finish (Pending, Last);
         exception
            when Connections.Operation_Cancelled =>
               Peer_Drainable := Holding_Cancelled;
         end;
         Closed := not Connections.Is_Open (Item);
      end;
      Sockets.Close_Socket (Peer);
      return
        (Returned            => Returned,
         Peer_Drainable      => Peer_Drainable,
         Close_Deferred      => Close_Deferred,
         Cleanup_Before_Peer => Cleanup_Before_Peer,
         Closed              => Closed,
         Failure_Retained    => Failure_Retained,
         Result_Discarded    => Result_Discarded);
   end Execute_Driver_Failure;

   type Driver_Raise_Observation is record
      Returned             : Boolean;
      Driver_Raise_Caught  : Boolean;
      One_Terminal_Failure : Boolean;
      Source_Cleared       : Boolean;
      Child_Cleared        : Boolean;
      Failure_Retained     : Boolean;
   end record;

   function Driver_Raise_Detail
     (Actual : Driver_Raise_Observation) return Unbounded_String
   is
      Result : Unbounded_String :=
        To_Unbounded_String ("failed driver-raise observations:");

      procedure Note (Name : String) is
      begin
         Append (Result, " " & Name);
      end Note;
   begin
      if not Actual.Returned then
         Note ("Returned");
      end if;
      if not Actual.Driver_Raise_Caught then
         Note ("Driver_Raise_Caught");
      end if;
      if not Actual.One_Terminal_Failure then
         Note ("One_Terminal_Failure");
      end if;
      if not Actual.Source_Cleared then
         Note ("Source_Cleared");
      end if;
      if not Actual.Child_Cleared then
         Note ("Child_Cleared");
      end if;
      if not Actual.Failure_Retained then
         Note ("Failure_Retained");
      end if;
      return Result;
   end Driver_Raise_Detail;

   function Execute_Driver_Raise return Driver_Raise_Observation is
      task Server is
         entry Get_Address (Address : out Sockets.Endpoint);
      end Server;

      task body Server is
         Socket        : Sockets.Socket_Type;
         Bound         : Sockets.Endpoint;
         Peer          : Sockets.Endpoint;
         Query         : Ada.Streams.Stream_Element_Array (1 .. 512);
         Response      : Ada.Streams.Stream_Element_Array (1 .. 512) :=
           (others => 0);
         Last          : Ada.Streams.Stream_Element_Offset;
         Sent_Last     : Ada.Streams.Stream_Element_Offset;
         Question_Last : Ada.Streams.Stream_Element_Offset := 13;
         Position      : Ada.Streams.Stream_Element_Offset := 3;

         procedure Put_U16 (Value : Natural) is
         begin
            Response (Position) :=
              Ada.Streams.Stream_Element ((Value / 256) mod 256);
            Response (Position + 1) :=
              Ada.Streams.Stream_Element (Value mod 256);
            Position := Position + 2;
         end Put_U16;
      begin
         Sockets.Create_Socket (Socket, Sockets.IPv4, Sockets.Socket_Datagram);
         Sockets.Bind_Socket
           (Socket,
            Sockets.Network_Endpoint
              (Sockets.Loopback_IPv4, Sockets.Any_Port));
         Bound := Sockets.Get_Socket_Name (Socket);
         accept Get_Address (Address : out Sockets.Endpoint) do
            Address := Bound;
         end Get_Address;
         Sockets.Receive_Socket (Socket, Query, Last, Peer);
         while Query (Question_Last) /= 0 loop
            Question_Last :=
              Question_Last
              + 1
              + Ada.Streams.Stream_Element_Offset (Query (Question_Last));
         end loop;
         Question_Last := Question_Last + 4;
         Response (1 .. 2) := Query (1 .. 2);
         Put_U16 (16#8183#);
         Put_U16 (1);
         Put_U16 (0);
         Put_U16 (0);
         Put_U16 (0);
         Response (Position .. Position + Question_Last - 13) :=
           Query (13 .. Question_Last);
         Position := Position + Question_Last - 12;
         Sockets.Send_Socket
           (Socket, Response (1 .. Position - 1), Sent_Last, Peer);
         Sockets.Close_Socket (Socket);
      end Server;

      Address              : Sockets.Endpoint;
      Servers              : DNS.Name_Server_Array (1 .. 1);
      Returned             : Boolean := False;
      Driver_Raise_Caught  : Boolean := False;
      One_Terminal_Failure : Boolean := False;
      Source_Cleared       : Boolean := False;
      Child_Cleared        : Boolean := False;
      Failure_Retained     : Boolean := False;
   begin
      Server.Get_Address (Address);
      Servers (1) := Address;
      DNS.Clear_Cache;
      begin
         declare
            Ignored : constant DNS.Address_Array :=
              DNS.Resolve_Using
                ("driver-raise.capacity.test",
                 Servers,
                 DNS.IPv6_Only,
                 Timeout        => 1.0,
                 Attempts       => 1,
                 Retry_Interval => 0.5);
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when DNS.Name_Not_Found =>
            null;
      end;

      declare
         Set     : aliased Operations.Completion_Set (2);
         Resolve : DNS.Resolve_Operation :=
           DNS.Resolve_Using
             (Set'Access,
              "driver-raise.capacity.test",
              Servers,
              DNS.Any_Family,
              Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (2.0),
              Attempts       => 1,
              Retry_Interval => 1.0);
         Filler  : Timers.Timer_Operation :=
           Timers.Sleep_For (Set'Access, 1.0);
         Batch   : Operations.Completion_Batch (Set.Capacity);
      begin
         begin
            Operations.Wait_Some (Set, Batch);
            Returned := True;
         exception
            when Operations.Capacity_Error =>
               null;
         end;

         Driver_Raise_Caught :=
           Returned
           and then Operations.Is_Terminal (Resolve)
           and then Operations.Outcome (Resolve) = Operations.Failed;
         One_Terminal_Failure :=
           Driver_Raise_Caught
           and then Operations.Terminal_Count (Set) = 1
           and then Operations.Pending_Count (Set) = 1;
         Child_Cleared := Driver_Raise_Caught;

         if Driver_Raise_Caught then
            begin
               declare
                  Ignored : constant DNS.Address_Array := DNS.Finish (Resolve);
                  pragma Unreferenced (Ignored);
               begin
                  null;
               end;
            exception
               when DNS.Resolution_Failed =>
                  Failure_Retained := True;
            end;
         end if;

         Operations.Cancel (Filler);
         begin
            Operations.Wait_All (Set);
            Source_Cleared := Driver_Raise_Caught;
         exception
            when Operations.Operation_Error =>
               Source_Cleared := False;
         end;
         begin
            Timers.Finish (Filler);
         exception
            when Operations.Operation_Cancelled =>
               null;
         end;
      end;

      return
        (Returned             => Returned,
         Driver_Raise_Caught  => Driver_Raise_Caught,
         One_Terminal_Failure => One_Terminal_Failure,
         Source_Cleared       => Source_Cleared,
         Child_Cleared        => Child_Cleared,
         Failure_Retained     => Failure_Retained);
   end Execute_Driver_Raise;

   type Finalize_Adapter is new Model.Adapter with null record;

   overriding
   procedure Reset
     (Self     : in out Finalize_Adapter;
      Observed : out Model.State_Type;
      Status   : out Flyology_TLA.Replay.Adapter_Outcome);

   overriding
   procedure Apply
     (Self         : in out Finalize_Adapter;
      Index        : Positive;
      Action       : String;
      Role         : String;
      Input        : Model.Input_Type;
      Model_Source : String;
      Observed     : out Model.Outcome_Type;
      State        : out Model.State_Type;
      Status       : out Flyology_TLA.Replay.Adapter_Outcome);

   procedure Reset
     (Self     : in out Finalize_Adapter;
      Observed : out Model.State_Type;
      Status   : out Flyology_TLA.Replay.Adapter_Outcome)
   is
      pragma Unreferenced (Self);
   begin
      Observed :=
        (Target_State           => Model.State_Target_State_Pending,
         Target_Reported        => False,
         Other_State            => Model.State_Other_State_Terminal,
         Other_Reported         => False,
         Saved_Other_Reported   => False,
         Cancellation_Requested => False,
         Phase                  => Model.State_Phase_Ready,
         Driver_State           => Model.State_Driver_State_Pending,
         Peer_Registered        => True,
         Close_Required         => False,
         Close_Pending          => False,
         Driver_Returned        => False,
         Driver_Phase           => Model.State_Driver_Phase_Ready,
         Raise_Root_State       => Model.State_Raise_Root_State_Pending,
         Raise_Root_Source      => Model.State_Raise_Root_Source_Immediate,
         Raise_Root_Has_Child   => False,
         Driver_Raised          => False,
         Terminal_Failure_Count => 0,
         Raise_Phase            => Model.State_Raise_Phase_Ready,
         Harness_Phase          => Model.State_Harness_Phase_Ready,
         Last_Action            => Model.State_Last_Action_Init);
      Status := (Succeeded => True, Detail => Null_Unbounded_String);
   end Reset;

   procedure Apply
     (Self         : in out Finalize_Adapter;
      Index        : Positive;
      Action       : String;
      Role         : String;
      Input        : Model.Input_Type;
      Model_Source : String;
      Observed     : out Model.Outcome_Type;
      State        : out Model.State_Type;
      Status       : out Flyology_TLA.Replay.Adapter_Outcome)
   is
      procedure Apply_Driver
        (Mode          : Disposal_Mode;
         Harness_Phase : Model.State_Harness_Phase_Type;
         Last_Action   : Model.State_Last_Action_Type)
      is
         Actual   : constant Driver_Failure_Observation :=
           Execute_Driver_Failure (Mode);
         Complete : constant Boolean :=
           Actual.Returned
           and then Actual.Peer_Drainable
           and then Actual.Close_Deferred
           and then Actual.Cleanup_Before_Peer
           and then Actual.Closed
           and then (if Mode = Typed_Finish
                     then
                       Actual.Failure_Retained
                       and then not Actual.Result_Discarded
                     else
                       Actual.Result_Discarded
                       and then not Actual.Failure_Retained);
      begin
         Observed :=
           (Returned             => Actual.Returned,
            Other_Replayable     => False,
            Peer_Drainable       => Actual.Peer_Drainable,
            Close_Deferred       => Actual.Close_Deferred,
            Cleanup_Before_Peer  => Actual.Cleanup_Before_Peer,
            Closed_At_Finish     => Actual.Closed and then Mode = Typed_Finish,
            Closed_At_Consume    =>
              Actual.Closed and then Mode = Generic_Consume,
            Closed_At_Finalize   =>
              Actual.Closed and then Mode = Controlled_Finalize,
            Failure_Retained     => Actual.Failure_Retained,
            Result_Discarded     => Actual.Result_Discarded,
            Driver_Raise_Caught  => False,
            One_Terminal_Failure => False,
            Raise_Source_Cleared => False,
            Raise_Child_Cleared  => False);
         State :=
           (Target_State           => Model.State_Target_State_Idle,
            Target_Reported        => False,
            Other_State            => Model.State_Other_State_Terminal,
            Other_Reported         => False,
            Saved_Other_Reported   => False,
            Cancellation_Requested => True,
            Phase                  => Model.State_Phase_Done,
            Driver_State           =>
              (if Actual.Closed
               then Model.State_Driver_State_Idle
               else Model.State_Driver_State_Terminal),
            Peer_Registered        => not Actual.Peer_Drainable,
            Close_Required         => not Actual.Closed,
            Close_Pending          => False,
            Driver_Returned        => Actual.Returned,
            Driver_Phase           =>
              (if Complete
               then Model.State_Driver_Phase_Done
               elsif Actual.Returned
               then Model.State_Driver_Phase_Returned
               else Model.State_Driver_Phase_Blocked),
            Raise_Root_State       => Model.State_Raise_Root_State_Pending,
            Raise_Root_Source      => Model.State_Raise_Root_Source_Immediate,
            Raise_Root_Has_Child   => False,
            Driver_Raised          => False,
            Terminal_Failure_Count => 0,
            Raise_Phase            => Model.State_Raise_Phase_Ready,
            Harness_Phase          => Harness_Phase,
            Last_Action            => Last_Action);
         Status :=
           (Succeeded => Complete,
            Detail    =>
              (if Complete
               then Null_Unbounded_String
               else Driver_Failure_Detail (Actual, Mode)));
      end Apply_Driver;
   begin
      if Index = 1
        and then Action = "CompletionSetFinalize!Finalize"
        and then Role = "finalize"
        and then Input.Event = Model.Input_Event_Finalize
        and then Model_Source = "CompletionSetFinalize!Finalize"
      then
         declare
            Actual   : constant Finalize_Observation := Execute_Finalize;
            Complete : constant Boolean :=
              Actual.Returned
              and then Actual.Cancellation_Requested
              and then Actual.Target_Driven
              and then Actual.Other_Preserved
              and then Actual.Other_Replayable;
         begin
            Observed :=
              (Returned             => Actual.Returned,
               Other_Replayable     => Actual.Other_Replayable,
               Peer_Drainable       => False,
               Close_Deferred       => False,
               Cleanup_Before_Peer  => False,
               Closed_At_Finish     => False,
               Closed_At_Consume    => False,
               Closed_At_Finalize   => False,
               Failure_Retained     => False,
               Result_Discarded     => False,
               Driver_Raise_Caught  => False,
               One_Terminal_Failure => False,
               Raise_Source_Cleared => False,
               Raise_Child_Cleared  => False);
            State :=
              (Target_State           =>
                 (if Actual.Target_Driven
                  then Model.State_Target_State_Idle
                  else Model.State_Target_State_Pending),
               Target_Reported        => False,
               Other_State            =>
                 (if Actual.Other_Preserved
                  then Model.State_Other_State_Terminal
                  else Model.State_Other_State_Idle),
               Other_Reported         => not Actual.Other_Replayable,
               Saved_Other_Reported   => False,
               Cancellation_Requested => Actual.Cancellation_Requested,
               Phase                  =>
                 (if Complete
                  then Model.State_Phase_Done
                  else Model.State_Phase_Drain),
               Driver_State           => Model.State_Driver_State_Pending,
               Peer_Registered        => True,
               Close_Required         => False,
               Close_Pending          => False,
               Driver_Returned        => False,
               Driver_Phase           => Model.State_Driver_Phase_Ready,
               Raise_Root_State       => Model.State_Raise_Root_State_Pending,
               Raise_Root_Source      =>
                 Model.State_Raise_Root_Source_Immediate,
               Raise_Root_Has_Child   => False,
               Driver_Raised          => False,
               Terminal_Failure_Count => 0,
               Raise_Phase            => Model.State_Raise_Phase_Ready,
               Harness_Phase          => Model.State_Harness_Phase_Finalized,
               Last_Action            =>
                 (if Complete
                  then Model.State_Last_Action_Finalize
                  else Model.State_Last_Action_Begin_Finalize));
            Status :=
              (Succeeded => Complete,
               Detail    =>
                 (if Complete
                  then Null_Unbounded_String
                  else Failure_Detail (Actual)));
         end;
         return;
      elsif Index = 2
        and then Action = "CompletionSetFinalize!DriverFinish"
        and then Role = "driver-finish"
        and then Input.Event = Model.Input_Event_Driver_Finish
        and then Model_Source = "CompletionSetFinalize!DriverFinish"
      then
         Apply_Driver
           (Typed_Finish,
            Model.State_Harness_Phase_Finished,
            Model.State_Last_Action_Driver_Finish);
         return;
      elsif Index = 3
        and then Action = "CompletionSetFinalize!DriverConsume"
        and then Role = "driver-consume"
        and then Input.Event = Model.Input_Event_Driver_Consume
        and then Model_Source = "CompletionSetFinalize!DriverConsume"
      then
         Apply_Driver
           (Generic_Consume,
            Model.State_Harness_Phase_Consumed,
            Model.State_Last_Action_Driver_Consume);
         return;
      elsif Index = 4
        and then Action = "CompletionSetFinalize!DriverFinalize"
        and then Role = "driver-finalize"
        and then Input.Event = Model.Input_Event_Driver_Finalize
        and then Model_Source = "CompletionSetFinalize!DriverFinalize"
      then
         Apply_Driver
           (Controlled_Finalize,
            Model.State_Harness_Phase_Disposed,
            Model.State_Last_Action_Driver_Finalize);
         return;
      elsif Index = 5
        and then Action = "CompletionSetFinalize!DriverRaises"
        and then Role = "driver-raise"
        and then Input.Event = Model.Input_Event_Driver_Raises
        and then Model_Source = "CompletionSetFinalize!DriverRaises"
      then
         declare
            Actual   : constant Driver_Raise_Observation :=
              Execute_Driver_Raise;
            Complete : constant Boolean :=
              Actual.Returned
              and then Actual.Driver_Raise_Caught
              and then Actual.One_Terminal_Failure
              and then Actual.Source_Cleared
              and then Actual.Child_Cleared
              and then Actual.Failure_Retained;
         begin
            Observed :=
              (Returned             => Actual.Returned,
               Other_Replayable     => False,
               Peer_Drainable       => False,
               Close_Deferred       => False,
               Cleanup_Before_Peer  => False,
               Closed_At_Finish     => False,
               Closed_At_Consume    => False,
               Closed_At_Finalize   => False,
               Failure_Retained     => Actual.Failure_Retained,
               Result_Discarded     => False,
               Driver_Raise_Caught  => Actual.Driver_Raise_Caught,
               One_Terminal_Failure => Actual.One_Terminal_Failure,
               Raise_Source_Cleared => Actual.Source_Cleared,
               Raise_Child_Cleared  => Actual.Child_Cleared);
            State :=
              (Target_State           => Model.State_Target_State_Idle,
               Target_Reported        => False,
               Other_State            => Model.State_Other_State_Terminal,
               Other_Reported         => False,
               Saved_Other_Reported   => False,
               Cancellation_Requested => True,
               Phase                  => Model.State_Phase_Done,
               Driver_State           => Model.State_Driver_State_Idle,
               Peer_Registered        => False,
               Close_Required         => False,
               Close_Pending          => False,
               Driver_Returned        => True,
               Driver_Phase           => Model.State_Driver_Phase_Done,
               Raise_Root_State       =>
                 (if Actual.Driver_Raise_Caught
                  then Model.State_Raise_Root_State_Terminal
                  else Model.State_Raise_Root_State_Pending),
               Raise_Root_Source      => Model.State_Raise_Root_Source_None,
               Raise_Root_Has_Child   => not Actual.Child_Cleared,
               Driver_Raised          => True,
               Terminal_Failure_Count =>
                 (if Actual.One_Terminal_Failure then 1 else 0),
               Raise_Phase            =>
                 (if Complete
                  then Model.State_Raise_Phase_Done
                  else Model.State_Raise_Phase_Raised),
               Harness_Phase          =>
                 (if Complete
                  then Model.State_Harness_Phase_Done
                  else Model.State_Harness_Phase_Disposed),
               Last_Action            =>
                 Model.State_Last_Action_Driver_Raises);
            Status :=
              (Succeeded => Complete,
               Detail    =>
                 (if Complete
                  then Null_Unbounded_String
                  else Driver_Raise_Detail (Actual)));
         end;
         return;
      end if;

      Observed :=
        (Returned             => False,
         Other_Replayable     => False,
         Peer_Drainable       => False,
         Close_Deferred       => False,
         Cleanup_Before_Peer  => False,
         Closed_At_Finish     => False,
         Closed_At_Consume    => False,
         Closed_At_Finalize   => False,
         Failure_Retained     => False,
         Result_Discarded     => False,
         Driver_Raise_Caught  => False,
         One_Terminal_Failure => False,
         Raise_Source_Cleared => False,
         Raise_Child_Cleared  => False);
      Reset (Self, State, Status);
      Status :=
        (Succeeded => False,
         Detail    =>
           To_Unbounded_String ("unsupported modeled action or input"));
   end Apply;

begin
   declare
      Config : Flyology_TLA.Command_Line.Configuration :=
        Flyology_TLA.Command_Line.Parse (Limits);
   begin
      if Flyology_TLA.Command_Line.Help_Requested (Config) then
         Flyology_TLA.Command_Line.Put_Help;
         return;
      end if;

      declare
         Trace   : constant Flyology_TLA.Traces.Trace :=
           Flyology_TLA.Command_Line.Load (Config);
         Adapter : Finalize_Adapter;
         Result  : Flyology_TLA.Replay.Replay_Result;
      begin
         Model.Run
           (Adapter, Trace, Flyology_TLA.Command_Line.Limits (Config), Result);
         Flyology_TLA.Command_Line.Report (Config, Result);
         Flyology_TLA.Command_Line.Set_Exit_Status (Result);
      end;
   end;
exception
   when Error : Flyology_TLA.Command_Line.Usage_Error =>
      Flyology_TLA.Command_Line.Fail
        (Ada.Exceptions.Exception_Message (Error), Show_Help => True);
   when Error : Flyology_TLA.Traces.Trace_Error =>
      Flyology_TLA.Command_Line.Fail
        ("cannot load trace: " & Ada.Exceptions.Exception_Message (Error));
end Operations_Finalize_Conformance;
