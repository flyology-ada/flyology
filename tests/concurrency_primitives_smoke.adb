with Flyology;
with Flyology.Cancellation;
with Flyology.Capacity;
with Flyology.Channels.Bounded;
with Flyology.Worker_Pools;
with System.Multiprocessors;
with Worker_Pool_Test_Control;

procedure Concurrency_Primitives_Smoke is

   package Integer_Channels is new Flyology.Channels.Bounded (Integer);

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
   begin
      Exercise_Success;
      Exercise_Failure;
      Exercise_Activation_Failure;
      Exercise_Abort_Safe_Shutdown;
      Exercise_Run_Abort;
   end Exercise_Worker_Pool;

   procedure Exercise_Lightweight_Pool is new Exercise_Worker_Pool
     (Model => Flyology.Lightweight_Task, CPU => 1);

   procedure Exercise_Native_Pool is new Exercise_Worker_Pool
     (Model => Flyology.Native_Task,
      CPU   => System.Multiprocessors.Not_A_Specific_CPU);

begin
   Exercise_Channel;
   Exercise_Lightweight_Waits;
   Exercise_Native_Waits;
   Exercise_Lightweight_Pool;
   Exercise_Native_Pool;
end Concurrency_Primitives_Smoke;
