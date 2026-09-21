with Ada.Unchecked_Conversion;
with Flyology.Channel_Buckets;
with Flyology.Channel_Test_Hooks;
with Flyology.Channel_Policy;
with Flyology.Operations.Drivers;
with Flyology.Wake_Sources;
with System.Tasking;

package body Flyology.Channels.Bounded is

   package Policy renames Flyology.Channel_Policy;

   use type System.Address;
   use type Flyology.Operations.Driver_Event;
   use type Interfaces.C.int;
   use type Interfaces.C.unsigned;
   use type Flyology.Wake_Sources.Signal_Attempt_Result;

   type Channel_Operation_Access is access all Channel_Operation;
   function To_Operation is new Ada.Unchecked_Conversion (System.Address, Channel_Operation_Access);

   subtype Bucket_Index is Flyology.Channel_Buckets.Bucket_Index;
   type Subscription_Queue is record
      Head : System.Address := System.Null_Address;
      Tail : System.Address := System.Null_Address;
   end record;
   type Queue_Array is array (Bucket_Index) of Subscription_Queue;
   type Subscription_Count_Array is array (Bucket_Index) of Interfaces.C.unsigned with Atomic_Components;
   Active_Subscriptions : Subscription_Count_Array := (others => 0);

   procedure Check_Outer_Protected_Action is
   begin
      if System.Tasking.Self.Common.Protected_Action_Nesting > 0 then
         raise Program_Error with "potentially blocking operation";
      end if;
   end Check_Outer_Protected_Action;

   function Bucket (Address : System.Address) return Bucket_Index
   is (Flyology.Channel_Buckets.Bucket (Address, Channel'Alignment));

   --  Queue links are mutated only while Subscriptions is protected.
   procedure Append (Queue : in out Subscription_Queue; Operation : System.Address) is
      Target : constant Channel_Operation_Access := To_Operation (Operation);
   begin
      if Target = null
        or else Target.Next /= System.Null_Address
        or else Target.Previous /= System.Null_Address
      then
         raise Program_Error with "invalid channel subscription links";
      end if;
      Target.Previous := Queue.Tail;
      if Queue.Tail = System.Null_Address then
         Queue.Head := Operation;
      else
         To_Operation (Queue.Tail).Next := Operation;
      end if;
      Queue.Tail := Operation;
   end Append;

   procedure Remove (Queue : in out Subscription_Queue; Operation : System.Address) is
      Target : constant Channel_Operation_Access := To_Operation (Operation);
   begin
      if Target = null
        or else (Target.Previous = System.Null_Address and then Queue.Head /= Operation)
        or else (Target.Next = System.Null_Address and then Queue.Tail /= Operation)
      then
         raise Program_Error with "channel subscription link is stale";
      end if;
      if Target.Previous = System.Null_Address then
         Queue.Head := Target.Next;
      else
         To_Operation (Target.Previous).Next := Target.Next;
      end if;
      if Target.Next = System.Null_Address then
         Queue.Tail := Target.Previous;
      else
         To_Operation (Target.Next).Previous := Target.Previous;
      end if;
      Target.Next := System.Null_Address;
      Target.Previous := System.Null_Address;
   end Remove;

   procedure Claim_First
     (Ready, In_Flight : in out Subscription_Queue;
      Channel_Address  : System.Address;
      Guard            : in out Notification_Guard)
   is
      Cursor : System.Address := Ready.Head;
   begin
      while Cursor /= System.Null_Address loop
         declare
            Target : constant Channel_Operation_Access := To_Operation (Cursor);
            Next   : constant System.Address := Target.Next;
         begin
            if Target.Item /= null and then Target.Item.all'Address = Channel_Address then
               Remove (Ready, Cursor);
               Append (In_Flight, Cursor);
               Target.In_Flight := True;
               Target.Claim.Start;
               Guard.Target := Cursor;
               Guard.Descriptor := Target.Signal_Descriptor;
               Guard.Kind := Target.Kind;
               Guard.Channel_Address := Channel_Address;
               return;
            end if;
            Cursor := Next;
         end;
      end loop;
   end Claim_First;

   protected body Signal_Claim is
      procedure Start is
      begin
         if In_Flight then
            raise Program_Error with "channel signal claim already in flight";
         end if;
         In_Flight := True;
      end Start;

      procedure Done is
      begin
         In_Flight := False;
      end Done;

      entry Wait when not In_Flight is
      begin
         null;
      end Wait;
   end Signal_Claim;

   procedure Flush (Guard : in out Notification_Guard);

   procedure After_Claim_Barrier (Guard : Notification_Guard) is
   begin
      if Flyology.Channel_Test_Hooks.Enabled then
         if Guard.Target /= System.Null_Address then
            Flyology.Channel_Test_Hooks.After_Signal_Claim_Barrier;
         end if;
      end if;
   end After_Claim_Barrier;

   protected Subscriptions is
      procedure Link (Operation : System.Address);
      procedure Unlink (Operation : System.Address; Guard : in out Notification_Guard);
      procedure Clear_Notification (Operation : System.Address);
      procedure Claim
        (Channel_Address : System.Address;
         Kind            : Scoped_Kind;
         Guard           : in out Notification_Guard;
         Wake_All        : Boolean := False);
      procedure Acknowledge (Guard : in out Notification_Guard);
   private
      Ready_Sends        : Queue_Array;
      Ready_Receives     : Queue_Array;
      In_Flight_Sends    : Queue_Array;
      In_Flight_Receives : Queue_Array;
      Notified_Sends     : Queue_Array;
      Notified_Receives  : Queue_Array;
   end Subscriptions;

   protected body Subscriptions is
      procedure Link (Operation : System.Address) is
         Target : constant Channel_Operation_Access := To_Operation (Operation);
         Index  : Bucket_Index;
      begin
         if Target = null or else Target.Item = null or else Target.Subscribed then
            raise Program_Error with "invalid channel operation subscription";
         end if;
         Index := Bucket (Target.Item.all'Address);
         if Target.Kind = Scoped_Send then
            Append (Ready_Sends (Index), Operation);
         else
            Append (Ready_Receives (Index), Operation);
         end if;
         Target.Subscribed := True;
         Target.Notified := False;
         Active_Subscriptions (Index) := Active_Subscriptions (Index) + 1;
      end Link;

      procedure Unlink (Operation : System.Address; Guard : in out Notification_Guard) is
         Target : constant Channel_Operation_Access := To_Operation (Operation);
         Index  : Bucket_Index;
      begin
         if Target = null or else not Target.Subscribed then
            return;
         end if;
         Index := Bucket (Target.Item.all'Address);
         if Target.Kind = Scoped_Send then
            if Target.In_Flight then
               Remove (In_Flight_Sends (Index), Operation);
            elsif Target.Notified then
               Remove (Notified_Sends (Index), Operation);
            else
               Remove (Ready_Sends (Index), Operation);
            end if;
         elsif Target.In_Flight then
            Remove (In_Flight_Receives (Index), Operation);
         elsif Target.Notified then
            Remove (Notified_Receives (Index), Operation);
         else
            Remove (Ready_Receives (Index), Operation);
         end if;
         declare
            Handoff : constant Boolean := Target.Notified or else Target.In_Flight;
            Kind    : constant Scoped_Kind := Target.Kind;
            Address : constant System.Address := Target.Item.all'Address;
         begin
            Target.Subscribed := False;
            Target.Notified := False;
            Active_Subscriptions (Index) := Active_Subscriptions (Index) - 1;
            --  A cancelled or timed-out operation may have claimed the only
            --  wake for a buffered item. Pass that claim to another waiter.
            if Handoff then
               Guard.Channel_Address := Address;
               Claim (Address, Kind, Guard);
            end if;
         end;
      end Unlink;

      procedure Clear_Notification (Operation : System.Address) is
         Target : constant Channel_Operation_Access := To_Operation (Operation);
         Index  : Bucket_Index;
      begin
         if Target = null or else not Target.Subscribed or else not Target.Notified then
            return;
         end if;
         Index := Bucket (Target.Item.all'Address);
         if Target.Kind = Scoped_Send then
            Remove (Notified_Sends (Index), Operation);
            Append (Ready_Sends (Index), Operation);
         else
            Remove (Notified_Receives (Index), Operation);
            Append (Ready_Receives (Index), Operation);
         end if;
         Target.Notified := False;
      end Clear_Notification;

      procedure Claim
        (Channel_Address : System.Address;
         Kind            : Scoped_Kind;
         Guard           : in out Notification_Guard;
         Wake_All        : Boolean := False)
      is
         Index : constant Bucket_Index := Bucket (Channel_Address);
      begin
         if Guard.Target /= System.Null_Address then
            raise Program_Error with "channel notification guard already holds a claim";
         end if;
         if Wake_All then
            Claim_First (Ready_Sends (Index), In_Flight_Sends (Index), Channel_Address, Guard);
            if Guard.Target = System.Null_Address then
               Claim_First (Ready_Receives (Index), In_Flight_Receives (Index), Channel_Address, Guard);
            end if;
         elsif Kind = Scoped_Send then
            Claim_First (Ready_Sends (Index), In_Flight_Sends (Index), Channel_Address, Guard);
         else
            Claim_First (Ready_Receives (Index), In_Flight_Receives (Index), Channel_Address, Guard);
         end if;
      end Claim;

      procedure Acknowledge (Guard : in out Notification_Guard) is
         Operation : constant System.Address := Guard.Target;
         Target    : constant Channel_Operation_Access := To_Operation (Operation);
         Index     : Bucket_Index;
      begin
         if Target = null or else not Target.In_Flight then
            raise Program_Error with "invalid channel signal acknowledgment";
         end if;
         if Target.Subscribed then
            Index := Bucket (Target.Item.all'Address);
            if Target.Kind = Scoped_Send then
               Remove (In_Flight_Sends (Index), Operation);
               Append (Notified_Sends (Index), Operation);
            else
               Remove (In_Flight_Receives (Index), Operation);
               Append (Notified_Receives (Index), Operation);
            end if;
            Target.Notified := True;
         end if;
         Target.In_Flight := False;
         --  Clear the caller's only retained pointer before the waiter can
         --  reclaim this operation after Claim.Done opens its entry.
         Guard.Target := System.Null_Address;
         Guard.Descriptor := -1;
         Target.Claim.Done;
      end Acknowledge;
   end Subscriptions;

   procedure Flush (Guard : in out Notification_Guard) is
      Failed : Boolean;
   begin
      loop
         if Guard.Target = System.Null_Address then
            exit when not Guard.Wake_All and then not Guard.Retry_After_Failure;
            Subscriptions.Claim
              (Guard.Channel_Address,
               (if Guard.Wake_All then Scoped_Send else Guard.Kind),
               Guard,
               Wake_All => Guard.Wake_All);
            Guard.Retry_After_Failure := False;
            exit when Guard.Target = System.Null_Address;
         end if;
         Failed := False;
         begin
            declare
               Result : Flyology.Wake_Sources.Signal_Attempt_Result;
            begin
               loop
                  if Flyology.Channel_Test_Hooks.Enabled then
                     if Flyology.Channel_Test_Hooks.Take_Bounded_Signal_Failure then
                        Result := Flyology.Wake_Sources.Signal_Failed;
                     elsif Flyology.Channel_Test_Hooks.Take_Bounded_Signal_Interrupt then
                        Result := Flyology.Wake_Sources.Signal_Interrupted;
                     else
                        Result := Flyology.Wake_Sources.Try_Signal_Borrowed (Guard.Descriptor);
                     end if;
                  else
                     Result := Flyology.Wake_Sources.Try_Signal_Borrowed (Guard.Descriptor);
                  end if;
                  exit when Result /= Flyology.Wake_Sources.Signal_Interrupted;
               end loop;
               if Result = Flyology.Wake_Sources.Signal_Failed then
                  Failed := True;
               end if;
            end;
         exception
            --  The channel transition is already committed. An invalid
            --  descriptor belongs to this subscriber, not the producer.
            when others =>
               Failed := True;
         end;
         --  Preserve the handoff obligation across acknowledgment. An abort
         --  after Acknowledge clears Target must still retry in Finalize.
         Guard.Retry_After_Failure := Failed and then not Guard.Wake_All;
         Subscriptions.Acknowledge (Guard);
         if Flyology.Channel_Test_Hooks.Enabled then
            if Guard.Retry_After_Failure then
               Flyology.Channel_Test_Hooks.After_Bounded_Failure_Ack_Barrier;
            end if;
         end if;
         exit when not Guard.Wake_All and then not Guard.Retry_After_Failure;
      end loop;
      Guard.Wake_All := False;
   end Flush;

   overriding
   procedure Finalize (Item : in out Notification_Guard) is
   begin
      begin
         Flush (Item);
         if Item.Drain_Target /= System.Null_Address then
            To_Operation (Item.Drain_Target).Claim.Wait;
            Item.Drain_Target := System.Null_Address;
         end if;
      exception
         when others =>
            null;
      end;
   end Finalize;

   procedure Unlink_Scoped (Operation : System.Address) is
      Guard : Notification_Guard;
   begin
      Guard.Drain_Target := Operation;
      Subscriptions.Unlink (Operation, Guard);
      Flush (Guard);
      To_Operation (Operation).Claim.Wait;
      Guard.Drain_Target := System.Null_Address;
   end Unlink_Scoped;

   procedure Clear_Scoped (Operation : System.Address) is
      Guard : Notification_Guard;
   begin
      Guard.Drain_Target := Operation;
      To_Operation (Operation).Claim.Wait;
      Guard.Drain_Target := System.Null_Address;
      Subscriptions.Clear_Notification (Operation);
   end Clear_Scoped;

   protected body Channel_State is
      procedure Claim_Scoped (Guard : not null access Notification_Guard; For_Receive : Boolean) is
         Index : constant Bucket_Index := Bucket (Guard.Channel_Address);
      begin
         if Active_Subscriptions (Index) /= 0 then
            Subscriptions.Claim
              (Guard.Channel_Address, (if For_Receive then Scoped_Receive else Scoped_Send), Guard.all);
         end if;
      end Claim_Scoped;

      entry Send (Value : Element_Type; Guard : not null access Notification_Guard)
        when Policy.Send_Entry_Open (Stopped, Count, Capacity)
      is
      begin
         case Policy.Classify_Send (Stopped, Count, Capacity) is
            when Policy.Accept_Send  =>
               Buffer (Tail) := Value;
               Tail := Policy.Advance (Tail, Capacity);
               Count := Policy.Count_After_Send (Count, Capacity);
               Claim_Scoped (Guard, For_Receive => True);

            when Policy.Reject_Send  =>
               raise Channel_Closed with "send on closed channel";

            when Policy.Wait_To_Send =>
               raise Program_Error with "channel send entry opened while full";
         end case;
      end Send;

      entry Receive (Value : out Element_Type; Guard : not null access Notification_Guard)
        when Policy.Receive_Entry_Open (Stopped, Count)
      is
         Position : Positive;
      begin
         case Policy.Classify_Receive (Stopped, Count) is
            when Policy.Accept_Receive  =>
               Value := Buffer (Head);
               Policy.Apply_Dequeue (Head, Count, Capacity, Position);
               --  Commit logical removal before clearing controlled storage.
               --  Element operations are required not to raise, but this
               --  ordering prevents a violating finalizer from making the
               --  already-copied item deliverable twice.
               Buffer (Position) := Empty_Value;
               Claim_Scoped (Guard, For_Receive => False);

            when Policy.Reject_Receive  =>
               raise Channel_Closed with "receive from drained channel";

            when Policy.Wait_To_Receive =>
               raise Program_Error with "channel receive entry opened while empty";
         end case;
      end Receive;

      procedure Try_Send_After_Clear
        (Value    : Element_Type;
         Accepted : not null access Boolean;
         Result   : out Try_Send_Result;
         Guard    : not null access Notification_Guard) is
      begin
         case Policy.Classify_Send (Stopped, Count, Capacity) is
            when Policy.Accept_Send  =>
               Buffer (Tail) := Value;
               Tail := Policy.Advance (Tail, Capacity);
               Count := Policy.Count_After_Send (Count, Capacity);
               Result := Item_Sent;
               Accepted.all := True;
               Claim_Scoped (Guard, For_Receive => True);

            when Policy.Wait_To_Send =>
               Result := Channel_Full;

            when Policy.Reject_Send  =>
               Result := Send_Closed;
         end case;
      end Try_Send_After_Clear;

      procedure Try_Receive
        (Value  : in out Element_Type;
         Result : out Try_Receive_Result;
         Guard  : not null access Notification_Guard)
      is
         Position : Positive;
      begin
         case Policy.Classify_Receive (Stopped, Count) is
            when Policy.Accept_Receive  =>
               Value := Buffer (Head);
               Policy.Apply_Dequeue (Head, Count, Capacity, Position);
               Buffer (Position) := Empty_Value;
               Result := Item_Received;
               Claim_Scoped (Guard, For_Receive => False);

            when Policy.Wait_To_Receive =>
               Result := Channel_Empty;

            when Policy.Reject_Receive  =>
               Result := Receive_Closed;
         end case;
      end Try_Receive;

      procedure Close (Guard : not null access Notification_Guard) is
      begin
         Guard.Wake_All := True;
         Stopped := True;
         Subscriptions.Claim (Guard.Channel_Address, Scoped_Receive, Guard.all, Wake_All => True);
      end Close;

      entry Await_Drained when Policy.Is_Drained (Stopped, Count) is
      begin
         null;
      end Await_Drained;

      function Current return Snapshot
      is (Closed            => Stopped,
          Pending           => Count,
          Waiting_Senders   => Channel_State.Send'Count,
          Waiting_Receivers => Channel_State.Receive'Count);
   end Channel_State;

   procedure Close (Item : in out Channel) is
      Guard : aliased Notification_Guard;
   begin
      Check_Outer_Protected_Action;
      Guard.Channel_Address := Item'Address;
      Item.State.Close (Guard'Access);
      After_Claim_Barrier (Guard);
      Flush (Guard);
   end Close;

   procedure Send (Item : in out Channel; Value : Element_Type) is
      Guard : aliased Notification_Guard;
   begin
      Check_Outer_Protected_Action;
      Guard.Channel_Address := Item'Address;
      Item.State.Send (Value, Guard'Access);
      After_Claim_Barrier (Guard);
      Flush (Guard);
   end Send;

   procedure Receive (Item : in out Channel; Value : out Element_Type) is
      Guard : aliased Notification_Guard;
   begin
      Check_Outer_Protected_Action;
      Guard.Channel_Address := Item'Address;
      Item.State.Receive (Value, Guard'Access);
      After_Claim_Barrier (Guard);
      Flush (Guard);
   end Receive;

   procedure Try_Send_After_Clear
     (Item     : in out Channel;
      Value    : Element_Type;
      Accepted : not null access Boolean;
      Result   : out Try_Send_Result)
   is
      Guard : aliased Notification_Guard;
   begin
      Check_Outer_Protected_Action;
      Guard.Channel_Address := Item'Address;
      Item.State.Try_Send_After_Clear (Value, Accepted, Result, Guard'Access);
      After_Claim_Barrier (Guard);
      Flush (Guard);
   end Try_Send_After_Clear;

   procedure Try_Send (Item : in out Channel; Value : Element_Type; Result : out Try_Send_Result) is
      Accepted : aliased Boolean := False;
   begin
      Try_Send_After_Clear (Item, Value, Accepted'Access, Result);
   end Try_Send;

   procedure Try_Receive (Item : in out Channel; Value : in out Element_Type; Result : out Try_Receive_Result)
   is
      Guard : aliased Notification_Guard;
   begin
      Check_Outer_Protected_Action;
      Guard.Channel_Address := Item'Address;
      Item.State.Try_Receive (Value, Result, Guard'Access);
      After_Claim_Barrier (Guard);
      Flush (Guard);
   end Try_Receive;

   procedure Await_Drained (Item : in out Channel) is
   begin
      Item.State.Await_Drained;
   end Await_Drained;

   function Current (Item : Channel) return Snapshot is
   begin
      return Item.State.Current;
   end Current;

   procedure Try_Send
     (Object   : in out Channel;
      Value    : Element_Type;
      Accepted : not null access Boolean;
      Result   : out Try_Send_Result) is
   begin
      Accepted.all := False;
      if Flyology.Channel_Test_Hooks.Enabled then
         Flyology.Channel_Test_Hooks.Before_Send_Barrier;
      end if;
      Object.Try_Send_After_Clear (Value, Accepted, Result);
   end Try_Send;

   procedure Timed_Send (Item : in out Channel; Value : Element_Type; Timeout : Duration) is
      Guard : aliased Notification_Guard;
   begin
      Check_Outer_Protected_Action;
      Guard.Channel_Address := Item'Address;
      if Timeout < 0.0 then
         Item.State.Send (Value, Guard'Access);
      else
         select
            Item.State.Send (Value, Guard'Access);
         or
            delay Timeout;
            raise Timeout_Error with "channel send timed out";
         end select;
      end if;
      After_Claim_Barrier (Guard);
      Flush (Guard);
   end Timed_Send;

   procedure Timed_Receive (Item : in out Channel; Value : out Element_Type; Timeout : Duration) is
      Guard : aliased Notification_Guard;
   begin
      Check_Outer_Protected_Action;
      Guard.Channel_Address := Item'Address;
      if Timeout < 0.0 then
         Item.State.Receive (Value, Guard'Access);
      else
         select
            Item.State.Receive (Value, Guard'Access);
         or
            delay Timeout;
            raise Timeout_Error with "channel receive timed out";
         end select;
      end if;
      After_Claim_Barrier (Guard);
      Flush (Guard);
   end Timed_Receive;

   procedure Try_Scoped (Operation : in out Channel_Operation; Result : out Try_Receive_Result) is
   begin
      case Operation.Kind is
         when Scoped_Send    =>
            declare
               Send_Result : Try_Send_Result;
            begin
               Operation.Item.Try_Send (Operation.Value, Send_Result);
               case Send_Result is
                  when Item_Sent    =>
                     Operation.Value := Empty_Value;
                     Result := Item_Received;

                  when Channel_Full =>
                     Result := Channel_Empty;

                  when Send_Closed  =>
                     Operation.Value := Empty_Value;
                     Operation.Failure := Channel_Closed_Failure;
                     Result := Receive_Closed;
               end case;
            end;

         when Scoped_Receive =>
            Operation.Item.Try_Receive (Operation.Value, Result);
            if Result = Receive_Closed then
               Operation.Failure := Channel_Closed_Failure;
            end if;
      end case;
   end Try_Scoped;

   procedure Start_Scoped
     (Operation : in out Channel_Operation;
      Item      : not null access Channel'Class;
      Kind      : Scoped_Kind;
      Value     : Element_Type;
      Timeout   : Duration)
   is
      Read_Descriptor, Signal_Descriptor : Interfaces.C.int := -1;
      Result                             : Try_Receive_Result;
   begin
      Flyology.Operations.Drivers.Start (Operation);
      --  The public access formal requires an aliased channel, and the scoped
      --  contract requires that channel to outlive the operation. Retain that
      --  structured borrow beyond this initiating call.
      Operation.Item := Item.all'Unchecked_Access;
      Operation.Kind := Kind;
      Operation.Value := Value;
      Operation.Next := System.Null_Address;
      Operation.Previous := System.Null_Address;
      Operation.Signal_Descriptor := -1;
      Operation.Subscribed := False;
      Operation.In_Flight := False;
      Operation.Notified := False;
      Operation.Failure := No_Failure;

      Try_Scoped (Operation, Result);
      if Result = Channel_Empty and then Timeout /= 0.0 then
         Flyology.Operations.Drivers.Completion_Source (Operation, Read_Descriptor, Signal_Descriptor);
         Operation.Signal_Descriptor := Signal_Descriptor;
         --  Subscribe before rechecking. A state transition before Link is
         --  found by the recheck; one after Link signals this operation.
         Subscriptions.Link (Operation'Address);
         Try_Scoped (Operation, Result);
         if Result /= Channel_Empty then
            Unlink_Scoped (Operation'Address);
         end if;
      end if;
      case Result is
         when Item_Received  =>
            Flyology.Operations.Drivers.Complete (Operation, Flyology.Operations.Succeeded);

         when Receive_Closed =>
            Flyology.Operations.Drivers.Complete (Operation, Flyology.Operations.Failed);

         when Channel_Empty  =>
            if Timeout = 0.0 then
               Operation.Value := Empty_Value;
               Operation.Failure := Timeout_Failure;
               Flyology.Operations.Drivers.Complete (Operation, Flyology.Operations.Failed);
            else
               if Timeout > 0.0 then
                  Flyology.Operations.Drivers.Arm_Deadline (Operation, Timeout);
               end if;
               Flyology.Operations.Drivers.Arm_Readiness (Operation, Read_Descriptor, False);
            end if;
      end case;
   exception
      when others =>
         if Operation.Subscribed then
            Unlink_Scoped (Operation'Address);
         end if;
         Operation.Value := Empty_Value;
         Operation.Item := null;
         if Flyology.Operations.Is_Active (Operation) then
            Flyology.Operations.Drivers.Rollback_Start (Operation);
         end if;
         raise;
   end Start_Scoped;

   procedure Send
     (Item      : not null access Channel'Class;
      Value     : Element_Type;
      Timeout   : Duration := -1.0;
      Operation : in out Send_Operation) is
   begin
      Start_Scoped (Channel_Operation (Operation), Item, Scoped_Send, Value, Timeout);
   end Send;

   function Send
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null access Channel'Class;
      Value   : Element_Type;
      Timeout : Duration := -1.0) return Send_Operation is
   begin
      return Result : Send_Operation (Set) do
         Send (Item, Value, Timeout, Result);
      end return;
   end Send;

   procedure Receive
     (Item : not null access Channel'Class; Timeout : Duration := -1.0; Operation : in out Receive_Operation)
   is
   begin
      Start_Scoped (Channel_Operation (Operation), Item, Scoped_Receive, Empty_Value, Timeout);
   end Receive;

   function Receive
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null access Channel'Class;
      Timeout : Duration := -1.0) return Receive_Operation is
   begin
      return Result : Receive_Operation (Set) do
         Receive (Item, Timeout, Result);
      end return;
   end Receive;

   overriding
   procedure Drive (Item : in out Channel_Operation; Event : Flyology.Operations.Driver_Event) is
      Result                             : Try_Receive_Result;
      Read_Descriptor, Signal_Descriptor : Interfaces.C.int;
   begin
      case Event is
         when Flyology.Operations.Start_Operation                                             =>
            raise Program_Error with "channel operation was already started";

         when Flyology.Operations.Source_Ready                                                =>
            --  Clear before rechecking. A concurrent channel transition can
            --  then signal again if this operation loses the race for data.
            Clear_Scoped (Item'Address);
            Try_Scoped (Item, Result);
            if Result /= Channel_Empty then
               Unlink_Scoped (Item'Address);
            end if;

         when Flyology.Operations.Deadline_Reached                                            =>
            Unlink_Scoped (Item'Address);
            Try_Scoped (Item, Result);
            if Result = Channel_Empty then
               Item.Value := Empty_Value;
               Item.Failure := Timeout_Failure;
            end if;

         when Flyology.Operations.Dependency_Changed | Flyology.Operations.Continue_Operation =>
            raise Program_Error with "channel operation received a dependency event";
      end case;

      case Result is
         when Item_Received  =>
            Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Succeeded);

         when Receive_Closed =>
            Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);

         when Channel_Empty  =>
            if Event = Flyology.Operations.Deadline_Reached then
               Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
            else
               Flyology.Operations.Drivers.Completion_Source (Item, Read_Descriptor, Signal_Descriptor);
               Flyology.Operations.Drivers.Arm_Readiness (Item, Read_Descriptor, False);
            end if;
      end case;
   exception
      when others =>
         if Item.Subscribed then
            Unlink_Scoped (Item'Address);
         end if;
         Item.Value := Empty_Value;
         Item.Failure := Driver_Failure;
         Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
   end Drive;

   overriding
   procedure Request_Cancellation (Item : in out Channel_Operation) is
   begin
      if Item.Subscribed then
         Unlink_Scoped (Item'Address);
      end if;
      Item.Value := Empty_Value;
      Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Cancelled);
   end Request_Cancellation;

   procedure Reset (Operation : in out Channel_Operation) is
   begin
      Operation.Item := null;
      Operation.Value := Empty_Value;
      Operation.Next := System.Null_Address;
      Operation.Previous := System.Null_Address;
      Operation.Signal_Descriptor := -1;
      Operation.Subscribed := False;
      Operation.In_Flight := False;
      Operation.Notified := False;
      Operation.Failure := No_Failure;
   end Reset;

   procedure Raise_Failure (Failure : Scoped_Failure) is
   begin
      case Failure is
         when Channel_Closed_Failure =>
            raise Channel_Closed with "scoped channel operation observed close";

         when Timeout_Failure        =>
            raise Timeout_Error with "scoped channel operation timed out";

         when Driver_Failure         =>
            raise Program_Error with "scoped channel operation driver failed";

         when No_Failure             =>
            raise Program_Error with "scoped channel operation failed";
      end case;
   end Raise_Failure;

   procedure Finish (Operation : in out Send_Operation) is
      Outcome : constant Flyology.Operations.Terminal_Outcome := Flyology.Operations.Outcome (Operation);
      Failure : constant Scoped_Failure := Operation.Failure;
   begin
      Flyology.Operations.Consume (Operation);
      Reset (Channel_Operation (Operation));
      case Outcome is
         when Flyology.Operations.Succeeded =>
            null;

         when Flyology.Operations.Cancelled =>
            raise Operation_Cancelled;

         when Flyology.Operations.Failed    =>
            Raise_Failure (Failure);
      end case;
   end Finish;

   procedure Finish (Operation : in out Receive_Operation; Value : out Element_Type) is
      Outcome : constant Flyology.Operations.Terminal_Outcome := Flyology.Operations.Outcome (Operation);
      Failure : constant Scoped_Failure := Operation.Failure;
   begin
      Flyology.Operations.Consume (Operation);
      case Outcome is
         when Flyology.Operations.Succeeded =>
            Value := Operation.Value;
            Reset (Channel_Operation (Operation));

         when Flyology.Operations.Cancelled =>
            Reset (Channel_Operation (Operation));
            raise Operation_Cancelled;

         when Flyology.Operations.Failed    =>
            Reset (Channel_Operation (Operation));
            Raise_Failure (Failure);
      end case;
   end Finish;

end Flyology.Channels.Bounded;
