with Ada.Finalization;
with Ada.Real_Time;
with Flyology;
with Flyology.Cancellation;
with Flyology.Capacity;
with Flyology.Channels.Bounded;
with Flyology.IO;
with Flyology.Native_Executors;
with Flyology.Worker_Pools;
with Interfaces;
with System.Multiprocessors;
with Worker_Pool_Test_Control;

procedure Concurrency_Primitives_Smoke is
   use type Interfaces.Unsigned_64;

   package Integer_Channels is new Flyology.Channels.Bounded (Integer, 0);

   protected Active_Native_Work is
      procedure Reset;
      procedure Mark_Started;
      procedure Mark_Cancellation_Observed;
      entry Wait_Started;
      function Cancellation_Observed return Boolean;
   private
      Started  : Boolean := False;
      Observed : Boolean := False;
   end Active_Native_Work;

   protected body Active_Native_Work is
      procedure Reset is
      begin
         Started := False;
         Observed := False;
      end Reset;

      procedure Mark_Started is
      begin
         Started := True;
      end Mark_Started;

      procedure Mark_Cancellation_Observed is
      begin
         Observed := True;
      end Mark_Cancellation_Observed;

      entry Wait_Started when Started is
      begin
         null;
      end Wait_Started;

      function Cancellation_Observed return Boolean is (Observed);
   end Active_Native_Work;

   procedure Native_Work
     (Input    : Integer;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time;
      Result   : out Integer)
   is
      pragma Unreferenced (Deadline);
   begin
      if Input = 99 then
         declare
            Cancellation_FD   : Flyology.IO.Descriptor;
            Already_Cancelled : Boolean;
         begin
            --  Borrow the executor-owned token's wake descriptor before the
            --  shutdown test arms its persistent signaling failure.
            Token.Wait_Source (Cancellation_FD, Already_Cancelled);
            pragma Assert (not Already_Cancelled);
            pragma Unreferenced (Cancellation_FD);
            Active_Native_Work.Mark_Started;
            while not Token.Requested loop
               delay 0.001;
            end loop;
            Active_Native_Work.Mark_Cancellation_Observed;
         end;
         raise Flyology.Cancellation.Operation_Cancelled;
      end if;

      --  Completed-operation abandonment tests also need an existing token
      --  wake descriptor to exercise their signaling-failure path.
      declare
         Cancellation_FD   : Flyology.IO.Descriptor;
         Already_Cancelled : Boolean;
      begin
         Token.Wait_Source (Cancellation_FD, Already_Cancelled);
         pragma Assert (not Already_Cancelled);
         pragma Unreferenced (Cancellation_FD);
      end;
      Result := Input * 2;
   end Native_Work;

   package Native_Executors is new Flyology.Native_Executors
     (Integer, Integer, Native_Work);

   --  Result_Type is a generic formal private type, so copying a result into
   --  the executor's bounded storage runs application code that may raise.
   --  This actual models a copy that fails once, as an Unbounded_String or
   --  other allocating component would under memory pressure. Only the worker
   --  task arms and observes the injection, and the executor's protected
   --  state orders it against the waiting caller.
   Fragile_Copy_Armed : Boolean := False;
   Fragile_Copy_Failures : Natural := 0;

   type Fragile_Result is new Ada.Finalization.Controlled with record
      Value : Integer := 0;
   end record;

   overriding procedure Adjust (Item : in out Fragile_Result);

   overriding procedure Adjust (Item : in out Fragile_Result) is
      pragma Unreferenced (Item);
   begin
      if Fragile_Copy_Armed then
         Fragile_Copy_Armed := False;
         Fragile_Copy_Failures := Fragile_Copy_Failures + 1;
         raise Storage_Error with "injected native executor result copy";
      end if;
   end Adjust;

   procedure Fragile_Work
     (Input    : Integer;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time;
      Result   : out Fragile_Result)
   is
      pragma Unreferenced (Token, Deadline);
   begin
      Result.Value := Input * 3;
      if Input = 7 then
         --  Arm only after this operation's own result is built so the
         --  executor's completion copy is the failing one.
         Fragile_Copy_Armed := True;
      end if;
   end Fragile_Work;

   package Fragile_Executors is new Flyology.Native_Executors
     (Integer, Fragile_Result, Fragile_Work);

   protected type Boolean_Result is
      procedure Set (Value : Boolean);
      entry Wait (Value : out Boolean);
   private
      Ready  : Boolean := False;
      Stored : Boolean := False;
   end Boolean_Result;

   protected body Boolean_Result is
      procedure Set (Value : Boolean) is
      begin
         Stored := Value;
         Ready := True;
      end Set;

      entry Wait (Value : out Boolean) when Ready is
      begin
         Value := Stored;
      end Wait;
   end Boolean_Result;

   generic
      Model : Flyology.Execution_Model;
      CPU   : System.Multiprocessors.CPU_Range;
   procedure Exercise_Task_Waits;

   procedure Exercise_Task_Waits is
      use type Flyology.Capacity.Acquire_Result;

      Gate     : aliased Flyology.Capacity.Gate (Capacity => 1);
      Accepted : Boolean;
      Attempt  : Flyology.Capacity.Acquire_Result;
   begin
      Gate.Acquire (Accepted);
      pragma Assert (Accepted);
      Gate.Try_Acquire (Attempt);
      pragma Assert (Attempt = Flyology.Capacity.Gate_Full);
      Flyology.Capacity.Timed_Acquire (Gate, 0.0, Attempt);
      pragma Assert (Attempt = Flyology.Capacity.Acquire_Timed_Out);

      declare
         Outcome : Boolean_Result;

         task Waiter with CPU => CPU is
            pragma Task_Info (Model);
         end Waiter;

         task body Waiter is
            Was_Accepted : Boolean;
         begin
            Gate.Acquire (Was_Accepted);
            Outcome.Set (Was_Accepted);
         end Waiter;

         Was_Accepted : Boolean;
      begin
         while Gate.Waiting = 0 loop
            delay 0.0;
         end loop;
         pragma Assert (Gate.Active = 1);
         Gate.Request_Shutdown;
         Outcome.Wait (Was_Accepted);
         pragma Assert (not Was_Accepted);
         Gate.Release;
         Gate.Await_Drained;
         pragma Assert (Gate.Active = 0);
         pragma Assert (Gate.Shutdown_Requested);
         Gate.Try_Acquire (Attempt);
         pragma Assert (Attempt = Flyology.Capacity.Gate_Closed);
      end;

      declare
         Stop    : aliased Flyology.Cancellation.Token;
         Outcome : Boolean_Result;

         task Cancellation_Waiter with CPU => CPU is
            pragma Task_Info (Model);
         end Cancellation_Waiter;

         task body Cancellation_Waiter is
         begin
            Stop.Await_Request;
            Outcome.Set (True);
         end Cancellation_Waiter;

         Woke : Boolean;
      begin
         Stop.Request;
         Outcome.Wait (Woke);
         pragma Assert (Woke and Stop.Requested);
      end;

      declare
         Queue   : Integer_Channels.Channel (Capacity => 1);
         Outcome : Boolean_Result;

         task Receiver with CPU => CPU is
            pragma Task_Info (Model);
         end Receiver;

         task body Receiver is
            Value  : Integer;
            Closed : Boolean := False;
         begin
            begin
               Queue.Receive (Value);
            exception
               when Integer_Channels.Channel_Closed =>
                  Closed := True;
            end;
            Outcome.Set (Closed);
         end Receiver;

         Closed : Boolean;
      begin
         while Queue.Current.Waiting_Receivers = 0 loop
            delay 0.0;
         end loop;
         Queue.Close;
         Outcome.Wait (Closed);
         pragma Assert (Closed);
         Queue.Await_Drained;
      end;

      declare
         Queue : Integer_Channels.Channel (Capacity => 1);
      begin
         Queue.Send (1);
         declare
            Outcome : Boolean_Result;

            task Sender with CPU => CPU is
               pragma Task_Info (Model);
            end Sender;

            task body Sender is
               Closed : Boolean := False;
            begin
               begin
                  Queue.Send (2);
               exception
                  when Integer_Channels.Channel_Closed =>
                     Closed := True;
               end;
               Outcome.Set (Closed);
            end Sender;

            Closed : Boolean;
            Value  : Integer;
         begin
            while Queue.Current.Waiting_Senders = 0 loop
               delay 0.0;
            end loop;
            Queue.Close;
            Outcome.Wait (Closed);
            pragma Assert (Closed);
            Queue.Receive (Value);
            pragma Assert (Value = 1);
            Queue.Await_Drained;
         end;
      end;
   end Exercise_Task_Waits;

   procedure Exercise_Lightweight_Waits is new Exercise_Task_Waits
     (Model => Flyology.Lightweight_Task, CPU => 1);

   procedure Exercise_Native_Waits is new Exercise_Task_Waits
     (Model => Flyology.Native_Task,
      CPU   => System.Multiprocessors.Not_A_Specific_CPU);

   procedure Exercise_Channel is
      use type Integer_Channels.Try_Send_Result;
      use type Integer_Channels.Try_Receive_Result;

      Queue          : Integer_Channels.Channel (Capacity => 2);
      Send_Result    : Integer_Channels.Try_Send_Result;
      Receive_Result : Integer_Channels.Try_Receive_Result;
      Value          : Integer := 0;
      Timed_Out      : Boolean;
   begin
      Queue.Try_Send (1, Send_Result);
      pragma Assert (Send_Result = Integer_Channels.Item_Sent);
      Queue.Try_Send (2, Send_Result);
      pragma Assert (Send_Result = Integer_Channels.Item_Sent);
      Queue.Try_Send (3, Send_Result);
      pragma Assert (Send_Result = Integer_Channels.Channel_Full);

      Timed_Out := False;
      begin
         Integer_Channels.Timed_Send (Queue, 3, 0.0);
      exception
         when Integer_Channels.Timeout_Error =>
            Timed_Out := True;
      end;
      pragma Assert (Timed_Out);

      Queue.Try_Receive (Value, Receive_Result);
      pragma Assert
        (Receive_Result = Integer_Channels.Item_Received and Value = 1);
      Queue.Send (3);
      Queue.Close;

      Queue.Try_Send (4, Send_Result);
      pragma Assert (Send_Result = Integer_Channels.Send_Closed);
      Queue.Receive (Value);
      pragma Assert (Value = 2);
      Queue.Receive (Value);
      pragma Assert (Value = 3);
      Queue.Await_Drained;
      Value := 41;
      Queue.Try_Receive (Value, Receive_Result);
      pragma Assert
        (Receive_Result = Integer_Channels.Receive_Closed and Value = 41);

      declare
         Empty : Integer_Channels.Channel (Capacity => 1);
      begin
         Value := 42;
         Empty.Try_Receive (Value, Receive_Result);
         pragma Assert
           (Receive_Result = Integer_Channels.Channel_Empty and Value = 42);

         Timed_Out := False;
         begin
            Integer_Channels.Timed_Receive (Empty, Value, 0.0);
         exception
            when Integer_Channels.Timeout_Error =>
               Timed_Out := True;
         end;
         pragma Assert (Timed_Out);
         Empty.Close;
      end;
   end Exercise_Channel;

   procedure Exercise_Native_Executor_Abandon_Failure is
      Item     : aliased Native_Executors.Executor
        (Workers => 1, Capacity => 1);
      Accepted : Boolean;

      procedure Wait_For_Success (Count : Interfaces.Unsigned_64) is
      begin
         for Attempt in 1 .. 100 loop
            exit when
              Native_Executors.Statistics (Item).Successful_Executions =
                Count;
            delay 0.001;
         end loop;
         pragma Assert
           (Native_Executors.Statistics (Item).Successful_Executions = Count);
      end Wait_For_Success;
   begin
      Worker_Pool_Test_Control.Reset;
      Native_Executors.Start (Item);
      declare
         Handle : Native_Executors.Operation_Handle (Item'Access);
         Failed : Boolean := False;
      begin
         Native_Executors.Submit
           (Item, 1, null, Ada.Real_Time.Time_Last, Handle, Accepted);
         pragma Assert (Accepted);
         Wait_For_Success (1);
         Worker_Pool_Test_Control.Fail_Native_Executor_Cancellation_Once;
         begin
            Native_Executors.Abandon (Item, Handle);
         exception
            when Program_Error => Failed := True;
         end;
         pragma Assert (Failed);
         pragma Assert
           (Native_Executors.Statistics (Item).Outstanding_Operations = 0);
      end;

      declare
         Handle : Native_Executors.Operation_Handle (Item'Access);
      begin
         Native_Executors.Submit
           (Item, 2, null, Ada.Real_Time.Time_Last, Handle, Accepted);
         pragma Assert (Accepted);
         Wait_For_Success (2);
         Worker_Pool_Test_Control.Fail_Native_Executor_Cancellation_Once;
         --  Finalization must consume the handle and release the completed
         --  slot even though cancellation signalling raises internally.
      end;
      pragma Assert
        (Native_Executors.Statistics (Item).Outstanding_Operations = 0);

      declare
         Handle : Native_Executors.Operation_Handle (Item'Access);
         Result : Integer;
      begin
         Native_Executors.Submit
           (Item, 3, null, Ada.Real_Time.Time_Last, Handle, Accepted);
         pragma Assert (Accepted);
         Native_Executors.Await (Item, Handle, Result);
         pragma Assert (Result = 6);
      end;

      declare
         Handle : Native_Executors.Operation_Handle (Item'Access);
         Failed : Boolean := False;
      begin
         Worker_Pool_Test_Control.Arm_Native_Executor_Completion_Wake;
         Native_Executors.Submit
           (Item, 4, null, Ada.Real_Time.Time_Last, Handle, Accepted);
         pragma Assert (Accepted);
         Wait_For_Success (4);
         Worker_Pool_Test_Control.Fail_Native_Executor_Consume_Once;
         begin
            Native_Executors.Abandon (Item, Handle);
         exception
            when Program_Error => Failed := True;
         end;
         pragma Assert (Failed);
         pragma Assert
           (Native_Executors.Statistics (Item).Outstanding_Operations = 0);
      end;

      --  A failed wake consumption must not retain capacity or leave the
      --  recycled completion descriptor spuriously readable.
      declare
         Handle : Native_Executors.Operation_Handle (Item'Access);
         Result : Integer;
      begin
         Native_Executors.Submit
           (Item, 5, null, Ada.Real_Time.Time_Last, Handle, Accepted);
         pragma Assert (Accepted);
         Native_Executors.Await (Item, Handle, Result);
         pragma Assert (Result = 10);
      end;
      Worker_Pool_Test_Control.Reset;
      Native_Executors.Shutdown (Item);
   end Exercise_Native_Executor_Abandon_Failure;

   procedure Exercise_Native_Executor_Result_Copy_Failure is
      use type Ada.Real_Time.Time;

      Item      : aliased Fragile_Executors.Executor
        (Workers => 1, Capacity => 1);
      Accepted  : Boolean;
      Reported  : Boolean := False;
      Timed_Out : Boolean := False;
      Result    : Fragile_Result;
   begin
      Worker_Pool_Test_Control.Reset;
      Fragile_Executors.Start (Item);
      declare
         Handle : Fragile_Executors.Operation_Handle (Item'Access);
      begin
         Fragile_Executors.Submit
           (Item, 7, null, Ada.Real_Time.Time_Last, Handle, Accepted);
         pragma Assert (Accepted);
         begin
            Fragile_Executors.Await
              (Item, Handle, Result,
               Deadline => Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5));
         exception
            when Flyology.IO.Timeout_Error =>
               Timed_Out := True;
            when others =>
               Reported := True;
         end;
      end;
      pragma Assert (Fragile_Copy_Failures = 1);
      --  A failing result copy is a terminal outcome for the operation. The
      --  waiting caller must observe it instead of sleeping on a slot that
      --  no worker still owns.
      pragma Assert (not Timed_Out);
      pragma Assert (Reported);
      pragma Assert
        (Fragile_Executors.Statistics (Item).Failed_Executions = 1);
      pragma Assert
        (Fragile_Executors.Statistics (Item).Successful_Executions = 0);
      pragma Assert
        (Fragile_Executors.Statistics (Item).Running_Operations = 0);
      pragma Assert
        (Fragile_Executors.Statistics (Item).Outstanding_Operations = 0);

      --  Exactly one accounting transition happened, so the slot is free and
      --  the executor still admits and completes further work.
      declare
         Handle : Fragile_Executors.Operation_Handle (Item'Access);
      begin
         Fragile_Executors.Submit
           (Item, 4, null, Ada.Real_Time.Time_Last, Handle, Accepted);
         pragma Assert (Accepted);
         Fragile_Executors.Await
           (Item, Handle, Result,
            Deadline => Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5));
         pragma Assert (Result.Value = 12);
      end;
      pragma Assert
        (Fragile_Executors.Statistics (Item).Successful_Executions = 1);
      Fragile_Executors.Shutdown (Item);
   end Exercise_Native_Executor_Result_Copy_Failure;

   procedure Exercise_Native_Executor_Activation_Failure is
      --  Instantiating locally makes this subprogram the master of the worker
      --  collection, so a worker orphaned by a partial activation must
      --  terminate before the procedure can return.
      package Local_Executors is new Flyology.Native_Executors
        (Integer, Integer, Native_Work);
      Failed : Boolean := False;
   begin
      Worker_Pool_Test_Control.Reset;
      Worker_Pool_Test_Control.Fail_Activation_At (2);
      declare
         Item : aliased Local_Executors.Executor
           (Workers => 3, Capacity => 1);
      begin
         begin
            Local_Executors.Start (Item);
         exception
            when Tasking_Error | Storage_Error =>
               Failed := True;
         end;
      end;
      Worker_Pool_Test_Control.Reset;
      pragma Assert (Failed);
   end Exercise_Native_Executor_Activation_Failure;

   procedure Exercise_Native_Executor_Shutdown_Failure is
      Item     : aliased Native_Executors.Executor
        (Workers => 1, Capacity => 1);
      Handle   : Native_Executors.Operation_Handle (Item'Access);
      Accepted : Boolean;
      Failed   : Boolean := False;
      Result   : Integer;
   begin
      Worker_Pool_Test_Control.Reset;
      Active_Native_Work.Reset;
      Native_Executors.Start (Item);
      Native_Executors.Submit
        (Item, 99, null, Ada.Real_Time.Time_Last, Handle, Accepted);
      pragma Assert (Accepted);
      Active_Native_Work.Wait_Started;

      Worker_Pool_Test_Control.Fail_Native_Executor_Cancellations (100);
      begin
         Native_Executors.Shutdown (Item);
      exception
         when Program_Error => Failed := True;
      end;
      pragma Assert (Failed);
      --  A persistent signaling fault is observed once, not retried in an
      --  abort-deferred cleanup loop. Logical cancellation still lets the
      --  active worker terminate before the original failure is re-raised.
      pragma Assert
        (Worker_Pool_Test_Control
           .Remaining_Native_Executor_Cancellation_Failures = 99);
      pragma Assert (Active_Native_Work.Cancellation_Observed);
      Worker_Pool_Test_Control.Reset;

      --  The failing owner still publishes terminal completion, so this
      --  idempotent call must return rather than waiting forever.
      Native_Executors.Shutdown (Item);
      begin
         Native_Executors.Await (Item, Handle, Result);
         pragma Assert (False);
      exception
         when Flyology.Cancellation.Operation_Cancelled => null;
      end;
      pragma Assert
        (Native_Executors.Statistics (Item).Outstanding_Operations = 0);
   end Exercise_Native_Executor_Shutdown_Failure;

   procedure Exercise_Native_Executor_Token_Cleanup_Abort is
      Item     : aliased Native_Executors.Executor
        (Workers => 1, Capacity => 1);
      Handle   : Native_Executors.Operation_Handle (Item'Access);
      Accepted : Boolean;
      Result   : Integer;
   begin
      Worker_Pool_Test_Control.Reset;
      Native_Executors.Start (Item);
      Native_Executors.Submit
        (Item, 6, null, Ada.Real_Time.Time_Last, Handle, Accepted);
      pragma Assert (Accepted);
      for Attempt in 1 .. 100 loop
         exit when
           Native_Executors.Statistics (Item).Successful_Executions = 1;
         delay 0.001;
      end loop;
      pragma Assert
        (Native_Executors.Statistics (Item).Successful_Executions = 1);

      Worker_Pool_Test_Control.Arm_Token_Cleanup_Barrier;
      declare
         task Stopper is
            pragma Task_Info (Flyology.Native_Task);
         end Stopper;

         task body Stopper is
         begin
            Native_Executors.Shutdown (Item);
         end Stopper;
      begin
         Worker_Pool_Test_Control.Wait_Token_Cleanup_Barrier;
         abort Stopper;
         Worker_Pool_Test_Control.Release_Token_Cleanup_Barrier;
      end;

      Native_Executors.Shutdown (Item);
      pragma Assert
        (Worker_Pool_Test_Control.Outstanding_Cleanup_Tokens = 0);
      Native_Executors.Await (Item, Handle, Result);
      pragma Assert (Result = 12);
   end Exercise_Native_Executor_Token_Cleanup_Abort;

   --  A timed acquisition must stay abort-safe. The barrier holds the aborted
   --  caller inside the Gate protected action that counts the permit, so the
   --  abort takes effect in the window between acquisition and the caller
   --  recording the permit. Only a cleanup obligation published inside that
   --  protected action can return the permit.
   procedure Exercise_Capacity_Timed_Acquire_Abort is
      Admission : aliased Flyology.Capacity.Gate (Capacity => 1);

      type Permit_Guard (Item : not null access Flyology.Capacity.Gate) is
        new Ada.Finalization.Limited_Controlled with record
         Armed : aliased Boolean := False;
      end record;

      overriding procedure Finalize (Guard : in out Permit_Guard);

      overriding procedure Finalize (Guard : in out Permit_Guard) is
      begin
         if Guard.Armed then
            Guard.Item.Release (Guard.Armed'Access);
         end if;
      end Finalize;

      use type Flyology.Capacity.Acquire_Result;
   begin
      --  Without an abort the obligation tracks the reported result.
      declare
         Guard   : Permit_Guard (Admission'Access);
         Outcome : Flyology.Capacity.Acquire_Result;
      begin
         Flyology.Capacity.Timed_Acquire
           (Admission, 1.0, Outcome, Guard.Armed'Access);
         pragma Assert (Outcome = Flyology.Capacity.Permit_Acquired);
         pragma Assert (Guard.Armed);
         pragma Assert (Admission.Active = 1);
      end;
      pragma Assert (Admission.Active = 0);

      Worker_Pool_Test_Control.Reset;
      Worker_Pool_Test_Control.Arm_Capacity_Acquire_Barrier;
      declare
         task Acquirer is
            pragma Task_Info (Flyology.Native_Task);
         end Acquirer;

         task body Acquirer is
            Guard   : Permit_Guard (Admission'Access);
            Outcome : Flyology.Capacity.Acquire_Result;
         begin
            Flyology.Capacity.Timed_Acquire
              (Admission, 10.0, Outcome, Guard.Armed'Access);
            pragma Assert
              (Guard.Armed =
                 (Outcome = Flyology.Capacity.Permit_Acquired));
         end Acquirer;
      begin
         Worker_Pool_Test_Control.Wait_Capacity_Acquire_Barrier;
         abort Acquirer;
         Worker_Pool_Test_Control.Release_Capacity_Acquire_Barrier;
      end;

      pragma Assert (Admission.Active = 0);
      pragma Assert (Admission.Waiting = 0);
      Admission.Request_Shutdown;
      Admission.Await_Drained;
   end Exercise_Capacity_Timed_Acquire_Abort;

   procedure Exercise_Native_Executor_Shutdown_Abort is
      Item : aliased Native_Executors.Executor
        (Workers => 1, Capacity => 1);
   begin
      Worker_Pool_Test_Control.Reset;
      Native_Executors.Start (Item);
      Worker_Pool_Test_Control.Arm_Shutdown_Barrier;
      declare
         task Stopper is
            pragma Task_Info (Flyology.Native_Task);
         end Stopper;

         task body Stopper is
         begin
            Native_Executors.Shutdown (Item);
         end Stopper;
      begin
         Worker_Pool_Test_Control.Wait_Shutdown_Barrier;
         abort Stopper;
         Worker_Pool_Test_Control.Release_Shutdown_Barrier;
      end;
      Worker_Pool_Test_Control.Reset;

      --  Abort-deferred cleanup joins and releases the pool, then publishes
      --  completion so an idempotent caller does not wait on the lost owner.
      Native_Executors.Shutdown (Item);
   end Exercise_Native_Executor_Shutdown_Abort;

   protected type Totals is
      procedure Add (Value : Integer);
      function Count return Natural;
      function Sum return Integer;
   private
      Seen  : Natural := 0;
      Total : Integer := 0;
   end Totals;

   protected body Totals is
      procedure Add (Value : Integer) is
      begin
         Seen := Seen + 1;
         Total := Total + Value;
      end Add;

      function Count return Natural is (Seen);
      function Sum return Integer is (Total);
   end Totals;

   generic
      Model : Flyology.Execution_Model;
      CPU   : System.Multiprocessors.CPU_Range;
   procedure Exercise_Worker_Pool;

   procedure Exercise_Worker_Pool is
      procedure Process
        (Context  : in out Totals;
         Job      : Integer;
         Stopping : not null access Flyology.Cancellation.Token)
      is
         pragma Unreferenced (Stopping);
      begin
         if Job < 0 then
            raise Program_Error with "injected worker failure";
         end if;
         Context.Add (Job);
      end Process;

      package Pools is new Flyology.Worker_Pools
        (Job_Type       => Integer,
         Empty_Job      => 0,
         Worker_Context => Totals,
         Process        => Process,
         Worker_Model   => Model,
         Worker_CPU     => CPU);

      type Run_Result is (Run_Succeeded, Run_Failed, Run_Unexpected);

      protected type Run_Outcome is
         procedure Set (Value : Run_Result);
         entry Wait (Value : out Run_Result);
      private
         Ready  : Boolean := False;
         Stored : Run_Result := Run_Unexpected;
      end Run_Outcome;

      protected body Run_Outcome is
         procedure Set (Value : Run_Result) is
         begin
            Stored := Value;
            Ready := True;
         end Set;

         entry Wait (Value : out Run_Result) when Ready is
         begin
            Value := Stored;
         end Wait;
      end Run_Outcome;

      procedure Exercise_Success is
         Item    : aliased Pools.Pool
           (Worker_Count => 3, Queue_Capacity => 2);
         Context : aliased Totals;
         Outcome : Run_Outcome;

         task Runner;

         task body Runner is
         begin
            begin
               Pools.Run (Item, Context);
               Outcome.Set (Run_Succeeded);
            exception
               when others =>
                  Outcome.Set (Run_Unexpected);
            end;
         end Runner;

         Accepted : Boolean;
         Result   : Run_Result;
      begin
         for Job in 1 .. 20 loop
            Pools.Submit (Item, Job, Accepted);
            pragma Assert (Accepted);
         end loop;
         Pools.Request_Shutdown (Item);
         Outcome.Wait (Result);
         pragma Assert (Result = Run_Succeeded);
         pragma Assert (Context.Count = 20);
         pragma Assert (Context.Sum = 210);
         pragma Assert (not Pools.Current (Item).Running);
         pragma Assert (Pools.Current (Item).Shutdown_Requested);
         pragma Assert (Pools.Current (Item).Pending_Jobs = 0);
         pragma Assert (Pools.Current (Item).Completed_Jobs = 20);
         pragma Assert (Pools.Current (Item).Failures = 0);
      end Exercise_Success;

      procedure Exercise_Failure is
         Item     : aliased Pools.Pool
           (Worker_Count => 2, Queue_Capacity => 4);
         Context  : aliased Totals;
         Accepted : Boolean;
      begin
         Pools.Submit (Item, 1, Accepted);
         pragma Assert (Accepted);
         Pools.Submit (Item, -1, Accepted);
         pragma Assert (Accepted);
         Pools.Submit (Item, 2, Accepted);
         pragma Assert (Accepted);

         declare
            Outcome : Run_Outcome;

            task Runner;

            task body Runner is
            begin
               begin
                  Pools.Run (Item, Context);
                  Outcome.Set (Run_Unexpected);
               exception
                  when Pools.Pool_Failed =>
                     Outcome.Set (Run_Failed);
                  when others =>
                     Outcome.Set (Run_Unexpected);
               end;
            end Runner;

            Result : Run_Result;
         begin
            Outcome.Wait (Result);
            pragma Assert (Result = Run_Failed);
         end;

         pragma Assert (Context.Count = 2);
         pragma Assert (Context.Sum = 3);
         pragma Assert (Pools.Current (Item).Completed_Jobs = 2);
         pragma Assert (Pools.Current (Item).Failures = 1);
         pragma Assert
           (Pools.First_Failure_Information (Item)'Length > 0);

         declare
            Rejected : Boolean := False;
         begin
            begin
               Pools.Run (Item, Context);
            exception
               when Program_Error =>
                  Rejected := True;
            end;
            pragma Assert (Rejected);
         end;
      end Exercise_Failure;

      procedure Exercise_Activation_Failure is
         Item    : aliased Pools.Pool
           (Worker_Count => 3, Queue_Capacity => 2);
         Context : aliased Totals;
         Failed  : Boolean := False;
      begin
         Worker_Pool_Test_Control.Reset;
         Worker_Pool_Test_Control.Fail_Activation_At (2);

         begin
            Pools.Run (Item, Context);
         exception
            when Tasking_Error =>
               Failed := True;
         end;

         Worker_Pool_Test_Control.Reset;
         pragma Assert (Failed);
         pragma Assert (not Pools.Current (Item).Running);
         pragma Assert (Pools.Current (Item).Shutdown_Requested);
      end Exercise_Activation_Failure;

      procedure Exercise_Abort_Safe_Shutdown is
         Item    : aliased Pools.Pool
           (Worker_Count => 2, Queue_Capacity => 2);
         Context : aliased Totals;
         Outcome : Run_Outcome;

         task Runner;

         task body Runner is
         begin
            begin
               Pools.Run (Item, Context);
               Outcome.Set (Run_Succeeded);
            exception
               when others =>
                  Outcome.Set (Run_Unexpected);
            end;
         end Runner;

         Result : Run_Result;
      begin
         while not Pools.Current (Item).Running loop
            delay 0.0;
         end loop;

         Worker_Pool_Test_Control.Reset;
         Worker_Pool_Test_Control.Arm_Shutdown_Barrier;
         declare
            task Stopper is
               pragma Task_Info (Flyology.Native_Task);
            end Stopper;

            task body Stopper is
            begin
               Pools.Request_Shutdown (Item);
            end Stopper;
         begin
            Worker_Pool_Test_Control.Wait_Shutdown_Barrier;
            abort Stopper;
            Worker_Pool_Test_Control.Release_Shutdown_Barrier;
         end;

         Outcome.Wait (Result);
         Worker_Pool_Test_Control.Reset;
         pragma Assert (Result = Run_Succeeded);
         pragma Assert (not Pools.Current (Item).Running);
         pragma Assert (Pools.Current (Item).Shutdown_Requested);
         pragma Assert (Pools.Current (Item).Pending_Jobs = 0);
      end Exercise_Abort_Safe_Shutdown;

      procedure Exercise_Run_Abort is
         Item     : aliased Pools.Pool
           (Worker_Count => 2, Queue_Capacity => 2);
         Context  : aliased Totals;
         Accepted : Boolean;
      begin
         declare
            task Runner;

            task body Runner is
            begin
               Pools.Run (Item, Context);
            end Runner;
         begin
            while not Pools.Current (Item).Running loop
               delay 0.0;
            end loop;
            abort Runner;
         end;

         pragma Assert (not Pools.Current (Item).Running);
         pragma Assert (Pools.Current (Item).Shutdown_Requested);
         pragma Assert (Pools.Current (Item).Pending_Jobs = 0);

         Pools.Submit (Item, 1, Accepted);
         pragma Assert (not Accepted);
      end Exercise_Run_Abort;

      --  A second Run must be rejected with Program_Error and must leave the
      --  run that already owns the pool untouched: admission stays open, jobs
      --  still complete, and the owner still joins its workers.
      procedure Exercise_Duplicate_Run is
         Item    : aliased Pools.Pool
           (Worker_Count => 2, Queue_Capacity => 2);
         Context : aliased Totals;
         Outcome : Run_Outcome;

         Rejected      : Boolean := False;
         Still_Running : Boolean := False;
         Still_Open    : Boolean := False;
         Accepted      : Boolean := False;
         Joined        : Boolean := False;
         Result        : Run_Result := Run_Unexpected;
      begin
         declare
            task Runner;

            task body Runner is
            begin
               begin
                  Pools.Run (Item, Context);
                  Outcome.Set (Run_Succeeded);
               exception
                  when others =>
                     Outcome.Set (Run_Unexpected);
               end;
            end Runner;
         begin
            while not Pools.Current (Item).Running loop
               delay 0.0;
            end loop;

            begin
               Pools.Run (Item, Context);
            exception
               when Program_Error =>
                  Rejected := True;
               when others =>
                  null;
            end;

            Still_Running := Pools.Current (Item).Running;
            Still_Open := not Pools.Current (Item).Shutdown_Requested;

            Pools.Submit (Item, 5, Accepted);
            Pools.Request_Shutdown (Item);

            --  Bound the join. A rejected caller that terminalized the live
            --  pool leaves the owner permanently queued on its worker
            --  barrier, which must be reported rather than hang the suite.
            select
               Outcome.Wait (Result);
               Joined := True;
            or
               delay 10.0;
               abort Runner;
            end select;
         end;

         pragma Assert (Rejected);
         pragma Assert (Still_Running);
         pragma Assert (Still_Open);
         pragma Assert (Accepted);
         pragma Assert (Joined);
         pragma Assert (Result = Run_Succeeded);
         pragma Assert (Context.Count = 1);
         pragma Assert (Context.Sum = 5);
         pragma Assert (Pools.Current (Item).Completed_Jobs = 1);
         pragma Assert (Pools.Current (Item).Failures = 0);
      end Exercise_Duplicate_Run;

      --  Claiming the one-shot run is a single abort-deferred step. A caller
      --  aborted while it is still trying to claim never armed teardown, so
      --  the owning run keeps its workers, its queue, and its join barrier.
      procedure Exercise_Claim_Abort is
         Item    : aliased Pools.Pool
           (Worker_Count => 2, Queue_Capacity => 2);
         Context : aliased Totals;
         Outcome : Run_Outcome;

         Still_Running : Boolean := False;
         Still_Open    : Boolean := False;
         Accepted      : Boolean := False;
         Joined        : Boolean := False;
         Result        : Run_Result := Run_Unexpected;
      begin
         declare
            task Runner;

            task body Runner is
            begin
               begin
                  Pools.Run (Item, Context);
                  Outcome.Set (Run_Succeeded);
               exception
                  when others =>
                     Outcome.Set (Run_Unexpected);
               end;
            end Runner;
         begin
            while not Pools.Current (Item).Running loop
               delay 0.0;
            end loop;

            Worker_Pool_Test_Control.Reset;
            Worker_Pool_Test_Control.Arm_Run_Claim_Barrier;
            declare
               task Claimer is
                  pragma Task_Info (Flyology.Native_Task);
               end Claimer;

               task body Claimer is
               begin
                  Pools.Run (Item, Context);
               exception
                  when others =>
                     null;
               end Claimer;
            begin
               Worker_Pool_Test_Control.Wait_Run_Claim_Barrier;
               abort Claimer;
               Worker_Pool_Test_Control.Release_Run_Claim_Barrier;
            end;
            Worker_Pool_Test_Control.Reset;

            Still_Running := Pools.Current (Item).Running;
            Still_Open := not Pools.Current (Item).Shutdown_Requested;

            Pools.Submit (Item, 9, Accepted);
            Pools.Request_Shutdown (Item);

            select
               Outcome.Wait (Result);
               Joined := True;
            or
               delay 10.0;
               abort Runner;
            end select;
         end;

         pragma Assert (Still_Running);
         pragma Assert (Still_Open);
         pragma Assert (Accepted);
         pragma Assert (Joined);
         pragma Assert (Result = Run_Succeeded);
         pragma Assert (Context.Count = 1);
         pragma Assert (Context.Sum = 9);
         pragma Assert (Pools.Current (Item).Completed_Jobs = 1);
         pragma Assert (Pools.Current (Item).Failures = 0);
      end Exercise_Claim_Abort;
   begin
      Exercise_Success;
      Exercise_Failure;
      Exercise_Activation_Failure;
      Exercise_Abort_Safe_Shutdown;
      Exercise_Run_Abort;
      Exercise_Duplicate_Run;
      Exercise_Claim_Abort;
   end Exercise_Worker_Pool;

   procedure Exercise_Lightweight_Pool is new Exercise_Worker_Pool
     (Model => Flyology.Lightweight_Task, CPU => 1);

   procedure Exercise_Native_Pool is new Exercise_Worker_Pool
     (Model => Flyology.Native_Task,
      CPU   => System.Multiprocessors.Not_A_Specific_CPU);

begin
   Exercise_Channel;
   Exercise_Native_Executor_Result_Copy_Failure;
   Exercise_Native_Executor_Activation_Failure;
   Exercise_Native_Executor_Abandon_Failure;
   Exercise_Native_Executor_Shutdown_Failure;
   Exercise_Native_Executor_Shutdown_Abort;
   Exercise_Native_Executor_Token_Cleanup_Abort;
   Exercise_Capacity_Timed_Acquire_Abort;
   Exercise_Lightweight_Waits;
   Exercise_Native_Waits;
   Exercise_Lightweight_Pool;
   Exercise_Native_Pool;
end Concurrency_Primitives_Smoke;
