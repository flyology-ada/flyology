with Ada.Exceptions;
with Ada.Streams;
with Ada.Text_IO;
with Flyology;
with Flyology.Cancellation;
with Flyology.IO.Connections;
with Flyology.IO.Connections.Drivers;
with Flyology.IO.Connections.TLS;
with Flyology.IO.Sockets;
with Flyology.IO.Timers;
with Flyology.IO.TLS;
with Flyology.Operations;
with Flyology.Operations.Drivers;
with TLS_Test_Provider;

procedure Connection_Operations_Smoke is
   package Connections renames Flyology.IO.Connections;
   package Connection_Drivers renames Flyology.IO.Connections.Drivers;
   package Connection_TLS renames Flyology.IO.Connections.TLS;
   package Sockets renames Flyology.IO.Sockets;
   package TLS renames Flyology.IO.TLS;
   package Provider renames TLS_Test_Provider;

   use Ada.Streams;
   use type Connection_Drivers.Acquisition_Result;
   use type Connection_Drivers.Step_Result;
   use type Flyology.Operations.Driver_Event;
   use type Flyology.Operations.Terminal_Outcome;

   package Synthetic is

      type Synthetic_Transport is limited interface;
      procedure Start_Receive
        (Item      : in out Synthetic_Transport;
         Operation : in out Flyology.Operations.Operation'Class;
         Result    : out Connection_Drivers.Acquisition_Result)
      is abstract;
      procedure Poll_Receive
        (Item : in out Synthetic_Transport; Result : out Connection_Drivers.Acquisition_Result)
      is abstract;
      procedure Arm_Acquire
        (Item : in out Synthetic_Transport; Operation : in out Flyology.Operations.Operation'Class)
      is abstract;
      procedure Receive_Step
        (Item   : in out Synthetic_Transport;
         Data   : out Stream_Element_Array;
         Last   : out Stream_Element_Offset;
         Result : out Connection_Drivers.Step_Result)
      is abstract;
      procedure Arm_Step
        (Item      : in out Synthetic_Transport;
         Operation : in out Flyology.Operations.Operation'Class;
         Required  : Connection_Drivers.Step_Result)
      is abstract;
      procedure Release (Item : in out Synthetic_Transport) is abstract;

      type Connection_Transport (Item : not null access Connections.Connection'Class) is limited
        new Synthetic_Transport
      with record
         IO      : Connection_Drivers.Capability;
         Wakeup  : Connection_Drivers.Outbound_Wakeup;
         Timeout : Duration := 1.0;
      end record;

      overriding
      procedure Start_Receive
        (Item      : in out Connection_Transport;
         Operation : in out Flyology.Operations.Operation'Class;
         Result    : out Connection_Drivers.Acquisition_Result);
      overriding
      procedure Poll_Receive
        (Item : in out Connection_Transport; Result : out Connection_Drivers.Acquisition_Result);
      overriding
      procedure Arm_Acquire
        (Item : in out Connection_Transport; Operation : in out Flyology.Operations.Operation'Class);
      overriding
      procedure Receive_Step
        (Item   : in out Connection_Transport;
         Data   : out Stream_Element_Array;
         Last   : out Stream_Element_Offset;
         Result : out Connection_Drivers.Step_Result);
      overriding
      procedure Arm_Step
        (Item      : in out Connection_Transport;
         Operation : in out Flyology.Operations.Operation'Class;
         Required  : Connection_Drivers.Step_Result);
      overriding
      procedure Release (Item : in out Connection_Transport);

      type Stream_Array_Access is access all Stream_Element_Array;
      type Synthetic_Receive_Operation
        (Set       : not null access Flyology.Operations.Completion_Set'Class;
         Transport : not null access Synthetic_Transport'Class)
      is new Flyology.Operations.Operation (Set) with record
         Data           : Stream_Array_Access := null;
         Last           : Stream_Element_Offset := 0;
         Acquiring      : Boolean := True;
         Protocol_Ready : access Boolean := null;
      end record;

      overriding
      procedure Drive (Item : in out Synthetic_Receive_Operation; Event : Flyology.Operations.Driver_Event);
      overriding
      procedure Request_Cancellation (Item : in out Synthetic_Receive_Operation);

   end Synthetic;

   package body Synthetic is

      overriding
      procedure Start_Receive
        (Item      : in out Connection_Transport;
         Operation : in out Flyology.Operations.Operation'Class;
         Result    : out Connection_Drivers.Acquisition_Result) is
      begin
         Connection_Drivers.Start (Item.IO, Item.Item, Result, Timeout => Item.Timeout);
         Connection_Drivers.Arm_Deadline (Item.IO, Operation);
      end Start_Receive;

      overriding
      procedure Poll_Receive
        (Item : in out Connection_Transport; Result : out Connection_Drivers.Acquisition_Result) is
      begin
         Connection_Drivers.Poll_Acquisition (Item.IO, Result);
      end Poll_Receive;

      overriding
      procedure Arm_Acquire
        (Item : in out Connection_Transport; Operation : in out Flyology.Operations.Operation'Class) is
      begin
         Connection_Drivers.Arm_Acquisition (Item.IO, Operation);
      end Arm_Acquire;

      overriding
      procedure Receive_Step
        (Item   : in out Connection_Transport;
         Data   : out Stream_Element_Array;
         Last   : out Stream_Element_Offset;
         Result : out Connection_Drivers.Step_Result) is
      begin
         Connection_Drivers.Receive (Item.IO, Data, Last, Result);
      end Receive_Step;

      overriding
      procedure Arm_Step
        (Item      : in out Connection_Transport;
         Operation : in out Flyology.Operations.Operation'Class;
         Required  : Connection_Drivers.Step_Result) is
      begin
         Connection_Drivers.Arm_Transport (Item.IO, Operation, Required, Item.Wakeup);
      end Arm_Step;

      overriding
      procedure Release (Item : in out Connection_Transport) is
      begin
         Connection_Drivers.Release (Item.IO);
      end Release;

      overriding
      procedure Drive (Item : in out Synthetic_Receive_Operation; Event : Flyology.Operations.Driver_Event) is
         Acquired : Connection_Drivers.Acquisition_Result;
         Step     : Connection_Drivers.Step_Result;
      begin
         if Event = Flyology.Operations.Deadline_Reached then
            Release (Item.Transport.all);
            Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
            return;
         elsif Event /= Flyology.Operations.Start_Operation
           and then Item.Protocol_Ready /= null
           and then Item.Protocol_Ready.all
         then
            Release (Item.Transport.all);
            Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Succeeded);
            return;
         elsif Event = Flyology.Operations.Start_Operation then
            Start_Receive (Item.Transport.all, Item, Acquired);
         elsif Item.Acquiring then
            Poll_Receive (Item.Transport.all, Acquired);
         else
            Acquired := Connection_Drivers.Acquired;
         end if;

         if Acquired = Connection_Drivers.Need_Acquire_Readiness then
            Arm_Acquire (Item.Transport.all, Item);
            return;
         end if;
         Item.Acquiring := False;
         Receive_Step (Item.Transport.all, Item.Data.all, Item.Last, Step);
         case Step is
            when Connection_Drivers.Made_Progress | Connection_Drivers.Peer_Closed =>
               Release (Item.Transport.all);
               Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Succeeded);

            when Connection_Drivers.Need_Read | Connection_Drivers.Need_Write      =>
               Arm_Step (Item.Transport.all, Item, Step);
         end case;
      exception
         when others =>
            begin
               Release (Item.Transport.all);
            exception
               when others =>
                  null;
            end;
            Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
      end Drive;

      overriding
      procedure Request_Cancellation (Item : in out Synthetic_Receive_Operation) is
      begin
         Release (Item.Transport.all);
         Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Cancelled);
      exception
         when others =>
            Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
      end Request_Cancellation;

   end Synthetic;

   use Synthetic;

   function Ref (Item : Flyology.Operations.Operation'Class) return Flyology.Operations.Operation_Reference
   renames Flyology.Operations.Reference;

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   protected Results is
      procedure Publish (Passed : Boolean);
      entry Await (Passed : out Boolean);
   private
      Ready : Boolean := False;
      Value : Boolean := False;
   end Results;

   protected body Results is
      procedure Publish (Passed : Boolean) is
      begin
         Value := Passed;
         Ready := True;
      end Publish;

      entry Await (Passed : out Boolean) when Ready is
      begin
         Passed := Value;
         Ready := False;
      end Await;
   end Results;

   task type Runner (Model : Flyology.Execution_Model) is
      pragma Task_Info (Model);
   end Runner;

   task body Runner is
      Passed : Boolean := True;
   begin
      --  The familiar high-level connection owns its lease while the scoped
      --  operation composes with an ordinary timer and success gate.
      declare
         Manager      : aliased Connections.Server (Capacity => 1);
         Item         : aliased Connections.Connection (Manager'Access);
         Socket, Peer : Sockets.Socket_Type;
         Data         : aliased Stream_Element_Array := [1 => 0, 2 => 0, 3 => 0];
         Sent         : constant Stream_Element_Array := [1 => 11, 2 => 12, 3 => 13];
      begin
         Sockets.Create_Socket_Pair (Socket, Peer);
         Connections.Take (Manager, Socket, Item);
         declare
            Set     : aliased Flyology.Operations.Completion_Set (3);
            Get     : aliased Connections.Receive_Exactly_Operation :=
              Connections.Receive_Exactly (Set'Access, Item'Access, Data'Access, Timeout => 1.0);
            Alarm   : aliased Flyology.IO.Timers.Timer_Operation :=
              Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
            First   : Flyology.Operations.Gate_Operation :=
              Flyology.Operations.Wait_For_Success (Set'Access, [Ref (Get), Ref (Alarm)]);
            Batch   : Flyology.Operations.Completion_Batch (Set.Capacity);
            Matches : Flyology.Operations.Completion_Batch (Set.Capacity);
         begin
            Sockets.Send_All (Peer, Sent);
            loop
               exit when Flyology.Operations.Is_Terminal (First);
               Flyology.Operations.Wait_Some (Set, Batch);
            end loop;
            Flyology.Operations.Finish (First, Matches);
            Connections.Finish (Get);
            Passed :=
              Passed and then Data = Sent and then Matches.Count = 1 and then Connections.Is_Open (Item);
            if Flyology.Operations.Is_Active (Alarm) then
               Flyology.Operations.Cancel (Alarm);
            end if;
            begin
               Flyology.IO.Timers.Finish (Alarm);
            exception
               when Flyology.Operations.Operation_Cancelled =>
                  null;
            end;
         end;
         Connections.Close (Item);
         Sockets.Close_Socket (Peer);
      end;

      --  A class-wide higher-level transport stores a definite Connection
      --  capability without knowing its caller's Completion_Set. Its outer
      --  operation owns the only slot and arms the capability's hidden lease,
      --  lifecycle, and transport sources. Exercise plaintext and a TLS
      --  receive whose provider asks for the opposite write direction.
      for Use_TLS in Boolean loop
         declare
            Manager      : aliased Connections.Server (Capacity => 1);
            Item         : aliased Connections.Connection (Manager'Access);
            Socket, Peer : Sockets.Socket_Type;
            Backend      : Provider.Provider;
            Data         : aliased Stream_Element_Array := [1 => 0];
            Channel      : aliased Connection_Transport (Item'Access);
         begin
            Sockets.Create_Socket_Pair (Socket, Peer);
            Connections.Take (Manager, Socket, Item);
            if Use_TLS then
               Provider.Set_Script
                 (Backend, Provider.Handshake_Operation, [1 => (TLS.Complete, Provider.Preserve_Output, 0)]);
               Provider.Set_Script
                 (Backend,
                  Provider.Receive_Operation,
                  [1 => (TLS.Want_Write, Provider.Preserve_Output, 0),
                   2 => (TLS.Complete, Provider.Advance_Output, 1)]);
               Connection_TLS.Upgrade (Item, Backend, TLS.Server, "", Timeout => 1.0);
            else
               Sockets.Send_All (Peer, [1 => 71]);
            end if;
            declare
               Set : aliased Flyology.Operations.Completion_Set (1);
               Get : Synthetic_Receive_Operation (Set'Access, Channel'Access);
            begin
               Get.Data := Data'Unchecked_Access;
               Flyology.Operations.Drivers.Start (Get);
               Flyology.Operations.Drive
                 (Flyology.Operations.Operation'Class (Get), Flyology.Operations.Start_Operation);
               Flyology.Operations.Wait_All (Set);
               Passed :=
                 Passed
                 and then Flyology.Operations.Outcome (Get) = Flyology.Operations.Succeeded
                 and then Data (1) = (if Use_TLS then 42 else 71)
                 and then not Connection_Drivers.Is_Engaged (Channel.IO);
               Flyology.Operations.Consume (Get);
            end;
            Connections.Close (Item);
            Sockets.Close_Socket (Peer);
         end;
      end loop;

      --  The combined transport/outbound arming overload consumes an already
      --  pending coalesced notification before rescheduling. Reusing the same
      --  wakeup for a subsequent transport wait proves no stale signal spins.
      declare
         Manager      : aliased Connections.Server (Capacity => 1);
         Item         : aliased Connections.Connection (Manager'Access);
         Socket, Peer : Sockets.Socket_Type;
         Channel      : aliased Connection_Transport (Item'Access);
         Published    : aliased Boolean := True;
         Data         : aliased Stream_Element_Array := [1 => 0];
      begin
         Sockets.Create_Socket_Pair (Socket, Peer);
         Connections.Take (Manager, Socket, Item);
         Connection_Drivers.Signal (Channel.Wakeup);
         declare
            Set : aliased Flyology.Operations.Completion_Set (1);
            Get : Synthetic_Receive_Operation (Set'Access, Channel'Access);
         begin
            Get.Data := Data'Unchecked_Access;
            Get.Protocol_Ready := Published'Unchecked_Access;
            Flyology.Operations.Drivers.Start (Get);
            Flyology.Operations.Drive
              (Flyology.Operations.Operation'Class (Get), Flyology.Operations.Start_Operation);
            Flyology.Operations.Wait_All (Set);
            Passed := Passed and then Flyology.Operations.Outcome (Get) = Flyology.Operations.Succeeded;
            Flyology.Operations.Consume (Get);
         end;
         Published := False;
         declare
            Set : aliased Flyology.Operations.Completion_Set (1);
            Get : Synthetic_Receive_Operation (Set'Access, Channel'Access);
         begin
            Get.Data := Data'Unchecked_Access;
            Flyology.Operations.Drivers.Start (Get);
            Flyology.Operations.Drive
              (Flyology.Operations.Operation'Class (Get), Flyology.Operations.Start_Operation);
            Sockets.Send_All (Peer, [1 => 73]);
            Flyology.Operations.Wait_All (Set);
            Passed :=
              Passed
              and then Flyology.Operations.Outcome (Get) = Flyology.Operations.Succeeded
              and then Data = [1 => 73];
            Flyology.Operations.Consume (Get);
         end;
         Connections.Close (Item);
         Sockets.Close_Socket (Peer);
      end;

      --  A notification published after readiness is armed wakes the same
      --  owner operation without a helper operation or visible descriptor.
      declare
         Manager      : aliased Connections.Server (Capacity => 1);
         Item         : aliased Connections.Connection (Manager'Access);
         Socket, Peer : Sockets.Socket_Type;
         Channel      : aliased Connection_Transport (Item'Access);
         Published    : aliased Boolean := False;
         Data         : aliased Stream_Element_Array := [1 => 0];
      begin
         Sockets.Create_Socket_Pair (Socket, Peer);
         Connections.Take (Manager, Socket, Item);
         declare
            Set : aliased Flyology.Operations.Completion_Set (1);
            Get : Synthetic_Receive_Operation (Set'Access, Channel'Access);
         begin
            Get.Data := Data'Unchecked_Access;
            Get.Protocol_Ready := Published'Unchecked_Access;
            Flyology.Operations.Drivers.Start (Get);
            Flyology.Operations.Drive
              (Flyology.Operations.Operation'Class (Get), Flyology.Operations.Start_Operation);
            Published := True;
            Connection_Drivers.Signal (Channel.Wakeup);
            Flyology.Operations.Wait_All (Set);
            Passed := Passed and then Flyology.Operations.Outcome (Get) = Flyology.Operations.Succeeded;
            Flyology.Operations.Consume (Get);
         end;
         Connections.Close (Item);
         Sockets.Close_Socket (Peer);
      end;

      --  The readiness set coexists with the capability's absolute deadline.
      declare
         Manager      : aliased Connections.Server (Capacity => 1);
         Item         : aliased Connections.Connection (Manager'Access);
         Socket, Peer : Sockets.Socket_Type;
         Channel      : aliased Connection_Transport (Item'Access);
         Data         : aliased Stream_Element_Array := [1 => 0];
      begin
         Sockets.Create_Socket_Pair (Socket, Peer);
         Connections.Take (Manager, Socket, Item);
         Channel.Timeout := 0.005;
         declare
            Set : aliased Flyology.Operations.Completion_Set (1);
            Get : Synthetic_Receive_Operation (Set'Access, Channel'Access);
         begin
            Get.Data := Data'Unchecked_Access;
            Flyology.Operations.Drivers.Start (Get);
            Flyology.Operations.Drive
              (Flyology.Operations.Operation'Class (Get), Flyology.Operations.Start_Operation);
            Flyology.Operations.Wait_All (Set);
            Passed := Passed and then Flyology.Operations.Outcome (Get) = Flyology.Operations.Failed;
            Flyology.Operations.Consume (Get);
         end;
         Connections.Close (Item);
         Sockets.Close_Socket (Peer);
      end;

      --  Lease acquisition is itself composable: a second outer transport
      --  operation arms the connection lease source and resumes after the
      --  first set-independent capability releases it. Finalization also
      --  abandons a registered capability that never acquired the lease.
      declare
         Manager       : aliased Connections.Server (Capacity => 1);
         Item          : aliased Connections.Connection (Manager'Access);
         Socket, Peer  : Sockets.Socket_Type;
         Holder        : Connection_Drivers.Capability;
         Holder_Result : Connection_Drivers.Acquisition_Result;
         Data          : aliased Stream_Element_Array := [1 => 0];
         Channel       : aliased Connection_Transport (Item'Access);
      begin
         Sockets.Create_Socket_Pair (Socket, Peer);
         Connections.Take (Manager, Socket, Item);
         Connection_Drivers.Start (Holder, Item'Access, Holder_Result, Timeout => 1.0);
         Passed := Passed and then Holder_Result = Connection_Drivers.Acquired;
         declare
            Set : aliased Flyology.Operations.Completion_Set (1);
            Get : Synthetic_Receive_Operation (Set'Access, Channel'Access);
         begin
            Get.Data := Data'Unchecked_Access;
            Flyology.Operations.Drivers.Start (Get);
            Flyology.Operations.Drive
              (Flyology.Operations.Operation'Class (Get), Flyology.Operations.Start_Operation);
            Connection_Drivers.Release (Holder);
            Sockets.Send_All (Peer, [1 => 72]);
            Flyology.Operations.Wait_All (Set);
            Passed :=
              Passed
              and then Flyology.Operations.Outcome (Get) = Flyology.Operations.Succeeded
              and then Data (1) = 72;
            Flyology.Operations.Consume (Get);
         end;
         Connection_Drivers.Start (Holder, Item'Access, Holder_Result, Timeout => 1.0);
         declare
            Waiting : Connection_Drivers.Capability;
            Result  : Connection_Drivers.Acquisition_Result;
         begin
            Connection_Drivers.Start (Waiting, Item'Access, Result, Timeout => 1.0);
            Passed := Passed and then Result = Connection_Drivers.Need_Acquire_Readiness;
         end;
         Connection_Drivers.Release (Holder);
         Connections.Close (Item);
         Sockets.Close_Socket (Peer);
      end;

      --  Two operations on one Connection serialize through its existing
      --  generation-safe lease. The first completion releases that lease
      --  before its retained result is consumed, allowing the second to run.
      declare
         Manager      : aliased Connections.Server (Capacity => 1);
         Item         : aliased Connections.Connection (Manager'Access);
         Socket, Peer : Sockets.Socket_Type;
         Incoming     : aliased Stream_Element_Array := [1 => 0];
         Outgoing     : aliased Stream_Element_Array := [1 => 71, 2 => 72];
         Peer_Data    : Stream_Element_Array (Outgoing'Range);
      begin
         Sockets.Create_Socket_Pair (Socket, Peer);
         Connections.Take (Manager, Socket, Item);
         declare
            Set : aliased Flyology.Operations.Completion_Set (2);
            Get : Connections.Receive_Exactly_Operation :=
              Connections.Receive_Exactly (Set'Access, Item'Access, Incoming'Access, 1.0);
            Put : Connections.Send_All_Operation :=
              Connections.Send_All (Set'Access, Item'Access, Outgoing'Access, 1.0);
         begin
            Sockets.Send_All (Peer, [1 => 33]);
            Flyology.Operations.Wait_All (Set);
            Check
              (Flyology.Operations.Is_Terminal (Get) and then Flyology.Operations.Is_Terminal (Put),
               "serialized connection operations did not both complete");
            --  Put acquired the lease even though Get remains terminal and
            --  has not yet been consumed.
            Sockets.Receive_Exactly (Peer, Peer_Data, Timeout => 1.0);
            Connections.Finish (Get);
            Connections.Finish (Put);
            Passed := Passed and then Incoming = [1 => 33] and then Peer_Data = Outgoing;
         end;
         Connections.Close (Item);
         Sockets.Close_Socket (Peer);
      end;

      --  Token cancellation and a lease-wide deadline are retained until the
      --  typed Finish boundary without leaving Close blocked.
      declare
         Manager                  : aliased Connections.Server (Capacity => 1);
         Item                     : aliased Connections.Connection (Manager'Access);
         Socket, Peer             : Sockets.Socket_Type;
         Data                     : aliased Stream_Element_Array := [1 => 0];
         Token                    : aliased Flyology.Cancellation.Token;
         Was_Cancelled, Timed_Out : Boolean := False;
         Last                     : Stream_Element_Offset;
      begin
         Sockets.Create_Socket_Pair (Socket, Peer);
         Connections.Take (Manager, Socket, Item);
         declare
            Set       : aliased Flyology.Operations.Completion_Set (2);
            Cancelled : Connections.Receive_Operation :=
              Connections.Receive (Set'Access, Item'Access, Data'Access, 1.0, Token'Access);
            Timed     : Connections.Receive_Operation (Set'Access);
         begin
            Token.Request;
            Flyology.Operations.Wait_All (Set);
            begin
               Connections.Finish (Cancelled, Last);
            exception
               when Connections.Operation_Cancelled =>
                  Was_Cancelled := True;
            end;
            Connections.Receive (Item'Access, Data'Access, 0.005, null, Timed);
            Flyology.Operations.Wait_All (Set);
            begin
               Connections.Finish (Timed, Last);
            exception
               when Flyology.IO.Timeout_Error =>
                  Timed_Out := True;
            end;
         end;
         Passed := Passed and then Was_Cancelled and then Timed_Out;
         Connections.Close (Item);
         Sockets.Close_Socket (Peer);
      end;

      --  Explicit operation cancellation and abandoned-object finalization
      --  both release the connection lease before the next user of Item.
      declare
         Manager              : aliased Connections.Server (Capacity => 1);
         Item                 : aliased Connections.Connection (Manager'Access);
         Socket, Peer         : Sockets.Socket_Type;
         Data                 : aliased Stream_Element_Array := [1 => 0];
         Explicitly_Cancelled : Boolean := False;
         Last                 : Stream_Element_Offset;
      begin
         Sockets.Create_Socket_Pair (Socket, Peer);
         Connections.Take (Manager, Socket, Item);
         declare
            Set     : aliased Flyology.Operations.Completion_Set (1);
            Pending : Connections.Receive_Operation :=
              Connections.Receive (Set'Access, Item'Access, Data'Access, Timeout => Flyology.IO.Infinite);
         begin
            Flyology.Operations.Cancel (Pending);
            Flyology.Operations.Wait_All (Set);
            begin
               Connections.Finish (Pending, Last);
            exception
               when Connections.Operation_Cancelled =>
                  Explicitly_Cancelled := True;
            end;
         end;
         declare
            Set       : aliased Flyology.Operations.Completion_Set (1);
            Abandoned : Connections.Receive_Operation :=
              Connections.Receive (Set'Access, Item'Access, Data'Access, Timeout => Flyology.IO.Infinite);
            pragma Unreferenced (Abandoned);
         begin
            null;
         end;
         Passed := Passed and then Explicitly_Cancelled and then Connections.Is_Open (Item);
         Connections.Close (Item);
         Sockets.Close_Socket (Peer);
      end;

      --  Orderly plaintext EOF succeeds for one-chunk Receive, but an early
      --  EOF is a Device_Error for Receive_Exactly, matching synchronous API
      --  semantics at the typed Finish boundary.
      declare
         Manager                            : aliased Connections.Server (Capacity => 2);
         Partial                            : aliased Connections.Connection (Manager'Access);
         Exact                              : aliased Connections.Connection (Manager'Access);
         Socket_1, Peer_1, Socket_2, Peer_2 : Sockets.Socket_Type;
         Data_1                             : aliased Stream_Element_Array := [1 => 0];
         Data_2                             : aliased Stream_Element_Array := [1 => 0];
         Last                               : Stream_Element_Offset := Data_1'First;
         Exact_Failed                       : Boolean := False;
      begin
         Sockets.Create_Socket_Pair (Socket_1, Peer_1);
         Sockets.Create_Socket_Pair (Socket_2, Peer_2);
         Sockets.Prepare (Socket_1);
         Sockets.Prepare (Socket_2);
         Connections.Take (Manager, Socket_1, Partial);
         Connections.Take (Manager, Socket_2, Exact);
         Sockets.Close_Socket (Peer_1);
         Sockets.Close_Socket (Peer_2);
         declare
            Set : aliased Flyology.Operations.Completion_Set (1);
            One : Connections.Receive_Operation :=
              Connections.Receive (Set'Access, Partial'Access, Data_1'Access, 1.0);
         begin
            Flyology.Operations.Wait_All (Set);
            Connections.Finish (One, Last);
         end;
         declare
            Set      : aliased Flyology.Operations.Completion_Set (1);
            All_Data : Connections.Receive_Exactly_Operation :=
              Connections.Receive_Exactly (Set'Access, Exact'Access, Data_2'Access, 1.0);
         begin
            Flyology.Operations.Wait_All (Set);
            begin
               Connections.Finish (All_Data);
            exception
               when Flyology.IO.Device_Error =>
                  Exact_Failed := True;
            end;
         end;
         Passed := Passed and then Last = Data_1'First - 1 and then Exact_Failed;
         Connections.Close (Partial);
         Connections.Close (Exact);
      end;

      --  Close from another task wakes a pending scoped operation, waits for
      --  its registration and lease to drain, and leaves cancellation at the
      --  typed Finish boundary. This is the lifecycle source that requires a
      --  connection operation to arm more than its transport descriptor.
      declare
         Manager       : aliased Connections.Server (Capacity => 1);
         Item          : aliased Connections.Connection (Manager'Access);
         Socket, Peer  : Sockets.Socket_Type;
         Data          : aliased Stream_Element_Array := [1 => 0];
         Was_Cancelled : Boolean := False;

         task type Closer (Target : not null access Connections.Connection'Class);

         task body Closer is
         begin
            Connections.Close (Target.all);
         end Closer;
      begin
         Sockets.Create_Socket_Pair (Socket, Peer);
         Connections.Take (Manager, Socket, Item);
         declare
            Set        : aliased Flyology.Operations.Completion_Set (1);
            Pending    : Connections.Receive_Exactly_Operation :=
              Connections.Receive_Exactly
                (Set'Access, Item'Access, Data'Access, Timeout => Flyology.IO.Infinite);
            Close_Item : Closer (Item'Access);
            pragma Unreferenced (Close_Item);
         begin
            Flyology.Operations.Wait_All (Set);
            begin
               Connections.Finish (Pending);
            exception
               when Connections.Operation_Cancelled =>
                  Was_Cancelled := True;
            end;
         end;
         Passed := Passed and then Was_Cancelled and then not Connections.Is_Open (Item);
         Sockets.Close_Socket (Peer);
      end;

      --  TLS upgrade is itself a first-class operation. Provider setup is
      --  eager, while WANT_WRITE/WANT_READ handshake progress composes with
      --  an ordinary timer and success gate without exposing TLS internals.
      declare
         Manager      : aliased Connections.Server (Capacity => 1);
         Item         : aliased Connections.Connection (Manager'Access);
         Socket, Peer : Sockets.Socket_Type;
         Backend      : aliased Provider.Provider;
      begin
         Provider.Reset_State_Telemetry;
         Provider.Set_Script
           (Backend,
            Provider.Handshake_Operation,
            [1 => (TLS.Want_Write, Provider.Preserve_Output, 0),
             2 => (TLS.Want_Read, Provider.Preserve_Output, 0),
             3 => (TLS.Complete, Provider.Preserve_Output, 0)]);
         Sockets.Create_Socket_Pair (Socket, Peer);
         Connections.Take (Manager, Socket, Item);
         --  The scripted provider does not consume transport bytes, so keep
         --  read readiness persistent for its WANT_READ step.
         Sockets.Send_All (Peer, [1 => 97]);
         declare
            Set     : aliased Flyology.Operations.Completion_Set (3);
            Secure  : aliased Connection_TLS.Upgrade_Operation :=
              Connection_TLS.Upgrade
                (Set'Access, Item'Access, Backend'Access, TLS.Server, "", Timeout => 1.0);
            Alarm   : aliased Flyology.IO.Timers.Timer_Operation :=
              Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
            First   : Flyology.Operations.Gate_Operation :=
              Flyology.Operations.Wait_For_Success (Set'Access, [Ref (Secure), Ref (Alarm)]);
            Batch   : Flyology.Operations.Completion_Batch (Set.Capacity);
            Matches : Flyology.Operations.Completion_Batch (Set.Capacity);
         begin
            loop
               exit when Flyology.Operations.Is_Terminal (First);
               Flyology.Operations.Wait_Some (Set, Batch);
            end loop;
            Flyology.Operations.Finish (First, Matches);
            Connection_TLS.Finish (Secure);
            Passed := Passed and then Matches.Count = 1 and then Connections.Is_Open (Item);
            if Flyology.Operations.Is_Active (Alarm) then
               Flyology.Operations.Cancel (Alarm);
            end if;
            begin
               Flyology.IO.Timers.Finish (Alarm);
            exception
               when Flyology.Operations.Operation_Cancelled =>
                  null;
            end;
         end;
         Connections.Close (Item);
         Sockets.Close_Socket (Peer);
      end;

      --  Provider setup failure is retained until typed Finish and happens
      --  before the transport transition, so the plaintext connection remains
      --  usable. This also exercises the reusable initiating overload.
      declare
         Manager          : aliased Connections.Server (Capacity => 1);
         Item             : aliased Connections.Connection (Manager'Access);
         Socket, Peer     : Sockets.Socket_Type;
         Backend          : aliased Provider.Provider;
         Failed_At_Finish : Boolean := False;
         Set              : aliased Flyology.Operations.Completion_Set (1);
         Secure           : Connection_TLS.Upgrade_Operation (Set'Access);
      begin
         Provider.Set_Available (Backend, False);
         Sockets.Create_Socket_Pair (Socket, Peer);
         Connections.Take (Manager, Socket, Item);
         Connection_TLS.Upgrade
           (Item'Access, Backend'Access, TLS.Server, "", Timeout => 1.0, Operation => Secure);
         Flyology.Operations.Wait_All (Set);
         begin
            Connection_TLS.Finish (Secure);
         exception
            when TLS.TLS_Error =>
               Failed_At_Finish := True;
         end;
         Passed := Passed and then Failed_At_Finish and then Connections.Is_Open (Item);
         Connections.Close (Item);
         Sockets.Close_Socket (Peer);
      end;

      --  Timeout and explicit cancellation after a session is installed must
      --  both drain provider state and close the now-non-plaintext connection.
      for Cancel_Explicitly in Boolean loop
         declare
            Manager      : aliased Connections.Server (Capacity => 1);
            Item         : aliased Connections.Connection (Manager'Access);
            Socket, Peer : Sockets.Socket_Type;
            Backend      : aliased Provider.Provider;
            Saw_Expected : Boolean := False;
         begin
            Provider.Set_Script
              (Backend, Provider.Handshake_Operation, [1 => (TLS.Want_Read, Provider.Preserve_Output, 0)]);
            Sockets.Create_Socket_Pair (Socket, Peer);
            Connections.Take (Manager, Socket, Item);
            declare
               Set    : aliased Flyology.Operations.Completion_Set (1);
               Secure : Connection_TLS.Upgrade_Operation :=
                 Connection_TLS.Upgrade
                   (Set'Access,
                    Item'Access,
                    Backend'Access,
                    TLS.Server,
                    "",
                    Timeout => (if Cancel_Explicitly then Flyology.IO.Infinite else 0.005));
            begin
               if Cancel_Explicitly then
                  Flyology.Operations.Cancel (Secure);
               end if;
               Flyology.Operations.Wait_All (Set);
               begin
                  Connection_TLS.Finish (Secure);
               exception
                  when Connections.Operation_Cancelled =>
                     Saw_Expected := Cancel_Explicitly;
                  when Flyology.IO.Timeout_Error =>
                     Saw_Expected := not Cancel_Explicitly;
               end;
            end;
            Passed := Passed and then Saw_Expected and then not Connections.Is_Open (Item);
            Sockets.Close_Socket (Peer);
         end;
      end loop;

      --  The same operation types transparently drive an upgraded TLS
      --  transport. WANT_WRITE from receive and WANT_READ from send select
      --  the opposite descriptor direction; partial TLS progress reschedules
      --  on the owner stack without waiting for a new kernel event.
      declare
         Manager      : aliased Connections.Server (Capacity => 1);
         Item         : aliased Connections.Connection (Manager'Access);
         Socket, Peer : Sockets.Socket_Type;
         Backend      : Provider.Provider;
         Incoming     : aliased Stream_Element_Array := [1 => 0, 2 => 0];
         Outgoing     : aliased Stream_Element_Array := [1 => 81, 2 => 82];
         Set          : aliased Flyology.Operations.Completion_Set (4);
         Get          : Connections.Receive_Exactly_Operation (Set'Access);
         Put          : Connections.Send_All_Operation (Set'Access);
         State        : Provider.State_Telemetry;
      begin
         Provider.Reset_State_Telemetry;
         Provider.Set_Script
           (Backend, Provider.Handshake_Operation, [1 => (TLS.Complete, Provider.Preserve_Output, 0)]);
         Provider.Set_Script
           (Backend,
            Provider.Receive_Operation,
            [1 => (TLS.Want_Write, Provider.Preserve_Output, 0),
             2 => (TLS.Want_Read, Provider.Preserve_Output, 0),
             3 => (TLS.Complete, Provider.Advance_Output, 1),
             4 => (TLS.Complete, Provider.Advance_Output, 1),
             5 => (TLS.Peer_Closed, Provider.Preserve_Output, 0),
             6 => (TLS.Complete, Provider.Preserve_Output, 0)]);
         Provider.Set_Script
           (Backend,
            Provider.Send_Operation,
            [1 => (TLS.Want_Read, Provider.Preserve_Output, 0),
             2 => (TLS.Want_Write, Provider.Preserve_Output, 0),
             3 => (TLS.Complete, Provider.Advance_Output, 1),
             4 => (TLS.Complete, Provider.Advance_Output, 1)]);
         Sockets.Create_Socket_Pair (Socket, Peer);
         Connections.Take (Manager, Socket, Item);
         Connection_TLS.Upgrade (Item, Backend, TLS.Server, "", Timeout => 1.0);
         --  Keep the descriptor readable while the scripted provider asks for
         --  read readiness. The test provider itself does not consume it.
         Sockets.Send_All (Peer, [1 => 99]);

         Connections.Receive_Exactly (Item'Access, Incoming'Access, 1.0, null, Get);
         Flyology.Operations.Wait_All (Set);
         Connections.Finish (Get);
         Connections.Send_All (Item'Access, Outgoing'Access, 1.0, null, Put);
         Flyology.Operations.Wait_All (Set);
         Connections.Finish (Put);
         Provider.Get_State_Telemetry (State);
         Passed :=
           Passed
           and then Incoming = [42, 42]
           and then State.Calls (Provider.Receive_Operation) = 4
           and then State.Calls (Provider.Send_Operation) = 4;

         --  Exact receive retains the synchronous TLS_Error classification
         --  for peer close, and provider progress violations also fail only
         --  when the typed result is consumed.
         declare
            Closed     : Connections.Receive_Exactly_Operation :=
              Connections.Receive_Exactly (Set'Access, Item'Access, Incoming'Access, 1.0);
            Raised_TLS : Boolean := False;
         begin
            Flyology.Operations.Wait_All (Set);
            begin
               Connections.Finish (Closed);
            exception
               when TLS.TLS_Error =>
                  Raised_TLS := True;
            end;
            Passed := Passed and then Raised_TLS;
         end;
         declare
            Invalid    : Connections.Receive_Operation :=
              Connections.Receive (Set'Access, Item'Access, Incoming'Access, 1.0);
            Raised_TLS : Boolean := False;
            Last       : Stream_Element_Offset;
         begin
            Flyology.Operations.Wait_All (Set);
            begin
               Connections.Finish (Invalid, Last);
            exception
               when TLS.TLS_Error =>
                  Raised_TLS := True;
            end;
            Passed := Passed and then Raised_TLS;
         end;
         Connections.Close (Item);
         Sockets.Close_Socket (Peer);
      end;

      Check (Passed, "high-level connection operation matrix failed");
      Results.Publish (Passed);
   exception
      when Error : others =>
         Ada.Text_IO.Put_Line (Ada.Exceptions.Exception_Information (Error));
         Results.Publish (False);
   end Runner;

   type Runner_Access is access Runner;
   Native      : Runner_Access;
   Lightweight : Runner_Access;
   pragma Unreferenced (Native, Lightweight);
   Passed      : Boolean;
begin
   Native := new Runner (Flyology.Native_Task);
   Results.Await (Passed);
   pragma Assert (Passed);

   Lightweight := new Runner (Flyology.Lightweight_Task);
   Results.Await (Passed);
   pragma Assert (Passed);
end Connection_Operations_Smoke;
