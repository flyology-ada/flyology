with Ada.Unchecked_Deallocation;
with Flyology.Counter_Policy;
with Flyology.Worker_Pool_Test_Hooks;
with System.Address_To_Access_Conversions;

package body Flyology.Native_Executors is
   package Test_Hooks renames Flyology.Worker_Pool_Test_Hooks;

   use type Ada.Real_Time.Time;
   use type Ada.Exceptions.Exception_Id;
   use type Interfaces.Unsigned_64;
   use type System.Address;
   --  Slot_Status renames the proved policy state type, whose operators are
   --  not directly visible from this body without this clause.
   use type Slot_Status;

   procedure Free_Token is new Ada.Unchecked_Deallocation
     (Flyology.Cancellation.Token, Token_Access);

   overriding procedure Finalize (Owner : in out Token_Owner) is
   begin
      if Owner.Value /= null then
         Free_Token (Owner.Value);
         Test_Hooks.Token_Cleanup_Release;
      end if;
   end Finalize;

   procedure Request_Owned_Token (Token : Token_Access) is
   begin
      Token.Request;
   end Request_Owned_Token;

   procedure Consume_Completion_Wake
     (Wake : in out Flyology.Wake_Sources.Source) is
   begin
      if Test_Hooks.Consume_Failure then
         raise Program_Error with
           "injected native executor wake consumption failure";
      end if;
      Flyology.Wake_Sources.Consume (Wake);
   end Consume_Completion_Wake;

   protected body Shared_State is
      procedure Submit
        (Input      : Input_Type;
         Token      : Token_Access;
         Deadline   : Ada.Real_Time.Time;
         Slot       : out Positive;
         Generation : out Generation_Number;
         Replaced_Token : out Token_Access;
         Accepted   : out Boolean)
      is
         Found : Natural := 0;
      begin
         Replaced_Token := null;
         if Stopping then
            Counters.Rejected_Submissions :=
              Counters.Rejected_Submissions + 1;
            Slot := 1;
            Generation := 0;
            Accepted := False;
            return;
         end if;
         for Index in Status'Range loop
            if Status (Index) = Free then
               Found := Index;
               exit;
            end if;
         end loop;
         if Found = 0 then
            Counters.Rejected_Submissions :=
              Counters.Rejected_Submissions + 1;
            Slot := 1;
            Generation := 0;
            Accepted := False;
            return;
         end if;
         Slot := Found;
         Generations (Slot) :=
           Flyology.Counter_Policy.Nonzero_Successor (Generations (Slot));
         Generation := Generations (Slot);
         Inputs (Slot) := Input;
         Messages (Slot) := Ada.Strings.Unbounded.Null_Unbounded_String;
         Replaced_Token := Tokens (Slot);
         Tokens (Slot) := Token;
         Deadlines (Slot) := Deadline;
         Wake_Armed (Slot) := False;
         Wake_Pending (Slot) := False;
         Error_Ids (Slot) := Ada.Exceptions.Null_Id;
         Detached (Slot) := False;
         Status (Slot) := Queued;
         Queue (Tail) := Slot;
         Tail := (if Tail = Capacity then 1 else Tail + 1);
         Queue_Count := Queue_Count + 1;
         Counters.Accepted_Submissions :=
           Counters.Accepted_Submissions + 1;
         Counters.Outstanding_Operations :=
           Counters.Outstanding_Operations + 1;
         Counters.Queued_Operations := Counters.Queued_Operations + 1;
         Counters.Peak_Outstanding := Natural'Max
           (Counters.Peak_Outstanding, Counters.Outstanding_Operations);
         Accepted := True;
      end Submit;

      entry Next
        (Slot : out Positive; Stop : out Boolean)
        when Queue_Count > 0 or else Stopping
      is
      begin
         if Stopping then
            Slot := 1;
            Stop := True;
            return;
         end if;
         Slot := Queue (Head);
         Head := (if Head = Capacity then 1 else Head + 1);
         Queue_Count := Queue_Count - 1;
         Status (Slot) := Running;
         Counters.Queued_Operations := Counters.Queued_Operations - 1;
         Counters.Running_Operations := Counters.Running_Operations + 1;
         Stop := False;
      end Next;

      procedure Operation_Data
        (Slot     : Positive;
         Input    : out Input_Type;
         Token    : out Token_Access;
         Deadline : out Ada.Real_Time.Time) is
      begin
         if Status (Slot) /= Running then
            raise Program_Error with "native executor slot is not running";
         end if;
         Token := Tokens (Slot);
         Deadline := Deadlines (Slot);
         Input := Inputs (Slot);
      end Operation_Data;

      procedure Complete (Slot : Positive; Result : Result_Type) is
         Relinquished : constant Boolean := Detached (Slot);
         Deliver      : constant Boolean := not Relinquished;
      begin
         if Deliver then
            --  Result_Type assignment is application code and may propagate,
            --  for instance when copying an allocating component fails. Do it
            --  before any counter or status transition so a failure leaves the
            --  slot Running and lets the worker's Fail path record exactly one
            --  terminal outcome.
            Results (Slot) := Result;
            if Test_Hooks.Completion_Wake then
               Flyology.Wake_Sources.Ensure (Wakes (Slot));
               Wake_Armed (Slot) := True;
            end if;
         end if;
         Counters.Running_Operations :=
           Policy.Running_After_Report (Counters.Running_Operations);
         Counters.Successful_Executions :=
           Counters.Successful_Executions + 1;
         Counters.Outstanding_Operations := Policy.Outstanding_After_Report
           (Counters.Outstanding_Operations, Relinquished);
         Status (Slot) := Policy.State_After_Report (Relinquished);
         if Deliver then
            if Wake_Armed (Slot) then
               Flyology.Wake_Sources.Signal (Wakes (Slot));
               Wake_Pending (Slot) := True;
            end if;
         else
            Detached (Slot) := False;
         end if;
      end Complete;

      procedure Fail
        (Slot : Positive; Error : Ada.Exceptions.Exception_Occurrence)
      is
         Relinquished : constant Boolean := Detached (Slot);
      begin
         if not Policy.Terminal_Report_Allowed (Status (Slot)) then
            --  Complete already applied this operation's terminal transition
            --  before propagating a later failure, or Operation_Data rejected
            --  a slot this worker never owned. Reporting again would decrement
            --  Running_Operations a second time and strand an unrelated
            --  caller when a subsequent completion underflows.
            return;
         end if;
         Counters.Running_Operations :=
           Policy.Running_After_Report (Counters.Running_Operations);
         Counters.Failed_Executions := Counters.Failed_Executions + 1;
         Counters.Outstanding_Operations := Policy.Outstanding_After_Report
           (Counters.Outstanding_Operations, Relinquished);
         if not Relinquished then
            --  Record the failure identity before the slot becomes terminal.
            Error_Ids (Slot) := Ada.Exceptions.Exception_Identity (Error);
         end if;
         Status (Slot) := Policy.State_After_Report (Relinquished);
         if Relinquished then
            Detached (Slot) := False;
         else
            --  The slot is already terminal, so copying diagnostic text is
            --  allowed to fail without stranding a waiter.
            begin
               Messages (Slot) := Ada.Strings.Unbounded.To_Unbounded_String
                 (Ada.Exceptions.Exception_Message (Error));
            exception
               when others =>
                  Messages (Slot) :=
                    Ada.Strings.Unbounded.Null_Unbounded_String;
            end;
            if Wake_Armed (Slot) then
               Flyology.Wake_Sources.Signal (Wakes (Slot));
               Wake_Pending (Slot) := True;
            end if;
         end if;
      end Fail;

      procedure Try_Await
        (Slot       : Positive;
         Generation : Generation_Number;
         Result     : out Result_Type;
         Error_Id   : out Ada.Exceptions.Exception_Id;
         Message    : out Ada.Strings.Unbounded.Unbounded_String;
         Ready      : out Boolean)
      is
      begin
         if Generations (Slot) /= Generation or else Generation = 0
           or else Status (Slot) = Free
         then
            raise Invalid_Handle;
         elsif Status (Slot) /= Completed then
            Ready := False;
            return;
         end if;
         Ready := True;
         if Wake_Pending (Slot) then
            Consume_Completion_Wake (Wakes (Slot));
            Wake_Pending (Slot) := False;
         end if;
         Wake_Armed (Slot) := False;
         Result := Results (Slot);
         Error_Id := Error_Ids (Slot);
         Message := Messages (Slot);
         Messages (Slot) := Ada.Strings.Unbounded.Null_Unbounded_String;
         Status (Slot) := Free;
         Counters.Outstanding_Operations :=
           Counters.Outstanding_Operations - 1;
      end Try_Await;

      procedure Wait_Source
        (Slot       : Positive;
         Generation : Generation_Number;
         FD         : out Flyology.IO.Descriptor;
         Ready      : out Boolean)
      is
      begin
         if Generations (Slot) /= Generation or else Generation = 0
           or else Status (Slot) = Free
         then
            raise Invalid_Handle;
         end if;
         Ready := Status (Slot) = Completed;
         if Ready then
            FD := Flyology.IO.Invalid_Descriptor;
         else
            Flyology.Wake_Sources.Ensure (Wakes (Slot));
            Wake_Armed (Slot) := True;
            FD := Flyology.Wake_Sources.Descriptor (Wakes (Slot));
         end if;
      end Wait_Source;

      procedure Abandon
        (Slot       : Positive;
         Generation : Generation_Number)
      is
         Consume_Wake : Boolean := False;
      begin
         if Generations (Slot) /= Generation or else Generation = 0
           or else Status (Slot) = Free
         then
            raise Invalid_Handle;
         end if;
         Counters.Abandoned_Operations :=
           Counters.Abandoned_Operations + 1;
         if Status (Slot) = Completed then
            Consume_Wake := Wake_Pending (Slot);
            Wake_Pending (Slot) := False;
            Wake_Armed (Slot) := False;
            Status (Slot) := Free;
            Detached (Slot) := False;
            Counters.Outstanding_Operations :=
              Counters.Outstanding_Operations - 1;
         else
            Detached (Slot) := True;
         end if;
         --  Release the slot before fallible wake cleanup. If consumption
         --  fails, discard the descriptor generation so a later occupant
         --  cannot inherit a stale readable signal.
         if Consume_Wake then
            begin
               Consume_Completion_Wake (Wakes (Slot));
            exception
               when others =>
                  Flyology.Wake_Sources.Release (Wakes (Slot));
                  raise;
            end;
         end if;
         --  Publish the irreversible slot transition before signalling. A
         --  wake failure may escape, but cannot leave an accepted operation
         --  attached to a handle that finalization is about to discard.
         if Tokens (Slot) /= null then
            Request_Owned_Token (Tokens (Slot));
         end if;
      end Abandon;

      procedure Begin_Shutdown (Owner : out Boolean) is
      begin
         if Stopping then
            Owner := False;
            return;
         end if;
         Owner := True;
         Stopping := True;
         for Index in Status'Range loop
            if Status (Index) = Queued then
               Counters.Queued_Operations :=
                 Counters.Queued_Operations - 1;
               if Detached (Index) then
                  Status (Index) := Free;
                  Detached (Index) := False;
                  Counters.Outstanding_Operations :=
                    Counters.Outstanding_Operations - 1;
               else
                  Status (Index) := Completed;
                  Error_Ids (Index) :=
                    Flyology.Cancellation.Operation_Cancelled'Identity;
               end if;
            end if;
         end loop;
         Queue_Count := 0;
      end Begin_Shutdown;

      procedure Signal_Shutdown_Completion (Slot : Positive) is
      begin
         if Status (Slot) = Completed
           and then Wake_Armed (Slot)
           and then not Wake_Pending (Slot)
         then
            Flyology.Wake_Sources.Signal (Wakes (Slot));
            Wake_Pending (Slot) := True;
         end if;
      end Signal_Shutdown_Completion;

      procedure Request_Cancellation (Slot : Positive) is
      begin
         if Tokens (Slot) /= null then
            Request_Owned_Token (Tokens (Slot));
         end if;
      end Request_Cancellation;

      procedure Set_Expected_Workers (Count : Natural) is
      begin
         Expected_Workers := Count;
         Expected_Workers_Set := True;
      end Set_Expected_Workers;

      procedure Worker_Stopped is
      begin
         Stopped_Workers := Stopped_Workers + 1;
      end Worker_Stopped;

      entry Await_Stopped
        when Expected_Workers_Set
          and then Stopped_Workers = Expected_Workers is
      begin
         null;
      end Await_Stopped;

      procedure Take_Token
        (Slot : Positive; Owner : not null access Token_Owner) is
      begin
         Owner.Value := Tokens (Slot);
         Tokens (Slot) := null;
         if Owner.Value /= null then
            Test_Hooks.Token_Cleanup_Acquire;
            --  This barrier is inside the protected action: abort remains
            --  deferred after State relinquishes ownership until the caller's
            --  controlled holder is already authoritative.
            Test_Hooks.Token_Cleanup_Barrier;
         end if;
      end Take_Token;

      procedure Complete_Shutdown is
      begin
         Shutdown_Complete := True;
      end Complete_Shutdown;

      entry Await_Shutdown when Shutdown_Complete is
      begin
         null;
      end Await_Shutdown;

      function Shutdown_Started return Boolean is (Stopping);

      function Statistics return Executor_Statistics is (Counters);
   end Shared_State;

   task body Worker is
      Activation_Checked : constant Boolean := Test_Hooks.Check_Activation;
      pragma Unreferenced (Activation_Checked);

      package Conversions is new
        System.Address_To_Access_Conversions (Shared_State);
      State_Ptr : Conversions.Object_Pointer;
      Stopped   : Boolean := False;
   begin
      --  No worker touches the shared state before Start hands it the
      --  executor. If activation of a sibling fails, the allocator raises and
      --  the pool access value is lost, so the workers that did activate can
      --  never be reached by Shutdown. The terminate alternative lets the
      --  enclosing master collect them instead of waiting on them forever. It
      --  cannot be selected while the executor is usable, because Start runs
      --  inside that same still-incomplete master.
      select
         accept Start (State : System.Address) do
            State_Ptr := Conversions.To_Pointer (State);
         end Start;
      or
         accept Stop;
         Stopped := True;
      or
         terminate;
      end select;
      begin
         while not Stopped loop
            declare
               Slot     : Positive;
               Input    : Input_Type;
               Token    : Token_Access;
               Deadline : Ada.Real_Time.Time;
               Stop     : Boolean;
               Result   : Result_Type;
            begin
               State_Ptr.Next (Slot, Stop);
               exit when Stop;
               begin
                  State_Ptr.Operation_Data (Slot, Input, Token, Deadline);
                  if Token /= null and then Token.Requested then
                     raise Flyology.Cancellation.Operation_Cancelled;
                  elsif Deadline /= Ada.Real_Time.Time_Last
                    and then Ada.Real_Time.Clock >= Deadline
                  then
                     raise Flyology.IO.Timeout_Error with
                       "native executor operation deadline expired";
                  end if;
                  Execute (Input, Token, Deadline, Result);
                  State_Ptr.Complete (Slot, Result);
               exception
                  when Error : others =>
                     begin
                        State_Ptr.Fail (Slot, Error);
                     exception
                        when others => null;
                     end;
               end;
            end;
         end loop;
      exception
         when others =>
            null;
      end;
      if not Stopped then
         State_Ptr.Worker_Stopped;
      end if;
   end Worker;

   overriding procedure Initialize (Item : in out Executor) is
   begin
      null;
   end Initialize;

   procedure Start (Item : aliased in out Executor) is
   begin
      if Item.State.Shutdown_Started then
         raise Program_Error with "native executor has been shut down";
      elsif not Item.Started then
         Item.Pool := new Worker_Array (1 .. Item.Workers);
         Item.Started := True;
         for Worker of Item.Pool.all loop
            Worker.Start (Item.State'Address);
            Item.Activated_Workers := Item.Activated_Workers + 1;
         end loop;
      end if;
   end Start;

   procedure Shutdown (Item : in out Executor) is
      procedure Free is new Ada.Unchecked_Deallocation
        (Worker_Array, Worker_Array_Access);
      Owner          : Boolean := False;
      Failed         : Boolean := False;
      Workers_Joined : Boolean := False;
      Cleanup_Done   : Boolean := False;
      Primary_Error  : Ada.Exceptions.Exception_Occurrence;

      procedure Record_Failure
        (Error : Ada.Exceptions.Exception_Occurrence) is
      begin
         if not Failed then
            Ada.Exceptions.Save_Occurrence (Primary_Error, Error);
            Failed := True;
         end if;
      end Record_Failure;

      procedure Request_Cancellation (Index : Positive) is
      begin
         begin
            Item.State.Request_Cancellation (Index);
         exception
            when Error : others =>
               --  Token.Request publishes terminal cancellation before its
               --  fallible descriptor wake. Preserve that wake failure for
               --  the caller, but continue cleanup without retrying a
               --  documented persistent error forever.
               Record_Failure (Error);
         end;
      end Request_Cancellation;

      procedure Perform_Cleanup is
      begin
         if Cleanup_Done then
            return;
         end if;
         for Index in 1 .. Item.Capacity loop
            begin
               Item.State.Signal_Shutdown_Completion (Index);
            exception
               when Error : others =>
                  Record_Failure (Error);
            end;
         end loop;
         if Item.Started then
            for Index in 1 .. Item.Capacity loop
               Request_Cancellation (Index);
            end loop;
            if Item.Pool /= null then
               for Index in Item.Activated_Workers + 1 .. Item.Workers loop
                  begin
                     Item.Pool (Index).Stop;
                  exception
                     when Tasking_Error => null;
                  end;
               end loop;
            end if;
            begin
               Item.State.Set_Expected_Workers (Item.Activated_Workers);
               Item.State.Await_Stopped;
               Workers_Joined := True;
            exception
               when Error : others =>
                  Record_Failure (Error);
            end;
            if Workers_Joined then
               if Item.Pool /= null then
                  begin
                     Free (Item.Pool);
                  exception
                     when Error : others =>
                        Record_Failure (Error);
                  end;
               end if;
               for Index in 1 .. Item.Capacity loop
                  declare
                     Token : aliased Token_Owner;
                  begin
                     begin
                        Item.State.Take_Token (Index, Token'Access);
                     exception
                        when Error : others =>
                           Record_Failure (Error);
                     end;
                  end;
               end loop;
            end if;
            --  Keep Started immutable once activation succeeds. Stopping is
            --  the serialized admission gate, so concurrent Submit calls can
            --  safely observe terminal rejection without racing a lifecycle
            --  write.
         end if;
         Cleanup_Done := not Item.Started or else Workers_Joined;
      end Perform_Cleanup;

      type Completion_Guard is
        new Ada.Finalization.Limited_Controlled with null record;

      overriding procedure Finalize (Guard : in out Completion_Guard);

      overriding procedure Finalize (Guard : in out Completion_Guard) is
         pragma Unreferenced (Guard);
      begin
         if Owner then
            --  Finalization is abort-deferred. Publish the terminal state on
            --  normal return, exception propagation, or owner abort so later
            --  idempotent Shutdown callers cannot remain queued forever.
            if not Cleanup_Done then
               begin
                  Perform_Cleanup;
               exception
                  when others => null;
               end;
            end if;
            begin
               Item.State.Complete_Shutdown;
            exception
               when others => null;
            end;
         end if;
      end Finalize;

      Completion : Completion_Guard;
      pragma Unreferenced (Completion);
   begin
      Item.State.Begin_Shutdown (Owner);
      if not Owner then
         Item.State.Await_Shutdown;
         return;
      end if;
      Test_Hooks.Shutdown_Barrier;
      Perform_Cleanup;
      if Failed then
         Ada.Exceptions.Reraise_Occurrence (Primary_Error);
      end if;
   end Shutdown;

   overriding procedure Finalize (Item : in out Executor) is
   begin
      Shutdown (Item);
   end Finalize;

   procedure Submit
     (Item     : aliased in out Executor;
      Input    : Input_Type;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time;
      Handle   : in out Operation_Handle;
      Accepted : out Boolean)
   is
      Slot       : Positive;
      Generation : Generation_Number;
      Token_Value : Token_Access := null;
      Replaced_Token : Token_Access := null;
   begin
      if not Item.Started then
         raise Program_Error with "native executor has not been started";
      elsif Handle.Owner.all'Address /= Item'Address then
         raise Invalid_Handle;
      elsif Handle.Guard.Active then
         raise Invalid_Handle with
           "cannot submit through an active native operation handle";
      end if;
      Token_Value := new Flyology.Cancellation.Token;
      if Token /= null and then Token.Requested then
         Token_Value.Request;
      end if;
      begin
         Item.State.Submit
           (Input, Token_Value, Deadline, Slot, Generation, Replaced_Token,
            Accepted);
      exception
         when others =>
            Free_Token (Token_Value);
            raise;
      end;
      if Replaced_Token /= null then
         Free_Token (Replaced_Token);
      end if;
      if not Accepted then
         Free_Token (Token_Value);
      end if;
      Handle.Guard.State := Handle.Owner.State'Unchecked_Access;
      Handle.Guard.Slot := Slot;
      Handle.Guard.Generation := Generation;
      Handle.Guard.Active := Accepted;
   end Submit;

   procedure Await
     (Item   : aliased in out Executor;
      Handle : in out Operation_Handle;
      Result : out Result_Type;
      Token  : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last)
   is
      Error_Id : Ada.Exceptions.Exception_Id;
      Message  : Ada.Strings.Unbounded.Unbounded_String;
      Ready    : Boolean := False;

      function Wait_Timeout return Duration is
         Now : Ada.Real_Time.Time;
      begin
         if Deadline = Ada.Real_Time.Time_Last then
            return Flyology.IO.Infinite;
         end if;
         Now := Ada.Real_Time.Clock;
         if Now >= Deadline then
            return 0.0;
         end if;
         return Ada.Real_Time.To_Duration (Deadline - Now);
      end Wait_Timeout;
   begin
      if not Handle.Guard.Active
        or else Handle.Owner.all'Address /= Item'Address
        or else Handle.Guard.Generation = 0
        or else Handle.Guard.Slot > Item.Capacity
      then
         raise Invalid_Handle;
      end if;
      while not Ready loop
         if Token /= null and then Token.Requested then
            Abandon (Item, Handle);
            raise Flyology.Cancellation.Operation_Cancelled;
         elsif Deadline /= Ada.Real_Time.Time_Last
           and then Ada.Real_Time.Clock >= Deadline
         then
            Abandon (Item, Handle);
            raise Flyology.IO.Timeout_Error with
              "native executor await deadline expired";
         end if;
         Item.State.Try_Await
           (Handle.Guard.Slot, Handle.Guard.Generation,
            Result, Error_Id, Message, Ready);
         if not Ready then
            declare
               Completion_FD : Flyology.IO.Descriptor;
               Completed     : Boolean;
            begin
               Item.State.Wait_Source
                 (Handle.Guard.Slot, Handle.Guard.Generation,
                  Completion_FD, Completed);
               if not Completed then
                  if Token = null then
                     declare
                        Ignored : constant Boolean := Flyology.IO.Wait
                          (Completion_FD, Flyology.IO.For_Read,
                           Wait_Timeout);
                        pragma Unreferenced (Ignored);
                     begin
                        null;
                     end;
                  else
                     declare
                        Cancellation_FD : Flyology.IO.Descriptor;
                        Already_Cancelled : Boolean;
                     begin
                        Token.Wait_Source
                          (Cancellation_FD, Already_Cancelled);
                        if not Already_Cancelled then
                           declare
                              Requests : constant
                                Flyology.IO.Wait_Request_Array :=
                                  (1 =>
                                     (FD => Completion_FD,
                                      Condition => Flyology.IO.For_Read),
                                   2 =>
                                     (FD => Cancellation_FD,
                                      Condition => Flyology.IO.For_Read));
                              Ignored : constant Natural :=
                                Flyology.IO.Wait_Any
                                  (Requests, Wait_Timeout);
                              pragma Unreferenced (Ignored);
                           begin
                              null;
                           end;
                        end if;
                     end;
                  end if;
               end if;
            end;
         end if;
      end loop;
      Handle.Guard.Active := False;
      if Error_Id /= Ada.Exceptions.Null_Id then
         Ada.Exceptions.Raise_Exception
           (Error_Id, Ada.Strings.Unbounded.To_String (Message));
      end if;
   end Await;

   procedure Abandon
     (Item : aliased in out Executor; Handle : in out Operation_Handle)
   is
   begin
      if not Handle.Guard.Active
        or else Handle.Owner.all'Address /= Item'Address
      then
         raise Invalid_Handle;
      end if;
      begin
         Item.State.Abandon
           (Handle.Guard.Slot, Handle.Guard.Generation);
      exception
         when others =>
            Handle.Guard.Active := False;
            raise;
      end;
      Handle.Guard.Active := False;
   end Abandon;

   function Statistics (Item : Executor) return Executor_Statistics is
     (Item.State.Statistics);

   overriding procedure Finalize (Item : in out Handle_Guard) is
   begin
      if Item.Active and then Item.State /= null then
         begin
            Item.State.Abandon (Item.Slot, Item.Generation);
         exception
            when others => null;
         end;
         Item.Active := False;
      end if;
   end Finalize;

end Flyology.Native_Executors;
