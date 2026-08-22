with Ada.Unchecked_Conversion;
with Flyology.Channel_Policy;
with Flyology.Operations.Drivers;
with Interfaces;
with Interfaces.C;
with System.Storage_Elements;

package body Flyology.Buffers.Channels is
   package Policy renames Flyology.Channel_Policy;

   use type Flyology.Operations.Driver_Event;
   use type Interfaces.C.unsigned;
   use type System.Address;
   use type System.Storage_Elements.Integer_Address;

   type Channel_Operation_Access is access all Channel_Operation;
   function To_Operation is new Ada.Unchecked_Conversion
     (System.Address, Channel_Operation_Access);

   Bucket_Count : constant := 32;
   subtype Bucket_Index is Positive range 1 .. Bucket_Count;
   type Bucket_Array is array (Bucket_Index) of System.Address;
   type Subscription_Count_Array is
     array (Bucket_Index) of Interfaces.C.unsigned
     with Atomic_Components;
   Active_Subscriptions : Subscription_Count_Array := (others => 0);

   function Bucket (Address : System.Address) return Bucket_Index is
     (Bucket_Index
        (System.Storage_Elements.To_Integer (Address) mod
           System.Storage_Elements.Integer_Address (Bucket_Count) + 1));

   function Source_Address
     (Item : not null Channel_Access) return System.Address is
     (Item.State'Address);

   protected Subscriptions is
      procedure Link (Operation : System.Address);
      procedure Unlink (Operation : System.Address);
      procedure Signal (Source : System.Address);
   private
      Heads : Bucket_Array := (others => System.Null_Address);
   end Subscriptions;

   protected body Subscriptions is
      procedure Link (Operation : System.Address) is
         Target : constant Channel_Operation_Access :=
           To_Operation (Operation);
         Index : Bucket_Index;
      begin
         if Target = null or else Target.Item = null or else Target.Subscribed
         then
            raise Program_Error with
              "invalid buffer channel operation subscription";
         end if;
         Index := Bucket (Source_Address (Target.Item));
         Target.Next := Heads (Index);
         Target.Subscribed := True;
         Heads (Index) := Operation;
         Active_Subscriptions (Index) :=
           Active_Subscriptions (Index) + 1;
      end Link;

      procedure Unlink (Operation : System.Address) is
         Target : constant Channel_Operation_Access :=
           To_Operation (Operation);
         Index : Bucket_Index;
         Cursor, Previous : System.Address;
      begin
         if Target = null or else not Target.Subscribed then
            return;
         end if;
         Index := Bucket (Source_Address (Target.Item));
         Cursor := Heads (Index);
         Previous := System.Null_Address;
         while Cursor /= System.Null_Address and then Cursor /= Operation loop
            Previous := Cursor;
            Cursor := To_Operation (Cursor).Next;
         end loop;
         if Cursor = System.Null_Address then
            raise Program_Error with
              "buffer channel subscription link is stale";
         elsif Previous = System.Null_Address then
            Heads (Index) := Target.Next;
         else
            To_Operation (Previous).Next := Target.Next;
         end if;
         Target.Next := System.Null_Address;
         Target.Subscribed := False;
         Active_Subscriptions (Index) :=
           Active_Subscriptions (Index) - 1;
      end Unlink;

      procedure Signal (Source : System.Address) is
         Cursor : System.Address := Heads (Bucket (Source));
      begin
         while Cursor /= System.Null_Address loop
            declare
               Operation : constant Channel_Operation_Access :=
                 To_Operation (Cursor);
            begin
               if Operation.Item /= null
                 and then Source_Address (Operation.Item) = Source
               then
                  Flyology.Operations.Drivers.Signal_Completion
                    (Operation.all);
               end if;
               Cursor := Operation.Next;
            end;
         end loop;
      end Signal;
   end Subscriptions;

   function To_Stored_Metadata
     (Value : Transfer_Metadata) return Interfaces.Unsigned_64 is
     (Interfaces.Unsigned_64 (Value));

   function From_Stored_Metadata
     (Value : Interfaces.Unsigned_64) return Transfer_Metadata is
     (Transfer_Metadata (Value));

   protected body Channel_State is
      procedure Signal_Scoped is
         Source : constant System.Address :=
           Channel_State'Unchecked_Access.all'Address;
         Index : constant Bucket_Index := Bucket (Source);
      begin
         if Active_Subscriptions (Index) /= 0 then
            Subscriptions.Signal (Source);
         end if;
      end Signal_Scoped;

      --  Take Value's token into the queue. Detach and the queue update run
      --  in one protected action, so no abort can leave the slot owned by
      --  both Value and the channel.
      procedure Enqueue
        (Value    : in out Unique_Buffer;
         Metadata : Transfer_Metadata)
      is
         Position : Positive;
      begin
         Policy.Apply_Enqueue (Tail, Count, Capacity, Position);
         Flyology.Buffers.Drivers.Move_From (Value, Values (Position));
         Flyology.Buffers.Drivers.Set_Channel_Metadata
           (Values (Position), To_Stored_Metadata (Metadata));
      end Enqueue;

      procedure Enqueue
        (Value    : in out Flyology.Buffers.Drivers.Detached_Buffer;
         Metadata : Transfer_Metadata)
      is
         Position : Positive;
      begin
         Policy.Apply_Enqueue (Tail, Count, Capacity, Position);
         Flyology.Buffers.Drivers.Move (Value, Values (Position));
         Flyology.Buffers.Drivers.Set_Channel_Metadata
           (Values (Position), To_Stored_Metadata (Metadata));
      end Enqueue;

      --  Hand the oldest queued token to Target. Attach commits the transfer
      --  before the queue advances, so a rejected token stays queued instead
      --  of being lost, and the caller never holds a dequeued token outside
      --  this protected action.
      procedure Deliver
        (Target   : in out Unique_Buffer;
         Metadata : out Transfer_Metadata)
      is
         Position : Positive;
      begin
         Metadata := From_Stored_Metadata
           (Flyology.Buffers.Drivers.Channel_Metadata (Values (Head)));
         Flyology.Buffers.Drivers.Set_Channel_Metadata (Values (Head), 0);
         Flyology.Buffers.Drivers.Move_To (Values (Head), Target);
         Policy.Apply_Dequeue (Head, Count, Capacity, Position);
      end Deliver;

      procedure Deliver
        (Target   : in out Flyology.Buffers.Drivers.Detached_Buffer;
         Metadata : out Transfer_Metadata)
      is
         Position : Positive;
      begin
         Metadata := From_Stored_Metadata
           (Flyology.Buffers.Drivers.Channel_Metadata (Values (Head)));
         Flyology.Buffers.Drivers.Set_Channel_Metadata (Values (Head), 0);
         Flyology.Buffers.Drivers.Move (Values (Head), Target);
         Policy.Apply_Dequeue (Head, Count, Capacity, Position);
      end Deliver;

      entry Send
        (Value    : in out Unique_Buffer;
         Metadata : Transfer_Metadata;
         Accepted : out Boolean)
        when Policy.Send_Entry_Open (Stopped, Count, Capacity)
      is
      begin
         case Policy.Classify_Send (Stopped, Count, Capacity) is
            when Policy.Accept_Send =>
               Enqueue (Value, Metadata);
               Accepted := True;
               Signal_Scoped;
            when Policy.Reject_Send =>
               Accepted := False;
            when Policy.Wait_To_Send =>
               raise Program_Error with
                 "buffer channel send entry opened while full";
         end case;
      end Send;

      entry Receive
        (Target    : in out Unique_Buffer;
         Metadata  : out Transfer_Metadata;
         Available : out Boolean)
        when Policy.Receive_Entry_Open (Stopped, Count)
      is
      begin
         case Policy.Classify_Receive (Stopped, Count) is
            when Policy.Accept_Receive =>
               Deliver (Target, Metadata);
               Available := True;
               Signal_Scoped;
            when Policy.Reject_Receive =>
               Metadata := No_Metadata;
               Available := False;
            when Policy.Wait_To_Receive =>
               raise Program_Error with
                 "buffer channel receive entry opened while empty";
         end case;
      end Receive;

      procedure Try_Send
        (Value    : in out Unique_Buffer;
         Metadata : Transfer_Metadata;
         Result   : out Try_Send_Result) is
      begin
         case Policy.Classify_Send (Stopped, Count, Capacity) is
            when Policy.Accept_Send =>
               Enqueue (Value, Metadata);
               Result := Item_Sent;
               Signal_Scoped;
            when Policy.Wait_To_Send =>
               Result := Channel_Full;
            when Policy.Reject_Send =>
               Result := Send_Closed;
         end case;
      end Try_Send;

      procedure Try_Receive
        (Target   : in out Unique_Buffer;
         Metadata : out Transfer_Metadata;
         Result   : out Try_Receive_Result) is
      begin
         case Policy.Classify_Receive (Stopped, Count) is
            when Policy.Accept_Receive =>
               Deliver (Target, Metadata);
               Result := Item_Received;
               Signal_Scoped;
            when Policy.Wait_To_Receive =>
               Metadata := No_Metadata;
               Result := Channel_Empty;
            when Policy.Reject_Receive =>
               Metadata := No_Metadata;
               Result := Receive_Closed;
         end case;
      end Try_Receive;

      procedure Try_Send
        (Value    : in out Flyology.Buffers.Drivers.Detached_Buffer;
         Metadata : Transfer_Metadata;
         Result   : out Try_Send_Result) is
      begin
         case Policy.Classify_Send (Stopped, Count, Capacity) is
            when Policy.Accept_Send =>
               Enqueue (Value, Metadata);
               Result := Item_Sent;
               Signal_Scoped;
            when Policy.Wait_To_Send =>
               Result := Channel_Full;
            when Policy.Reject_Send =>
               Result := Send_Closed;
         end case;
      end Try_Send;

      procedure Try_Receive
        (Target   : in out Flyology.Buffers.Drivers.Detached_Buffer;
         Metadata : out Transfer_Metadata;
         Result   : out Try_Receive_Result) is
      begin
         case Policy.Classify_Receive (Stopped, Count) is
            when Policy.Accept_Receive =>
               Deliver (Target, Metadata);
               Result := Item_Received;
               Signal_Scoped;
            when Policy.Wait_To_Receive =>
               Metadata := No_Metadata;
               Result := Channel_Empty;
            when Policy.Reject_Receive =>
               Metadata := No_Metadata;
               Result := Receive_Closed;
         end case;
      end Try_Receive;

      procedure Take_Undelivered
        (Target : in out Flyology.Buffers.Drivers.Detached_Buffer;
         Result : out Try_Receive_Result)
      is
         Position : Positive;
      begin
         case Policy.Classify_Receive (Stopped, Count) is
            when Policy.Accept_Receive =>
               Flyology.Buffers.Drivers.Move (Values (Head), Target);
               Policy.Apply_Dequeue (Head, Count, Capacity, Position);
               Result := Item_Received;
               Signal_Scoped;
            when Policy.Wait_To_Receive =>
               Result := Channel_Empty;
            when Policy.Reject_Receive =>
               Result := Receive_Closed;
         end case;
      end Take_Undelivered;

      procedure Close is
      begin
         Stopped := True;
         Signal_Scoped;
      end Close;

      entry Await_Drained when Policy.Is_Drained (Stopped, Count) is
      begin
         null;
      end Await_Drained;

      function Current return Snapshot is
        (Closed            => Stopped,
         Pending           => Count,
         Waiting_Senders   => Send'Count,
         Waiting_Receivers => Receive'Count);
   end Channel_State;

   procedure Validate_Pools
     (Item  : Channel;
      Value : Unique_Buffer) is
   begin
      if Item.Owner /= Value.Owner then
         raise Program_Error with "buffer belongs to another channel pool";
      end if;
   end Validate_Pools;

   procedure Send_Move
     (Item  : in out Channel;
      Value : in out Unique_Buffer;
      Metadata : Transfer_Metadata := No_Metadata)
   is
      Accepted : Boolean;
   begin
      Validate_Pools (Item, Value);
      if not Has_Buffer (Value) then
         raise Program_Error with "send of a vacant buffer";
      end if;
      Item.State.Send (Value, Metadata, Accepted);
      if not Accepted then
         raise Channel_Closed with "send on closed buffer channel";
      end if;
   end Send_Move;

   procedure Receive_Move
     (Item   : in out Channel;
      Target : in out Unique_Buffer)
   is
      Metadata : Transfer_Metadata;
   begin
      Receive_Move (Item, Target, Metadata);
   end Receive_Move;

   procedure Receive_Move
     (Item     : in out Channel;
      Target   : in out Unique_Buffer;
      Metadata : out Transfer_Metadata)
   is
      Available : Boolean;
   begin
      Metadata := No_Metadata;
      Validate_Pools (Item, Target);
      if Has_Buffer (Target) then
         raise Program_Error with "receive into an occupied buffer";
      end if;
      Item.State.Receive (Target, Metadata, Available);
      if not Available then
         raise Channel_Closed with "receive from drained buffer channel";
      end if;
   end Receive_Move;

   procedure Try_Send_Move
     (Item   : in out Channel;
      Value  : in out Unique_Buffer;
      Result : out Try_Send_Result;
      Metadata : Transfer_Metadata := No_Metadata) is
   begin
      Validate_Pools (Item, Value);
      if not Has_Buffer (Value) then
         raise Program_Error with "send of a vacant buffer";
      end if;
      Item.State.Try_Send (Value, Metadata, Result);
   end Try_Send_Move;

   procedure Try_Receive_Move
     (Item   : in out Channel;
      Target : in out Unique_Buffer;
      Result : out Try_Receive_Result)
   is
      Metadata : Transfer_Metadata;
   begin
      Try_Receive_Move (Item, Target, Result, Metadata);
   end Try_Receive_Move;

   procedure Try_Receive_Move
     (Item     : in out Channel;
      Target   : in out Unique_Buffer;
      Result   : out Try_Receive_Result;
      Metadata : out Transfer_Metadata) is
   begin
      Metadata := No_Metadata;
      Validate_Pools (Item, Target);
      if Has_Buffer (Target) then
         raise Program_Error with "receive into an occupied buffer";
      end if;
      Item.State.Try_Receive (Target, Metadata, Result);
   end Try_Receive_Move;

   procedure Timed_Send_Move
     (Item    : in out Channel;
      Value   : in out Unique_Buffer;
      Timeout : Duration;
      Metadata : Transfer_Metadata := No_Metadata)
   is
      Accepted : Boolean;
      Result   : Try_Send_Result;
   begin
      if Timeout < 0.0 then
         Send_Move (Item, Value, Metadata);
         return;
      elsif Timeout = 0.0 then
         Try_Send_Move (Item, Value, Result, Metadata);
         case Result is
            when Item_Sent => return;
            when Send_Closed =>
               raise Channel_Closed with "send on closed buffer channel";
            when Channel_Full =>
               raise Timeout_Error with "buffer channel send timed out";
         end case;
      end if;

      Validate_Pools (Item, Value);
      if not Has_Buffer (Value) then
         raise Program_Error with "send of a vacant buffer";
      end if;
      select
         Item.State.Send (Value, Metadata, Accepted);
         if not Accepted then
            raise Channel_Closed with "send on closed buffer channel";
         end if;
      or
         delay Timeout;
         raise Timeout_Error with "buffer channel send timed out";
      end select;
   end Timed_Send_Move;

   procedure Timed_Receive_Move
     (Item    : in out Channel;
      Target  : in out Unique_Buffer;
      Timeout : Duration)
   is
      Metadata : Transfer_Metadata;
   begin
      Timed_Receive_Move (Item, Target, Timeout, Metadata);
   end Timed_Receive_Move;

   procedure Timed_Receive_Move
     (Item    : in out Channel;
      Target  : in out Unique_Buffer;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      Metadata : Transfer_Metadata;
   begin
      Timed_Receive_Move (Item, Target, Timeout, Metadata, Token);
   end Timed_Receive_Move;

   procedure Timed_Receive_Move
     (Item     : in out Channel;
      Target   : in out Unique_Buffer;
      Timeout  : Duration;
      Metadata : out Transfer_Metadata)
   is
      Available : Boolean;
      Result    : Try_Receive_Result;
   begin
      Metadata := No_Metadata;
      if Timeout < 0.0 then
         Receive_Move (Item, Target, Metadata);
         return;
      elsif Timeout = 0.0 then
         Try_Receive_Move (Item, Target, Result, Metadata);
         case Result is
            when Item_Received => return;
            when Receive_Closed =>
               raise Channel_Closed with
                 "receive from drained buffer channel";
            when Channel_Empty =>
               raise Timeout_Error with "buffer channel receive timed out";
         end case;
      end if;

      Validate_Pools (Item, Target);
      if Has_Buffer (Target) then
         raise Program_Error with "receive into an occupied buffer";
      end if;
      select
         Item.State.Receive (Target, Metadata, Available);
         if not Available then
            raise Channel_Closed with
              "receive from drained buffer channel";
         end if;
      or
         delay Timeout;
         raise Timeout_Error with "buffer channel receive timed out";
      end select;
   end Timed_Receive_Move;

   procedure Timed_Receive_Move
     (Item     : in out Channel;
      Target   : in out Unique_Buffer;
      Timeout  : Duration;
      Metadata : out Transfer_Metadata;
      Token    : access Flyology.Cancellation.Token) is
   begin
      Metadata := No_Metadata;
      if Token = null then
         Timed_Receive_Move (Item, Target, Timeout, Metadata);
      elsif Token.Requested then
         raise Operation_Cancelled;
      else
         select
            Token.Await_Request;
            raise Operation_Cancelled;
         then abort
            Timed_Receive_Move (Item, Target, Timeout, Metadata);
         end select;
      end if;
   end Timed_Receive_Move;

   procedure Try_Scoped
     (Operation : in out Channel_Operation;
      Result    : out Try_Receive_Result)
   is
   begin
      case Operation.Kind is
         when Scoped_Send =>
            declare
               Send_Result : Try_Send_Result;
            begin
               Operation.Item.State.Try_Send
                 (Operation.Owned, Operation.Metadata, Send_Result);
               case Send_Result is
                  when Item_Sent =>
                     Result := Item_Received;
                  when Channel_Full =>
                     Result := Channel_Empty;
                  when Send_Closed =>
                     Operation.Failure := Channel_Closed_Failure;
                     Result := Receive_Closed;
               end case;
            end;
         when Scoped_Receive =>
            Operation.Item.State.Try_Receive
              (Operation.Owned, Operation.Metadata, Result);
            if Result = Receive_Closed then
               Operation.Failure := Channel_Closed_Failure;
            end if;
      end case;
   end Try_Scoped;

   procedure Prepare_Scoped
     (Operation : in out Channel_Operation;
      Item      : not null Channel_Access;
      Kind      : Scoped_Kind;
      Timeout   : Duration;
      Descriptor : out Interfaces.C.int)
   is
      Signal_Descriptor : Interfaces.C.int;
   begin
      Flyology.Operations.Drivers.Start (Operation);
      Operation.Item := Item;
      Operation.Kind := Kind;
      Operation.Metadata := No_Metadata;
      Operation.Next := System.Null_Address;
      Operation.Subscribed := False;
      Operation.Failure := No_Failure;
      Flyology.Operations.Drivers.Completion_Source
        (Operation, Descriptor, Signal_Descriptor);
      if Timeout > 0.0 then
         Flyology.Operations.Drivers.Arm_Deadline (Operation, Timeout);
      end if;
   end Prepare_Scoped;

   procedure Finish_Start
     (Operation  : in out Channel_Operation;
      Descriptor : Interfaces.C.int;
      Timeout    : Duration)
   is
      Result : Try_Receive_Result;
   begin
      Try_Scoped (Operation, Result);
      if Result = Channel_Empty and then Timeout /= 0.0 then
         Subscriptions.Link (Operation'Address);
         Try_Scoped (Operation, Result);
         if Result /= Channel_Empty then
            Subscriptions.Unlink (Operation'Address);
         end if;
      end if;
      case Result is
         when Item_Received =>
            Flyology.Operations.Drivers.Complete
              (Operation, Flyology.Operations.Succeeded);
         when Receive_Closed =>
            Flyology.Operations.Drivers.Complete
              (Operation, Flyology.Operations.Failed);
         when Channel_Empty =>
            if Timeout = 0.0 then
               Operation.Failure := Timeout_Failure;
               Flyology.Operations.Drivers.Complete
                 (Operation, Flyology.Operations.Failed);
            else
               Flyology.Operations.Drivers.Arm_Readiness
                 (Operation, Descriptor, False);
            end if;
      end case;
   end Finish_Start;

   procedure Send_Move
     (Item      : not null Channel_Access;
      Value     : in out Unique_Buffer;
      Metadata  : Transfer_Metadata := No_Metadata;
      Timeout   : Duration := -1.0;
      Operation : in out Send_Operation)
   is
      Descriptor : Interfaces.C.int;
   begin
      Validate_Pools (Item.all, Value);
      if not Has_Buffer (Value) then
         raise Program_Error with "send of a vacant buffer";
      end if;
      Prepare_Scoped
        (Channel_Operation (Operation), Item, Scoped_Send,
         Timeout, Descriptor);
      Operation.Metadata := Metadata;
      Flyology.Buffers.Drivers.Move_From (Value, Operation.Owned);
      Finish_Start
        (Channel_Operation (Operation), Descriptor, Timeout);
   exception
      when others =>
         if Operation.Subscribed then
            Subscriptions.Unlink (Operation'Address);
         end if;
         if Flyology.Buffers.Drivers.Has_Buffer (Operation.Owned)
           and then not Has_Buffer (Value)
         then
            Flyology.Buffers.Drivers.Move_To (Operation.Owned, Value);
         end if;
         Operation.Item := null;
         if Flyology.Operations.Is_Active (Operation) then
            Flyology.Operations.Drivers.Rollback_Start (Operation);
         end if;
         raise;
   end Send_Move;

   function Send_Move
     (Set      : not null access Flyology.Operations.Completion_Set'Class;
      Item     : not null Channel_Access;
      Value    : in out Unique_Buffer;
      Metadata : Transfer_Metadata := No_Metadata;
      Timeout  : Duration := -1.0) return Send_Operation
   is
   begin
      return Result : Send_Operation (Set) do
         Send_Move (Item, Value, Metadata, Timeout, Result);
      end return;
   end Send_Move;

   procedure Receive_Move
     (Item      : not null Channel_Access;
      Timeout   : Duration := -1.0;
      Operation : in out Receive_Operation)
   is
      Descriptor : Interfaces.C.int;
   begin
      Prepare_Scoped
        (Channel_Operation (Operation), Item, Scoped_Receive,
         Timeout, Descriptor);
      Finish_Start
        (Channel_Operation (Operation), Descriptor, Timeout);
   exception
      when others =>
         if Operation.Subscribed then
            Subscriptions.Unlink (Operation'Address);
         end if;
         Operation.Item := null;
         if Flyology.Operations.Is_Active (Operation) then
            Flyology.Operations.Drivers.Rollback_Start (Operation);
         end if;
         raise;
   end Receive_Move;

   function Receive_Move
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null Channel_Access;
      Timeout : Duration := -1.0) return Receive_Operation
   is
   begin
      return Result : Receive_Operation (Set) do
         Receive_Move (Item, Timeout, Result);
      end return;
   end Receive_Move;

   overriding procedure Drive
     (Item  : in out Channel_Operation;
      Event : Flyology.Operations.Driver_Event)
   is
      Result : Try_Receive_Result;
      Descriptor, Signal_Descriptor : Interfaces.C.int;
   begin
      case Event is
         when Flyology.Operations.Start_Operation =>
            raise Program_Error with
              "buffer channel operation was already started";
         when Flyology.Operations.Source_Ready =>
            Try_Scoped (Item, Result);
            if Result /= Channel_Empty then
               Subscriptions.Unlink (Item'Address);
            end if;
         when Flyology.Operations.Deadline_Reached =>
            Subscriptions.Unlink (Item'Address);
            Try_Scoped (Item, Result);
            if Result = Channel_Empty then
               Item.Failure := Timeout_Failure;
            end if;
         when Flyology.Operations.Dependency_Changed
            | Flyology.Operations.Continue_Operation =>
            raise Program_Error with
              "buffer channel operation received a dependency event";
      end case;

      case Result is
         when Item_Received =>
            Flyology.Operations.Drivers.Complete
              (Item, Flyology.Operations.Succeeded);
         when Receive_Closed =>
            Flyology.Operations.Drivers.Complete
              (Item, Flyology.Operations.Failed);
         when Channel_Empty =>
            if Event = Flyology.Operations.Deadline_Reached then
               Flyology.Operations.Drivers.Complete
                 (Item, Flyology.Operations.Failed);
            else
               Flyology.Operations.Drivers.Completion_Source
                 (Item, Descriptor, Signal_Descriptor);
               Flyology.Operations.Drivers.Arm_Readiness
                 (Item, Descriptor, False);
            end if;
      end case;
   exception
      when others =>
         if Item.Subscribed then
            Subscriptions.Unlink (Item'Address);
         end if;
         Item.Failure := Driver_Failure;
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Failed);
   end Drive;

   overriding procedure Request_Cancellation
     (Item : in out Channel_Operation) is
   begin
      if Item.Subscribed then
         Subscriptions.Unlink (Item'Address);
      end if;
      Flyology.Operations.Drivers.Complete
        (Item, Flyology.Operations.Cancelled);
   end Request_Cancellation;

   procedure Reset (Operation : in out Channel_Operation) is
   begin
      Operation.Item := null;
      Operation.Metadata := No_Metadata;
      Operation.Next := System.Null_Address;
      Operation.Subscribed := False;
      Operation.Failure := No_Failure;
   end Reset;

   procedure Raise_Failure (Failure : Scoped_Failure) is
   begin
      case Failure is
         when Channel_Closed_Failure =>
            raise Channel_Closed with
              "scoped buffer channel operation observed close";
         when Timeout_Failure =>
            raise Timeout_Error with
              "scoped buffer channel operation timed out";
         when Driver_Failure =>
            raise Program_Error with
              "scoped buffer channel operation driver failed";
         when No_Failure =>
            raise Program_Error with
              "scoped buffer channel operation failed";
      end case;
   end Raise_Failure;

   procedure Finish
     (Operation : in out Send_Operation;
      Value     : in out Unique_Buffer)
   is
      Outcome : constant Flyology.Operations.Terminal_Outcome :=
        Flyology.Operations.Outcome (Operation);
      Failure : constant Scoped_Failure := Operation.Failure;
   begin
      if Has_Buffer (Value) then
         raise Program_Error with
           "buffer channel send finish destination is occupied";
      elsif Flyology.Buffers.Drivers.Has_Buffer (Operation.Owned)
        and then not Flyology.Buffers.Drivers.Same_Pool
          (Operation.Owned, Value)
      then
         raise Program_Error with
           "buffer channel send finish pool mismatch";
      end if;
      Flyology.Operations.Consume (Operation);
      if Flyology.Buffers.Drivers.Has_Buffer (Operation.Owned) then
         Flyology.Buffers.Drivers.Move_To (Operation.Owned, Value);
      end if;
      Reset (Channel_Operation (Operation));
      case Outcome is
         when Flyology.Operations.Succeeded =>
            null;
         when Flyology.Operations.Cancelled =>
            raise Operation_Cancelled;
         when Flyology.Operations.Failed =>
            Raise_Failure (Failure);
      end case;
   end Finish;

   procedure Finish
     (Operation : in out Receive_Operation;
      Target    : in out Unique_Buffer)
   is
      Metadata : Transfer_Metadata;
   begin
      Finish (Operation, Target, Metadata);
   end Finish;

   procedure Finish
     (Operation : in out Receive_Operation;
      Target    : in out Unique_Buffer;
      Metadata  : out Transfer_Metadata)
   is
      Outcome : constant Flyology.Operations.Terminal_Outcome :=
        Flyology.Operations.Outcome (Operation);
      Failure : constant Scoped_Failure := Operation.Failure;
   begin
      Metadata := No_Metadata;
      if Has_Buffer (Target) then
         raise Program_Error with
           "buffer channel receive finish destination is occupied";
      elsif Flyology.Buffers.Drivers.Has_Buffer (Operation.Owned)
        and then not Flyology.Buffers.Drivers.Same_Pool
          (Operation.Owned, Target)
      then
         raise Program_Error with
           "buffer channel receive finish pool mismatch";
      end if;
      Flyology.Operations.Consume (Operation);
      case Outcome is
         when Flyology.Operations.Succeeded =>
            Metadata := Operation.Metadata;
            Flyology.Buffers.Drivers.Move_To (Operation.Owned, Target);
            Reset (Channel_Operation (Operation));
         when Flyology.Operations.Cancelled =>
            Reset (Channel_Operation (Operation));
            raise Operation_Cancelled;
         when Flyology.Operations.Failed =>
            Reset (Channel_Operation (Operation));
            Raise_Failure (Failure);
      end case;
   end Finish;

   procedure Close (Item : in out Channel) is
   begin
      Item.State.Close;
   end Close;

   procedure Await_Drained (Item : in out Channel) is
   begin
      Item.State.Await_Drained;
   end Await_Drained;

   function Current (Item : Channel) return Snapshot is
     (Item.State.Current);

   overriding procedure Finalize (Item : in out Channel) is
      Undelivered : Flyology.Buffers.Drivers.Detached_Buffer;
      Result : Try_Receive_Result;
   begin
      Item.State.Close;
      loop
         Item.State.Take_Undelivered (Undelivered, Result);
         exit when Result /= Item_Received;
         Flyology.Buffers.Drivers.Release (Undelivered);
      end loop;
   end Finalize;

end Flyology.Buffers.Channels;
