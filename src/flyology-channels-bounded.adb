with Ada.Unchecked_Conversion;
with Flyology.Channel_Policy;
with Flyology.Operations.Drivers;
with Interfaces.C;
with System.Storage_Elements;

package body Flyology.Channels.Bounded is

   package Policy renames Flyology.Channel_Policy;

   use type System.Address;
   use type System.Storage_Elements.Integer_Address;
   use type Flyology.Operations.Driver_Event;
   use type Interfaces.C.int;
   use type Interfaces.C.unsigned;

   type Channel_Operation_Access is access all Channel_Operation;
   function To_Operation is new Ada.Unchecked_Conversion (System.Address, Channel_Operation_Access);

   Bucket_Count         : constant := 32;
   subtype Bucket_Index is Positive range 1 .. Bucket_Count;
   type Bucket_Array is array (Bucket_Index) of System.Address;
   type Subscription_Count_Array is array (Bucket_Index) of Interfaces.C.unsigned with Atomic_Components;
   Active_Subscriptions : Subscription_Count_Array := (others => 0);

   function Bucket (Address : System.Address) return Bucket_Index
   is (Bucket_Index
         (System.Storage_Elements.To_Integer (Address)
          mod System.Storage_Elements.Integer_Address (Bucket_Count)
          + 1));

   protected Subscriptions is
      procedure Link (Operation : System.Address);
      procedure Unlink (Operation : System.Address);
      procedure Signal (Channel_Address : System.Address);
   private
      Heads : Bucket_Array := (others => System.Null_Address);
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
         Target.Next := Heads (Index);
         Target.Subscribed := True;
         Heads (Index) := Operation;
         Active_Subscriptions (Index) := Active_Subscriptions (Index) + 1;
      end Link;

      procedure Unlink (Operation : System.Address) is
         Target           : constant Channel_Operation_Access := To_Operation (Operation);
         Index            : Bucket_Index;
         Cursor, Previous : System.Address;
      begin
         if Target = null or else not Target.Subscribed then
            return;
         end if;
         Index := Bucket (Target.Item.all'Address);
         Cursor := Heads (Index);
         Previous := System.Null_Address;
         while Cursor /= System.Null_Address and then Cursor /= Operation loop
            Previous := Cursor;
            Cursor := To_Operation (Cursor).Next;
         end loop;
         if Cursor = System.Null_Address then
            raise Program_Error with "channel subscription link is stale";
         elsif Previous = System.Null_Address then
            Heads (Index) := Target.Next;
         else
            To_Operation (Previous).Next := Target.Next;
         end if;
         Target.Next := System.Null_Address;
         Target.Subscribed := False;
         Active_Subscriptions (Index) := Active_Subscriptions (Index) - 1;
      end Unlink;

      procedure Signal (Channel_Address : System.Address) is
         Cursor : System.Address := Heads (Bucket (Channel_Address));
      begin
         while Cursor /= System.Null_Address loop
            declare
               Operation : constant Channel_Operation_Access := To_Operation (Cursor);
            begin
               if Operation.Item /= null and then Operation.Item.all'Address = Channel_Address then
                  Flyology.Operations.Drivers.Signal_Completion (Operation.all);
               end if;
               Cursor := Operation.Next;
            end;
         end loop;
      end Signal;
   end Subscriptions;

   protected body Channel is
      procedure Signal_Scoped is
         --  Channel'Address names the protected data part on GNAT, whereas an
         --  access-to-Channel designates the complete protected object. Form
         --  the same complete-object identity used by operation initiation.
         Channel_Address : constant System.Address := Channel'Unchecked_Access.all'Address;
         Index           : constant Bucket_Index := Bucket (Channel_Address);
      begin
         if Active_Subscriptions (Index) /= 0 then
            Subscriptions.Signal (Channel_Address);
         end if;
      end Signal_Scoped;

      entry Send (Value : Element_Type) when Policy.Send_Entry_Open (Stopped, Count, Capacity) is
      begin
         case Policy.Classify_Send (Stopped, Count, Capacity) is
            when Policy.Accept_Send  =>
               Buffer (Tail) := Value;
               Tail := Policy.Advance (Tail, Capacity);
               Count := Policy.Count_After_Send (Count, Capacity);
               Signal_Scoped;

            when Policy.Reject_Send  =>
               raise Channel_Closed with "send on closed channel";

            when Policy.Wait_To_Send =>
               raise Program_Error with "channel send entry opened while full";
         end case;
      end Send;

      entry Receive (Value : out Element_Type) when Policy.Receive_Entry_Open (Stopped, Count) is
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
               Signal_Scoped;

            when Policy.Reject_Receive  =>
               raise Channel_Closed with "receive from drained channel";

            when Policy.Wait_To_Receive =>
               raise Program_Error with "channel receive entry opened while empty";
         end case;
      end Receive;

      procedure Try_Send (Value : Element_Type; Result : out Try_Send_Result) is
         Ignored : aliased Boolean := False;
      begin
         Try_Send (Value, Ignored'Access, Result);
      end Try_Send;

      procedure Try_Send
        (Value : Element_Type; Accepted : not null access Boolean; Result : out Try_Send_Result) is
      begin
         Accepted.all := False;
         case Policy.Classify_Send (Stopped, Count, Capacity) is
            when Policy.Accept_Send  =>
               Buffer (Tail) := Value;
               Tail := Policy.Advance (Tail, Capacity);
               Count := Policy.Count_After_Send (Count, Capacity);
               Result := Item_Sent;
               Accepted.all := True;
               Signal_Scoped;

            when Policy.Wait_To_Send =>
               Result := Channel_Full;

            when Policy.Reject_Send  =>
               Result := Send_Closed;
         end case;
      end Try_Send;

      procedure Try_Receive (Value : in out Element_Type; Result : out Try_Receive_Result) is
         Position : Positive;
      begin
         case Policy.Classify_Receive (Stopped, Count) is
            when Policy.Accept_Receive  =>
               Value := Buffer (Head);
               Policy.Apply_Dequeue (Head, Count, Capacity, Position);
               Buffer (Position) := Empty_Value;
               Result := Item_Received;
               Signal_Scoped;

            when Policy.Wait_To_Receive =>
               Result := Channel_Empty;

            when Policy.Reject_Receive  =>
               Result := Receive_Closed;
         end case;
      end Try_Receive;

      procedure Close is
      begin
         Stopped := True;
         Signal_Scoped;
      end Close;

      entry Await_Drained when Policy.Is_Drained (Stopped, Count) is
      begin
         null;
      end Await_Drained;

      function Current return Snapshot
      is (Closed            => Stopped,
          Pending           => Count,
          Waiting_Senders   => Channel.Send'Count,
          Waiting_Receivers => Channel.Receive'Count);
   end Channel;

   procedure Timed_Send (Item : in out Channel; Value : Element_Type; Timeout : Duration) is
   begin
      if Timeout < 0.0 then
         Item.Send (Value);
      else
         select
            Item.Send (Value);
         or
            delay Timeout;
            raise Timeout_Error with "channel send timed out";
         end select;
      end if;
   end Timed_Send;

   procedure Timed_Receive (Item : in out Channel; Value : out Element_Type; Timeout : Duration) is
   begin
      if Timeout < 0.0 then
         Item.Receive (Value);
      else
         select
            Item.Receive (Value);
         or
            delay Timeout;
            raise Timeout_Error with "channel receive timed out";
         end select;
      end if;
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
      Item      : not null access Channel;
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
      Operation.Subscribed := False;
      Operation.Failure := No_Failure;

      Try_Scoped (Operation, Result);
      if Result = Channel_Empty and then Timeout /= 0.0 then
         Flyology.Operations.Drivers.Completion_Source (Operation, Read_Descriptor, Signal_Descriptor);
         --  Subscribe before rechecking. A state transition before Link is
         --  found by the recheck; one after Link signals this operation.
         Subscriptions.Link (Operation'Address);
         Try_Scoped (Operation, Result);
         if Result /= Channel_Empty then
            Subscriptions.Unlink (Operation'Address);
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
            Subscriptions.Unlink (Operation'Address);
         end if;
         Operation.Value := Empty_Value;
         Operation.Item := null;
         if Flyology.Operations.Is_Active (Operation) then
            Flyology.Operations.Drivers.Rollback_Start (Operation);
         end if;
         raise;
   end Start_Scoped;

   procedure Send
     (Item      : not null access Channel;
      Value     : Element_Type;
      Timeout   : Duration := -1.0;
      Operation : in out Send_Operation) is
   begin
      Start_Scoped (Channel_Operation (Operation), Item, Scoped_Send, Value, Timeout);
   end Send;

   function Send
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null access Channel;
      Value   : Element_Type;
      Timeout : Duration := -1.0) return Send_Operation is
   begin
      return Result : Send_Operation (Set) do
         Send (Item, Value, Timeout, Result);
      end return;
   end Send;

   procedure Receive
     (Item : not null access Channel; Timeout : Duration := -1.0; Operation : in out Receive_Operation) is
   begin
      Start_Scoped (Channel_Operation (Operation), Item, Scoped_Receive, Empty_Value, Timeout);
   end Receive;

   function Receive
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null access Channel;
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
            Try_Scoped (Item, Result);
            if Result /= Channel_Empty then
               Subscriptions.Unlink (Item'Address);
            end if;

         when Flyology.Operations.Deadline_Reached                                            =>
            Subscriptions.Unlink (Item'Address);
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
            Subscriptions.Unlink (Item'Address);
         end if;
         Item.Value := Empty_Value;
         Item.Failure := Driver_Failure;
         Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
   end Drive;

   overriding
   procedure Request_Cancellation (Item : in out Channel_Operation) is
   begin
      if Item.Subscribed then
         Subscriptions.Unlink (Item'Address);
      end if;
      Item.Value := Empty_Value;
      Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Cancelled);
   end Request_Cancellation;

   procedure Reset (Operation : in out Channel_Operation) is
   begin
      Operation.Item := null;
      Operation.Value := Empty_Value;
      Operation.Next := System.Null_Address;
      Operation.Subscribed := False;
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
