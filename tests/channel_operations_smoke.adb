with Ada.Exceptions;
with Ada.Text_IO;
with Flyology;
with Flyology.Channel_Testing;
with Flyology.Channels.Bounded;
with Flyology.IO.Timers;
with Flyology.Operations;

procedure Channel_Operations_Smoke is
   package Integer_Channels is new
     Flyology.Channels.Bounded (Element_Type => Integer, Empty_Value => 0);

   use type Integer_Channels.Try_Receive_Result;
   use type Integer_Channels.Try_Send_Result;
   use type Flyology.Execution_Model;

   function Ref
     (Item : Flyology.Operations.Operation'Class)
      return Flyology.Operations.Operation_Reference
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
      --  The prepared lightweight runtime tracks protected nesting. Reject
      --  the wrapper call before it commits a value or reaches post-lock I/O.
      if Model = Flyology.Lightweight_Task then
         declare
            Channel  : Integer_Channels.Channel (Capacity => 1);
            Status   : Integer_Channels.Try_Send_Result;
            Rejected : Boolean := False;

            protected Probe is
               procedure Attempt;
            end Probe;

            protected body Probe is
               procedure Attempt is
               begin
                  Channel.Try_Send (91, Status);
               end Attempt;
            end Probe;
         begin
            begin
               Probe.Attempt;
            exception
               when Program_Error =>
                  Rejected := True;
            end;
            Passed :=
              Passed and then Rejected and then Channel.Current.Pending = 0;
         end;
      end if;

      --  Clearing happens before the protected call can queue. Aborting at
      --  that exact boundary therefore leaves authoritative false evidence
      --  and no buffered value, even when the token arrived stale and true.
      declare
         Channel  : Integer_Channels.Channel (Capacity => 1);
         Accepted : aliased Boolean := True;
         Result   : Integer_Channels.Try_Send_Result :=
           Integer_Channels.Send_Closed;

         function Arm return Boolean is
         begin
            Flyology.Channel_Testing.Reset;
            Flyology.Channel_Testing.Arm_Before_Send;
            return True;
         end Arm;

         Armed : constant Boolean := Arm;
         pragma Unreferenced (Armed);

         task Sender;

         task body Sender is
         begin
            Integer_Channels.Try_Send (Channel, 11, Accepted'Access, Result);
         end Sender;

         Value  : Integer := 0;
         Status : Integer_Channels.Try_Receive_Result;
      begin
         Flyology.Channel_Testing.Wait_Before_Send;
         Passed := Passed and then not Accepted;
         abort Sender;
         Flyology.Channel_Testing.Release_Before_Send;
         while not Sender'Terminated loop
            delay 0.0;
         end loop;
         Channel.Try_Receive (Value, Status);
         Passed :=
           Passed
           and then not Accepted
           and then Status = Integer_Channels.Channel_Empty;
         Flyology.Channel_Testing.Reset;
      exception
         when others =>
            Flyology.Channel_Testing.Release_Before_Send;
            abort Sender;
            while not Sender'Terminated loop
               delay 0.0;
            end loop;
            Flyology.Channel_Testing.Reset;
            raise;
      end;

      --  Caller-aliased send evidence survives abort after the protected
      --  acceptance cut even though ordinary out copy-out never completes.
      declare
         Channel : aliased Integer_Channels.Channel (Capacity => 1);

         protected Barrier is
            procedure Arrive;
            entry Wait_Until_Arrived;
            entry Wait_For_Release;
            procedure Release;
         private
            Arrived  : Boolean := False;
            Released : Boolean := False;
         end Barrier;

         protected body Barrier is
            procedure Arrive is
            begin
               Arrived := True;
            end Arrive;

            entry Wait_Until_Arrived when Arrived is
            begin
               null;
            end Wait_Until_Arrived;

            entry Wait_For_Release when Released is
            begin
               null;
            end Wait_For_Release;

            procedure Release is
            begin
               Released := True;
            end Release;
         end Barrier;

         Accepted         : aliased Boolean := False;
         Published_Result : Integer_Channels.Try_Send_Result :=
           Integer_Channels.Send_Closed;

         procedure Send_Then_Publish
           (Result : out Integer_Channels.Try_Send_Result)
         is
            Local_Result : Integer_Channels.Try_Send_Result;
         begin
            Integer_Channels.Try_Send
              (Channel, 17, Accepted'Access, Local_Result);
            Barrier.Arrive;
            Barrier.Wait_For_Release;
            Result := Local_Result;
         end Send_Then_Publish;

         task Sender;

         task body Sender is
         begin
            Send_Then_Publish (Published_Result);
         end Sender;

         Value  : Integer := 0;
         Status : Integer_Channels.Try_Receive_Result;
      begin
         select
            Barrier.Wait_Until_Arrived;
         or
            delay 2.0;
            raise Program_Error
              with "channel acceptance barrier was not reached";
         end select;
         abort Sender;
         Barrier.Release;
         while not Sender'Terminated loop
            delay 0.0;
         end loop;
         Passed :=
           Passed
           and then Accepted
           and then Published_Result = Integer_Channels.Send_Closed;
         Channel.Try_Receive (Value, Status);
         Passed :=
           Passed
           and then Status = Integer_Channels.Item_Received
           and then Value = 17;
      exception
         when others =>
            Barrier.Release;
            abort Sender;
            while not Sender'Terminated loop
               delay 0.0;
            end loop;
            raise;
      end;

      --  Rejection always clears a stale caller token and retains no value.
      declare
         Channel  : Integer_Channels.Channel (Capacity => 1);
         Accepted : aliased Boolean := True;
         Status   : Integer_Channels.Try_Send_Result;
         Received : Integer_Channels.Try_Receive_Result;
         Value    : Integer := 0;
      begin
         Integer_Channels.Try_Send (Channel, 1, Accepted'Access, Status);
         Passed :=
           Passed
           and then Accepted
           and then Status = Integer_Channels.Item_Sent;
         Accepted := True;
         Integer_Channels.Try_Send (Channel, 2, Accepted'Access, Status);
         Passed :=
           Passed
           and then not Accepted
           and then Status = Integer_Channels.Channel_Full;
         Channel.Close;
         Accepted := True;
         Integer_Channels.Try_Send (Channel, 3, Accepted'Access, Status);
         Passed :=
           Passed
           and then not Accepted
           and then Status = Integer_Channels.Send_Closed;
         Channel.Try_Receive (Value, Received);
         Passed :=
           Passed
           and then Received = Integer_Channels.Item_Received
           and then Value = 1;
         Channel.Try_Receive (Value, Received);
         Passed := Passed and then Received = Integer_Channels.Receive_Closed;
      end;

      --  A familiar Receive overload composes with a timer through a success
      --  gate. Publishing after initiation but before the set wait exercises
      --  the atomic subscribe/recheck path rather than a helper task.
      declare
         Channel : aliased Integer_Channels.Channel (Capacity => 2);
         Set     : aliased Flyology.Operations.Completion_Set (3);
         Get     : aliased Integer_Channels.Receive_Operation :=
           Integer_Channels.Receive (Set'Access, Channel'Access, 1.0);
         Alarm   : aliased Flyology.IO.Timers.Timer_Operation :=
           Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
         Winner  : Flyology.Operations.Gate_Operation :=
           Flyology.Operations.Wait_For_Success
             (Set'Access, [Ref (Get), Ref (Alarm)]);
         Batch   : Flyology.Operations.Completion_Batch (Set.Capacity);
         Matches : Flyology.Operations.Completion_Batch (Set.Capacity);
         Status  : Integer_Channels.Try_Send_Result;
         Value   : Integer := 0;
      begin
         Channel.Try_Send (42, Status);
         Check
           (Status = Integer_Channels.Item_Sent,
            "channel test publication failed");
         while not Flyology.Operations.Is_Terminal (Winner) loop
            Flyology.Operations.Wait_Some (Set, Batch);
         end loop;
         Flyology.Operations.Finish (Winner, Matches);
         Integer_Channels.Finish (Get, Value);
         Passed :=
           Passed
           and then Value = 42
           and then Matches.Count = 1
           and then Natural (Matches.Ids (1)) = Flyology.Operations.Id (Get);
         Flyology.Operations.Cancel (Alarm);
         begin
            Flyology.IO.Timers.Finish (Alarm);
         exception
            when Flyology.Operations.Operation_Cancelled =>
               null;
         end;
      end;

      --  Two same-channel receivers are both first-class operations. Two
      --  commits cascade through one shared completion source and an All gate.
      declare
         Channel : aliased Integer_Channels.Channel (Capacity => 2);
         Set     : aliased Flyology.Operations.Completion_Set (3);
         Left    : aliased Integer_Channels.Receive_Operation :=
           Integer_Channels.Receive (Set'Access, Channel'Access, 1.0);
         Right   : aliased Integer_Channels.Receive_Operation :=
           Integer_Channels.Receive (Set'Access, Channel'Access, 1.0);
         Both    : Flyology.Operations.Gate_Operation :=
           Flyology.Operations.Wait_All
             (Set'Access, [Ref (Left), Ref (Right)]);
         Batch   : Flyology.Operations.Completion_Batch (Set.Capacity);
         Matches : Flyology.Operations.Completion_Batch (Set.Capacity);
         Status  : Integer_Channels.Try_Send_Result;
         A, B    : Integer := 0;
      begin
         Channel.Try_Send (1, Status);
         Check
           (Status = Integer_Channels.Item_Sent,
            "first fan-out publication failed");
         Channel.Try_Send (2, Status);
         Check
           (Status = Integer_Channels.Item_Sent,
            "second fan-out publication failed");
         while not Flyology.Operations.Is_Terminal (Both) loop
            Flyology.Operations.Wait_Some (Set, Batch);
         end loop;
         Flyology.Operations.Finish (Both, Matches);
         Integer_Channels.Finish (Left, A);
         Integer_Channels.Finish (Right, B);
         Passed :=
           Passed
           and then Matches.Count = 2
           and then ((A = 1 and then B = 2) or else (A = 2 and then B = 1));
      end;

      --  Many operations in one set exercise movement between the ready and
      --  notified lists. One source wake may drive all pending operations;
      --  each value must still be transferred exactly once.
      declare
         Channel : aliased Integer_Channels.Channel (Capacity => 24);
         Set     : aliased Flyology.Operations.Completion_Set (24);
         type Operation_Array is
           array (Positive range <>)
           of aliased Integer_Channels.Receive_Operation (Set'Access);
         Pending : Operation_Array (1 .. 24);
         Status  : Integer_Channels.Try_Send_Result;
         Seen    : array (1 .. 24) of Boolean := (others => False);
         Value   : Integer := 0;
      begin
         for Index in Pending'Range loop
            Integer_Channels.Receive (Channel'Access, 1.0, Pending (Index));
         end loop;
         for Index in Pending'Range loop
            Channel.Try_Send (Index, Status);
            Check
              (Status = Integer_Channels.Item_Sent,
               "many-subscriber publication failed");
         end loop;
         Flyology.Operations.Wait_All (Set);
         for Index in Pending'Range loop
            Integer_Channels.Finish (Pending (Index), Value);
            Check
              (Value in Seen'Range and then not Seen (Value),
               "many-subscriber delivery repeated");
            Seen (Value) := True;
         end loop;
         Passed := Passed and then (for all Delivered of Seen => Delivered);
      end;

      --  A synthetic interrupted write retries after the channel lock is
      --  released, then delivers the scoped completion notification.
      declare
         Channel : aliased Integer_Channels.Channel (Capacity => 1);
         Set     : aliased Flyology.Operations.Completion_Set (1);
         Get     : Integer_Channels.Receive_Operation :=
           Integer_Channels.Receive (Set'Access, Channel'Access, 5.0);
         Status  : Integer_Channels.Try_Send_Result;
         Value   : Integer := 0;
      begin
         Flyology.Channel_Testing.Reset;
         Flyology.Channel_Testing.Arm_Next_Bounded_Signal_Interrupt;
         Channel.Try_Send (47, Status);
         Flyology.Operations.Wait_All (Set);
         Integer_Channels.Finish (Get, Value);
         Passed :=
           Passed
           and then Status = Integer_Channels.Item_Sent
           and then Value = 47
           and then Flyology.Channel_Testing.Bounded_Signal_Interrupt_Observed;
         Flyology.Channel_Testing.Reset;
      end;

      --  A failed borrowed write stays local to its subscriber. The producer
      --  still reports its committed send and hands the item to a second set.
      declare
         Channel   : aliased Integer_Channels.Channel (Capacity => 1);
         Left_Set  : aliased Flyology.Operations.Completion_Set (1);
         Right_Set : aliased Flyology.Operations.Completion_Set (1);
         Left      : Integer_Channels.Receive_Operation :=
           Integer_Channels.Receive (Left_Set'Access, Channel'Access, 5.0);
         Right     : Integer_Channels.Receive_Operation :=
           Integer_Channels.Receive (Right_Set'Access, Channel'Access, 5.0);
         Status    : Integer_Channels.Try_Send_Result;
         Value     : Integer := 0;
         Delivered : Boolean := False;
         Cancelled : Boolean := False;
      begin
         Flyology.Channel_Testing.Reset;
         Flyology.Channel_Testing.Arm_Next_Bounded_Signal_Failure;
         Channel.Try_Send (67, Status);
         Flyology.Operations.Wait_All (Right_Set);
         Integer_Channels.Finish (Right, Value);
         Delivered := Value = 67;
         Flyology.Operations.Cancel (Left);
         begin
            Integer_Channels.Finish (Left, Value);
         exception
            when Integer_Channels.Operation_Cancelled =>
               Cancelled := True;
         end;
         Passed :=
           Passed
           and then Status = Integer_Channels.Item_Sent
           and then Delivered
           and then Cancelled
           and then Flyology.Channel_Testing.Bounded_Signal_Failure_Observed;
         Flyology.Channel_Testing.Reset;
      end;

      --  An abort after a failed write is acknowledged must preserve the
      --  pending handoff to a second valid completion set.
      declare
         Channel   : aliased Integer_Channels.Channel (Capacity => 1);
         Left_Set  : aliased Flyology.Operations.Completion_Set (1);
         Right_Set : aliased Flyology.Operations.Completion_Set (1);
         Left      : Integer_Channels.Receive_Operation :=
           Integer_Channels.Receive (Left_Set'Access, Channel'Access, 5.0);
         Right     : Integer_Channels.Receive_Operation :=
           Integer_Channels.Receive (Right_Set'Access, Channel'Access, 5.0);
         Value     : Integer := 0;
         Delivered : Boolean := False;
         Cancelled : Boolean := False;

         task Sender is
            entry Go;
         end Sender;

         task body Sender is
            Status : Integer_Channels.Try_Send_Result;
         begin
            accept Go;
            Channel.Try_Send (71, Status);
         end Sender;
      begin
         Flyology.Channel_Testing.Reset;
         Flyology.Channel_Testing.Arm_Next_Bounded_Signal_Failure;
         Flyology.Channel_Testing.Arm_After_Bounded_Failure_Ack;
         Sender.Go;
         Flyology.Channel_Testing.Wait_After_Bounded_Failure_Ack;
         abort Sender;
         while not Sender'Terminated loop
            delay 0.0;
         end loop;
         Flyology.Operations.Wait_All (Right_Set);
         Integer_Channels.Finish (Right, Value);
         Delivered := Value = 71;
         Flyology.Operations.Cancel (Left);
         begin
            Integer_Channels.Finish (Left, Value);
         exception
            when Integer_Channels.Operation_Cancelled =>
               Cancelled := True;
         end;
         Passed :=
           Passed
           and then Delivered
           and then Cancelled
           and then Flyology.Channel_Testing.Bounded_Signal_Failure_Observed;
         Flyology.Channel_Testing.Reset;
      end;

      --  A producer aborted after the protected commit still flushes its
      --  caller-owned claim before the pending operation can be reclaimed.
      declare
         Channel : aliased Integer_Channels.Channel (Capacity => 1);
         Set     : aliased Flyology.Operations.Completion_Set (1);
         Get     : Integer_Channels.Receive_Operation :=
           Integer_Channels.Receive (Set'Access, Channel'Access, 5.0);
         Value   : Integer := 0;
         Status  : Integer_Channels.Try_Send_Result;

         function Arm return Boolean is
         begin
            Flyology.Channel_Testing.Reset;
            Flyology.Channel_Testing.Arm_After_Signal_Claim;
            return True;
         end Arm;

         Armed : constant Boolean := Arm;
         pragma Unreferenced (Armed);

         task Sender;

         task body Sender is
         begin
            Channel.Try_Send (73, Status);
         end Sender;
      begin
         Flyology.Channel_Testing.Wait_After_Signal_Claim;
         abort Sender;
         while not Sender'Terminated loop
            delay 0.0;
         end loop;
         Flyology.Operations.Wait_All (Set);
         Integer_Channels.Finish (Get, Value);
         Passed := Passed and then Value = 73;
         Flyology.Channel_Testing.Reset;
      end;

      --  Cancellation may unlink an in-flight node, but it cannot reclaim
      --  the operation or its borrowed descriptor until the producer acks.
      declare
         Channel         : aliased Integer_Channels.Channel (Capacity => 1);
         Set             : aliased Flyology.Operations.Completion_Set (1);
         Get             : Integer_Channels.Receive_Operation :=
           Integer_Channels.Receive (Set'Access, Channel'Access, 5.0);
         Status          : Integer_Channels.Try_Send_Result;
         Received        : Integer_Channels.Try_Receive_Result;
         Value           : Integer := 0;
         Cancelled       : Boolean := False;
         Cancel_Returned : Boolean := False
         with Atomic;
         Wait_Observed   : Boolean := False
         with Atomic;

         task Sender is
            entry Go;
         end Sender;

         task body Sender is
         begin
            accept Go;
            Channel.Try_Send (51, Status);
         end Sender;

         task Releaser is
            entry Go;
         end Releaser;

         task body Releaser is
         begin
            accept Go;
            delay 0.02;
            Wait_Observed := not Cancel_Returned;
            Flyology.Channel_Testing.Release_After_Signal_Claim;
         end Releaser;
      begin
         Flyology.Channel_Testing.Reset;
         Flyology.Channel_Testing.Arm_After_Signal_Claim;
         Sender.Go;
         Flyology.Channel_Testing.Wait_After_Signal_Claim;
         Releaser.Go;
         Flyology.Operations.Cancel (Get);
         Cancel_Returned := True;
         while not Sender'Terminated or else not Releaser'Terminated loop
            delay 0.0;
         end loop;
         begin
            Integer_Channels.Finish (Get, Value);
         exception
            when Integer_Channels.Operation_Cancelled =>
               Cancelled := True;
         end;
         Channel.Try_Receive (Value, Received);
         Passed :=
           Passed
           and then Wait_Observed
           and then Cancelled
           and then Status = Integer_Channels.Item_Sent
           and then Received = Integer_Channels.Item_Received
           and then Value = 51;
         Flyology.Channel_Testing.Reset;
      end;

      --  An aborted closer must flush every terminal claim, including the
      --  ones selected after the first post-lock signal.
      declare
         Channel : aliased Integer_Channels.Channel (Capacity => 1);
         Set     : aliased Flyology.Operations.Completion_Set (8);
         type Operation_Array is
           array (Positive range <>)
           of aliased Integer_Channels.Receive_Operation (Set'Access);
         Pending : Operation_Array (1 .. 8);
         Value   : Integer := 0;
         Closed  : Natural := 0;

         task Closer is
            entry Go;
         end Closer;

         task body Closer is
         begin
            accept Go;
            Channel.Close;
         end Closer;
      begin
         for Index in Pending'Range loop
            Integer_Channels.Receive (Channel'Access, 5.0, Pending (Index));
         end loop;
         Flyology.Channel_Testing.Reset;
         Flyology.Channel_Testing.Arm_After_Signal_Claim;
         Closer.Go;
         Flyology.Channel_Testing.Wait_After_Signal_Claim;
         abort Closer;
         while not Closer'Terminated loop
            delay 0.0;
         end loop;
         Flyology.Operations.Wait_All (Set);
         for Index in Pending'Range loop
            begin
               Integer_Channels.Finish (Pending (Index), Value);
            exception
               when Integer_Channels.Channel_Closed =>
                  Closed := Closed + 1;
            end;
         end loop;
         Passed := Passed and then Closed = Pending'Length;
         Flyology.Channel_Testing.Reset;
      end;

      --  Separate completion sets need separate notifications. Each send
      --  claims a different waiting receiver even before any owner waits.
      declare
         Channel                          :
           aliased Integer_Channels.Channel (Capacity => 3);
         First_Set, Second_Set, Third_Set :
           aliased Flyology.Operations.Completion_Set (1);
         First                            :
           Integer_Channels.Receive_Operation :=
             Integer_Channels.Receive (First_Set'Access, Channel'Access, 1.0);
         Second                           :
           Integer_Channels.Receive_Operation :=
             Integer_Channels.Receive (Second_Set'Access, Channel'Access, 1.0);
         Third                            :
           Integer_Channels.Receive_Operation :=
             Integer_Channels.Receive (Third_Set'Access, Channel'Access, 1.0);
         Status                           : Integer_Channels.Try_Send_Result;
         A, B, C                          : Integer := 0;
      begin
         for Number in 1 .. 3 loop
            Channel.Try_Send (Number, Status);
            Check
              (Status = Integer_Channels.Item_Sent,
               "fan-out publication failed");
         end loop;
         Flyology.Operations.Wait_All (First_Set);
         Flyology.Operations.Wait_All (Second_Set);
         Flyology.Operations.Wait_All (Third_Set);
         Integer_Channels.Finish (First, A);
         Integer_Channels.Finish (Second, B);
         Integer_Channels.Finish (Third, C);
         Passed := Passed and then A + B + C = 6 and then A * B * C = 6;
      end;

      --  Cancellation of a signalled receiver passes its outstanding wake
      --  claim to another pending receiver for the already buffered item.
      declare
         Channel               :
           aliased Integer_Channels.Channel (Capacity => 1);
         First_Set, Second_Set :
           aliased Flyology.Operations.Completion_Set (1);
         First                 : Integer_Channels.Receive_Operation :=
           Integer_Channels.Receive (First_Set'Access, Channel'Access, 1.0);
         Second                : Integer_Channels.Receive_Operation :=
           Integer_Channels.Receive (Second_Set'Access, Channel'Access, 1.0);
         Status                : Integer_Channels.Try_Send_Result;
         Value                 : Integer := 0;
      begin
         Channel.Try_Send (27, Status);
         Check
           (Status = Integer_Channels.Item_Sent, "handoff publication failed");
         Flyology.Operations.Cancel (Second);
         begin
            Integer_Channels.Finish (Second, Value);
            Passed := False;
         exception
            when Integer_Channels.Operation_Cancelled =>
               null;
         end;
         Flyology.Operations.Wait_All (First_Set);
         Integer_Channels.Finish (First, Value);
         Passed := Passed and then Value = 27;
      end;

      --  Removing a notified node from the middle of a longer queue keeps
      --  both neighboring links intact and hands its claim to a ready waiter.
      declare
         Channel                                      :
           aliased Integer_Channels.Channel (Capacity => 3);
         First_Set, Second_Set, Third_Set, Fourth_Set :
           aliased Flyology.Operations.Completion_Set (1);
         First                                        :
           Integer_Channels.Receive_Operation :=
             Integer_Channels.Receive (First_Set'Access, Channel'Access, 1.0);
         Second                                       :
           Integer_Channels.Receive_Operation :=
             Integer_Channels.Receive (Second_Set'Access, Channel'Access, 1.0);
         Third                                        :
           Integer_Channels.Receive_Operation :=
             Integer_Channels.Receive (Third_Set'Access, Channel'Access, 1.0);
         Fourth                                       :
           Integer_Channels.Receive_Operation :=
             Integer_Channels.Receive (Fourth_Set'Access, Channel'Access, 1.0);
         Status                                       :
           Integer_Channels.Try_Send_Result;
         Seen                                         :
           array (1 .. 3) of Boolean := (others => False);
         Value                                        : Integer := 0;
      begin
         for Number in Seen'Range loop
            Channel.Try_Send (Number, Status);
            Check
              (Status = Integer_Channels.Item_Sent,
               "middle-unlink publication failed");
         end loop;
         Flyology.Operations.Cancel (Second);
         begin
            Integer_Channels.Finish (Second, Value);
            Passed := False;
         exception
            when Integer_Channels.Operation_Cancelled =>
               null;
         end;
         Flyology.Operations.Wait_All (First_Set);
         Flyology.Operations.Wait_All (Third_Set);
         Flyology.Operations.Wait_All (Fourth_Set);
         Integer_Channels.Finish (First, Value);
         Check
           (Value in Seen'Range and then not Seen (Value),
            "first middle-unlink delivery repeated");
         Seen (Value) := True;
         Integer_Channels.Finish (Third, Value);
         Check
           (Value in Seen'Range and then not Seen (Value),
            "third middle-unlink delivery repeated");
         Seen (Value) := True;
         Integer_Channels.Finish (Fourth, Value);
         Check
           (Value in Seen'Range and then not Seen (Value),
            "fourth middle-unlink delivery repeated");
         Seen (Value) := True;
         Passed := Passed and then (for all Delivered of Seen => Delivered);
      end;

      --  A full channel retains a pending send. Receiving capacity wakes it;
      --  Finish consumes the operation but the channel keeps FIFO ownership.
      declare
         Channel        : aliased Integer_Channels.Channel (Capacity => 1);
         Set            : aliased Flyology.Operations.Completion_Set (1);
         Status         : Integer_Channels.Try_Send_Result;
         Receive_Status : Integer_Channels.Try_Receive_Result;
         Value          : Integer := 0;
      begin
         Channel.Try_Send (7, Status);
         Check (Status = Integer_Channels.Item_Sent, "channel preload failed");
         declare
            Put : Integer_Channels.Send_Operation :=
              Integer_Channels.Send (Set'Access, Channel'Access, 8, 1.0);
         begin
            Channel.Try_Receive (Value, Receive_Status);
            Check
              (Receive_Status = Integer_Channels.Item_Received
               and then Value = 7,
               "channel capacity release failed");
            Flyology.Operations.Wait_All (Set);
            Integer_Channels.Finish (Put);
         end;
         Channel.Try_Receive (Value, Receive_Status);
         Passed :=
           Passed
           and then Receive_Status = Integer_Channels.Item_Received
           and then Value = 8;
      end;

      --  Timeout and close are retained provider failures. The set wait does
      --  not raise them; typed Finish reconstructs the synchronous exception.
      declare
         Channel               :
           aliased Integer_Channels.Channel (Capacity => 1);
         Set                   :
           aliased Flyology.Operations.Completion_Set (2);
         Timed                 : Integer_Channels.Receive_Operation :=
           Integer_Channels.Receive (Set'Access, Channel'Access, 0.005);
         Closed                :
           Integer_Channels.Receive_Operation (Set'Access);
         Timed_Out, Was_Closed : Boolean := False;
         Value                 : Integer := 0;
      begin
         Flyology.Operations.Wait_All (Set);
         begin
            Integer_Channels.Finish (Timed, Value);
         exception
            when Integer_Channels.Timeout_Error =>
               Timed_Out := True;
         end;
         Integer_Channels.Receive (Channel'Access, 1.0, Closed);
         Channel.Close;
         Flyology.Operations.Wait_All (Set);
         begin
            Integer_Channels.Finish (Closed, Value);
         exception
            when Integer_Channels.Channel_Closed =>
               Was_Closed := True;
         end;
         Passed := Passed and then Timed_Out and then Was_Closed;
      end;

      --  Close also terminalizes a send waiting for capacity. A terminal gate
      --  succeeds because it counts the provider failure as a terminal result;
      --  typed Finish alone raises Channel_Closed.
      declare
         Channel    : aliased Integer_Channels.Channel (Capacity => 1);
         Set        : aliased Flyology.Operations.Completion_Set (2);
         Status     : Integer_Channels.Try_Send_Result;
         Was_Closed : Boolean := False;
      begin
         Channel.Try_Send (10, Status);
         Check
           (Status = Integer_Channels.Item_Sent, "close-send preload failed");
         declare
            Put      : aliased Integer_Channels.Send_Operation :=
              Integer_Channels.Send (Set'Access, Channel'Access, 11, 1.0);
            Terminal : Flyology.Operations.Gate_Operation :=
              Flyology.Operations.Wait_All (Set'Access, [Ref (Put)]);
            Batch    : Flyology.Operations.Completion_Batch (Set.Capacity);
            Matches  : Flyology.Operations.Completion_Batch (Set.Capacity);
         begin
            Channel.Close;
            while not Flyology.Operations.Is_Terminal (Terminal) loop
               Flyology.Operations.Wait_Some (Set, Batch);
            end loop;
            Flyology.Operations.Finish (Terminal, Matches);
            begin
               Integer_Channels.Finish (Put);
            exception
               when Integer_Channels.Channel_Closed =>
                  Was_Closed := True;
            end;
            Passed := Passed and then Matches.Count = 1 and then Was_Closed;
         end;
      end;

      --  Cancellation unlinks before terminal publication, and a scoped
      --  pending object's finalizer does the same. Capacity-one reuse plus a
      --  later channel state change catches stale intrusive links.
      declare
         Channel   : aliased Integer_Channels.Channel (Capacity => 1);
         Set       : aliased Flyology.Operations.Completion_Set (1);
         Cancelled : Boolean := False;
         Value     : Integer := 0;
         Status    : Integer_Channels.Try_Send_Result;
      begin
         declare
            Get : Integer_Channels.Receive_Operation :=
              Integer_Channels.Receive (Set'Access, Channel'Access);
         begin
            Flyology.Operations.Cancel (Get);
            begin
               Integer_Channels.Finish (Get, Value);
            exception
               when Flyology.Operations.Operation_Cancelled =>
                  Cancelled := True;
            end;
         end;
         declare
            Abandoned : Integer_Channels.Receive_Operation :=
              Integer_Channels.Receive (Set'Access, Channel'Access);
            pragma Unreferenced (Abandoned);
         begin
            null;
         end;
         Channel.Try_Send (9, Status);
         Check
           (Status = Integer_Channels.Item_Sent,
            "channel stale-subscription publication failed");
         declare
            Get : Integer_Channels.Receive_Operation :=
              Integer_Channels.Receive (Set'Access, Channel'Access, 0.0);
         begin
            Flyology.Operations.Wait_All (Set);
            Integer_Channels.Finish (Get, Value);
         end;
         Passed := Passed and then Cancelled and then Value = 9;
      end;

      Check (Passed, "channel operation matrix failed");
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
end Channel_Operations_Smoke;
