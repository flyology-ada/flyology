with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Text_IO;
with Flyology;
with Flyology.Buffers;
with Flyology.IO;
with Flyology.IO.Files;
with Flyology.IO.Sockets;
with Flyology.IO.Timers;
with Flyology.Operations;

procedure Operations_Smoke is
   --  Executable overload matrix. Each row is exercised through the named
   --  first-class gate and its provider-specific Finish operation.
   --
   --  Provider overload                         Gate                    Lanes
   --  Flyology.IO.Wait                          Wait_Some (2)           both
   --  Timers.Sleep_For                          nested Some/Success/All both
   --  Timers.Sleep_Until                        nested Some/Success/All both
   --  Sockets.Receive (array)                   Successes (2)           both
   --  Sockets.Receive_Exactly (array)           All                     both
   --  Sockets.Send (array)                      Success                 both
   --  Sockets.Send_All (array)                  All                     both
   --  Sockets.Receive (Unique_Buffer)           All                     both
   --  Sockets.Send (Unique_Buffer)              All                     both
   --  Sockets.Send_All (Unique_Buffer)          All                     both
   --  Files.Read_At (array)                     All                     lightweight
   --  Files.Write_At (array)                    Successes (2)           lightweight
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Array;
   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Real_Time.Time;
   use type Flyology.Execution_Model;
   use type Flyology.Operations.Terminal_Outcome;

   protected Result is
      procedure Set (Passed : Boolean);
      entry Wait (Passed : out Boolean);
   private
      Done : Boolean := False;
      OK   : Boolean := False;
   end Result;

   protected body Result is
      procedure Set (Passed : Boolean) is
      begin
         OK := Passed;
         Done := True;
      end Set;

      entry Wait (Passed : out Boolean) when Done is
      begin
         Passed := OK;
         Done := False;
      end Wait;
   end Result;

   function Contains
     (Batch : Flyology.Operations.Completion_Batch;
      Id    : Natural) return Boolean
   is
   begin
      for Position in 1 .. Batch.Count loop
         if Natural (Batch.Ids (Position)) = Id then
            return True;
         end if;
      end loop;
      return False;
   end Contains;

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

   task type Runner (Model : Flyology.Execution_Model) is
      pragma Task_Info (Model);
   end Runner;

   task body Runner is
      Left_1, Right_1 : aliased Flyology.IO.Sockets.Socket_Type;
      Left_2, Right_2 : aliased Flyology.IO.Sockets.Socket_Type;
      Data : constant Ada.Streams.Stream_Element_Array := [1 => 42];
      Last : Ada.Streams.Stream_Element_Offset;
      Passed : Boolean := True;
   begin
      Flyology.IO.Sockets.Create_Socket_Pair (Left_1, Right_1);
      Flyology.IO.Sockets.Create_Socket_Pair (Left_2, Right_2);
      Flyology.IO.Sockets.Prepare (Left_1);
      Flyology.IO.Sockets.Prepare (Left_2);

      declare
         Set : aliased Flyology.Operations.Completion_Set (4);
         Ready_1 : aliased Flyology.IO.Readiness_Operation :=
           Flyology.IO.Wait
             (Set'Access,
              Flyology.IO.Sockets.Native_Descriptor (Left_1),
              Flyology.IO.For_Read);
         Ready_2 : aliased Flyology.IO.Readiness_Operation :=
           Flyology.IO.Wait
             (Set'Access,
              Flyology.IO.Sockets.Native_Descriptor (Left_2),
              Flyology.IO.For_Read);
         Alarm : aliased Flyology.IO.Timers.Timer_Operation :=
           Flyology.IO.Timers.Sleep_For (Set'Access, 0.05);
         Ready_Gate : Flyology.Operations.Gate_Operation :=
           Flyology.Operations.Wait_Some
             (Set'Access,
              [Ref (Ready_1), Ref (Ready_2), Ref (Alarm)],
              Required => 2);
         Batch : Flyology.Operations.Completion_Batch (Set.Capacity);
         Gate_Matches :
           Flyology.Operations.Completion_Batch (Set.Capacity);
      begin
         Flyology.IO.Sockets.Send_Socket (Right_2, Data, Last);
         Flyology.IO.Sockets.Send_Socket (Right_1, Data, Last);

         while not Flyology.Operations.Is_Terminal (Ready_Gate) loop
            Flyology.Operations.Wait_Some (Set, Batch);
         end loop;
         Flyology.Operations.Finish (Ready_Gate, Gate_Matches);
         Passed := Gate_Matches.Count = 2
           and then Contains (Gate_Matches, Flyology.Operations.Id (Ready_1))
           and then Contains (Gate_Matches, Flyology.Operations.Id (Ready_2));
         Flyology.IO.Finish (Ready_1);
         Flyology.IO.Finish (Ready_2);

         Flyology.Operations.Wait_Some (Set, Batch);
         Passed := Passed
           and then Batch.Count = 1
           and then Contains (Batch, Flyology.Operations.Id (Alarm));
         Flyology.IO.Timers.Finish (Alarm);

         Flyology.IO.Wait
           (Flyology.IO.Sockets.Native_Descriptor (Left_1),
            Flyology.IO.For_Read,
            Ready_1);
         Flyology.IO.Timers.Sleep_For (0.0, Alarm);
         Flyology.Operations.Cancel (Ready_1);
         Flyology.Operations.Wait_All (Set);
         Passed := Passed
           and then Flyology.Operations.Terminal_Count (Set) = 2;
         Flyology.IO.Timers.Finish (Alarm);
         declare
            Cancelled : Boolean := False;
         begin
            begin
               Flyology.IO.Finish (Ready_1);
            exception
               when Flyology.Operations.Operation_Cancelled =>
                  Cancelled := True;
            end;
            Passed := Passed and Cancelled;
         end;

         Flyology.IO.Wait
           (Flyology.IO.Sockets.Native_Descriptor (Left_1),
            Flyology.IO.For_Read,
            Ready_1);
         Flyology.IO.Wait
           (Flyology.IO.Sockets.Native_Descriptor (Left_2),
            Flyology.IO.For_Read,
            Ready_2);
         Flyology.IO.Timers.Sleep_Until
           (Ada.Real_Time.Clock + Ada.Real_Time.Seconds (1), Alarm);
         Flyology.Operations.Cancel (Alarm);
         Flyology.Operations.Wait_For_Successes (Set, 2, Batch);
         Passed := Passed
           and then Batch.Count = 3
           and then Contains (Batch, Flyology.Operations.Id (Ready_1))
           and then Contains (Batch, Flyology.Operations.Id (Ready_2))
           and then Contains (Batch, Flyology.Operations.Id (Alarm));
         Flyology.IO.Finish (Ready_1);
         Flyology.IO.Finish (Ready_2);
         declare
            Cancelled : Boolean := False;
         begin
            begin
               Flyology.IO.Timers.Finish (Alarm);
            exception
               when Flyology.Operations.Operation_Cancelled =>
                  Cancelled := True;
            end;
            Passed := Passed and Cancelled;
         end;
      end;
      Check (Passed, "descriptor operation gate matrix failed");

      --  Writable readiness uses the other poller direction. Repeated
      --  readiness observations on one descriptor are fanned out and become
      --  one stable gate snapshot without consuming the stream.
      declare
         Set : aliased Flyology.Operations.Completion_Set (2);
         Writable : aliased Flyology.IO.Readiness_Operation :=
           Flyology.IO.Wait
             (Set'Access,
              Flyology.IO.Sockets.Native_Descriptor (Right_1),
              Flyology.IO.For_Write);
         Ready : Flyology.Operations.Gate_Operation :=
           Flyology.Operations.Wait_All (Set'Access, [Ref (Writable)]);
         Batch : Flyology.Operations.Completion_Batch (Set.Capacity);
         Matches : Flyology.Operations.Completion_Batch (Set.Capacity);
      begin
         while not Flyology.Operations.Is_Terminal (Ready) loop
            Flyology.Operations.Wait_Some (Set, Batch);
         end loop;
         Flyology.Operations.Finish (Ready, Matches);
         Passed := Passed and then Matches.Count = 1;
         Flyology.IO.Finish (Writable);
      end;

      declare
         Set : aliased Flyology.Operations.Completion_Set (3);
         Ready_1 : aliased Flyology.IO.Readiness_Operation :=
           Flyology.IO.Wait
             (Set'Access,
              Flyology.IO.Sockets.Native_Descriptor (Left_1),
              Flyology.IO.For_Read);
         Ready_2 : aliased Flyology.IO.Readiness_Operation :=
           Flyology.IO.Wait
             (Set'Access,
              Flyology.IO.Sockets.Native_Descriptor (Left_1),
              Flyology.IO.For_Read);
         Both : Flyology.Operations.Gate_Operation :=
           Flyology.Operations.Wait_All
             (Set'Access, [Ref (Ready_1), Ref (Ready_2)]);
         Batch : Flyology.Operations.Completion_Batch (Set.Capacity);
         Matches : Flyology.Operations.Completion_Batch (Set.Capacity);
         Consumed : Ada.Streams.Stream_Element_Array := [1 => 0];
         Consumed_Last : Ada.Streams.Stream_Element_Offset;
      begin
         Flyology.IO.Sockets.Send_Socket (Right_1, Data, Last);
         while not Flyology.Operations.Is_Terminal (Both) loop
            Flyology.Operations.Wait_Some (Set, Batch);
         end loop;
         Flyology.Operations.Finish (Both, Matches);
         Passed := Passed and then Matches.Count = 2;
         Flyology.IO.Finish (Ready_1);
         Flyology.IO.Finish (Ready_2);
         Flyology.IO.Sockets.Receive_Socket
           (Left_1, Consumed, Consumed_Last);
         Passed := Passed
           and then Consumed_Last = Consumed'Last
           and then Consumed (Consumed'First) = 42;
      end;
      Check (Passed, "descriptor write/fan-out gates failed");

      --  Failure after reserving a slot rolls the partial operation back. A
      --  valid operation and gate can immediately reuse the bounded capacity.
      declare
         Set : aliased Flyology.Operations.Completion_Set (2);
         Rejected : Boolean := False;
      begin
         begin
            declare
               Invalid : Flyology.IO.Readiness_Operation :=
                 Flyology.IO.Wait
                   (Set'Access,
                    Flyology.IO.Invalid_Descriptor,
                    Flyology.IO.For_Read);
               pragma Unreferenced (Invalid);
            begin
               null;
            end;
         exception
            when Flyology.Operations.Operation_Error =>
               Rejected := True;
         end;
         declare
            Valid : aliased Flyology.IO.Readiness_Operation :=
              Flyology.IO.Wait
                (Set'Access,
                 Flyology.IO.Sockets.Native_Descriptor (Right_1),
                 Flyology.IO.For_Write);
            Done : Flyology.Operations.Gate_Operation :=
              Flyology.Operations.Wait_All (Set'Access, [Ref (Valid)]);
            Batch : Flyology.Operations.Completion_Batch (Set.Capacity);
            Matches :
              Flyology.Operations.Completion_Batch (Set.Capacity);
         begin
            while not Flyology.Operations.Is_Terminal (Done) loop
               Flyology.Operations.Wait_Some (Set, Batch);
            end loop;
            Flyology.Operations.Finish (Done, Matches);
            Flyology.IO.Finish (Valid);
            Passed := Passed
              and then Rejected
              and then Matches.Count = 1;
         end;
      end;
      Check (Passed, "readiness initiation rollback failed");

      --  A failed Rearm is transactional: it leaves the consumed operation
      --  idle so the same capacity-one slot and operation can be reused.
      declare
         Set : aliased Flyology.Operations.Completion_Set (1);
         Ready : Flyology.IO.Readiness_Operation :=
           Flyology.IO.Wait
             (Set'Access,
              Flyology.IO.Sockets.Native_Descriptor (Right_1),
              Flyology.IO.For_Write);
         Batch : Flyology.Operations.Completion_Batch (Set.Capacity);
         Rejected : Boolean := False;
      begin
         Flyology.Operations.Wait_Some (Set, Batch);
         Flyology.IO.Finish (Ready);
         begin
            Flyology.IO.Rearm
              (Flyology.IO.Invalid_Descriptor,
               Flyology.IO.For_Read,
               Ready);
         exception
            when Flyology.Operations.Operation_Error =>
               Rejected := True;
         end;
         Passed := Passed
           and then Rejected
           and then not Flyology.Operations.Is_Active (Ready)
           and then not Flyology.Operations.Is_Terminal (Ready);
         Flyology.IO.Rearm
           (Flyology.IO.Sockets.Native_Descriptor (Right_1),
            Flyology.IO.For_Write,
            Ready);
         Flyology.Operations.Wait_Some (Set, Batch);
         Flyology.IO.Finish (Ready);
      end;
      Check (Passed, "readiness Rearm rollback failed");

      --  First-class gates use the same operation lifecycle and can depend on
      --  provider operations or earlier gates. Both immediate timers expire
      --  in one scheduler batch, so every composed gate observes the same cut.
      declare
         Set : aliased Flyology.Operations.Completion_Set (6);
         Fast_1 : aliased Flyology.IO.Timers.Timer_Operation :=
           Flyology.IO.Timers.Sleep_For (Set'Access, 0.0);
         Fast_2 : aliased Flyology.IO.Timers.Timer_Operation :=
           Flyology.IO.Timers.Sleep_Until
             (Set'Access, Ada.Real_Time.Clock);
         Slow : aliased Flyology.IO.Timers.Timer_Operation :=
           Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
         Two_Ready : aliased Flyology.Operations.Gate_Operation :=
           Flyology.Operations.Wait_Some
             (Set'Access,
              [Ref (Fast_1), Ref (Fast_2), Ref (Slow)],
              Required => 2);
         First_Success : aliased Flyology.Operations.Gate_Operation :=
           Flyology.Operations.Wait_For_Success
             (Set'Access, [Ref (Two_Ready), Ref (Slow)]);
         Joined : Flyology.Operations.Gate_Operation :=
           Flyology.Operations.Wait_All
             (Set'Access, [Ref (Two_Ready), Ref (First_Success)]);
         Batch : Flyology.Operations.Completion_Batch (Set.Capacity);
         Some_Matches : Flyology.Operations.Completion_Batch (Set.Capacity);
         Success_Matches :
           Flyology.Operations.Completion_Batch (Set.Capacity);
         Join_Matches : Flyology.Operations.Completion_Batch (Set.Capacity);
      begin
         while not Flyology.Operations.Is_Terminal (Joined) loop
            Flyology.Operations.Wait_Some (Set, Batch);
         end loop;
         Passed := Passed
           and then Flyology.Operations.Outcome (Two_Ready) =
             Flyology.Operations.Succeeded
           and then Flyology.Operations.Outcome (First_Success) =
             Flyology.Operations.Succeeded
           and then Flyology.Operations.Outcome (Joined) =
             Flyology.Operations.Succeeded;

         Flyology.Operations.Finish (Joined, Join_Matches);
         Flyology.Operations.Finish
           (First_Success, Success_Matches);
         Flyology.Operations.Finish (Two_Ready, Some_Matches);
         Passed := Passed
           and then Join_Matches.Count = 2
           and then Contains
             (Join_Matches, Flyology.Operations.Id (Two_Ready))
           and then Contains
             (Join_Matches, Flyology.Operations.Id (First_Success))
           and then Success_Matches.Count = 1
           and then Contains
             (Success_Matches, Flyology.Operations.Id (Two_Ready))
           and then Some_Matches.Count = 2
           and then Contains
             (Some_Matches, Flyology.Operations.Id (Fast_1))
           and then Contains
             (Some_Matches, Flyology.Operations.Id (Fast_2));

         Flyology.IO.Timers.Finish (Fast_1);
         Flyology.IO.Timers.Finish (Fast_2);
         Flyology.Operations.Cancel (Slow);
         begin
            Flyology.IO.Timers.Finish (Slow);
         exception
            when Flyology.Operations.Operation_Cancelled =>
               null;
         end;
      end;
      Check (Passed, "nested timer gate composition failed");

      --  Exercise the absolute-timer overload with a genuinely future
      --  deadline rather than only its already-due branch.
      declare
         Set : aliased Flyology.Operations.Completion_Set (2);
         Alarm : aliased Flyology.IO.Timers.Timer_Operation :=
           Flyology.IO.Timers.Sleep_Until
             (Set'Access,
              Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (0.005));
         Done : Flyology.Operations.Gate_Operation :=
           Flyology.Operations.Wait_All (Set'Access, [Ref (Alarm)]);
         Batch : Flyology.Operations.Completion_Batch (Set.Capacity);
         Matches : Flyology.Operations.Completion_Batch (Set.Capacity);
      begin
         while not Flyology.Operations.Is_Terminal (Done) loop
            Flyology.Operations.Wait_Some (Set, Batch);
         end loop;
         Flyology.Operations.Finish (Done, Matches);
         Flyology.IO.Timers.Finish (Alarm);
         Passed := Passed and then Matches.Count = 1;
      end;
      Check (Passed, "future absolute timer gate failed");

      --  A success gate fails at the first snapshot where its threshold is
      --  impossible; it need not wait for unrelated remaining members.
      declare
         Set : aliased Flyology.Operations.Completion_Set (4);
         Candidate_1 : aliased Flyology.IO.Timers.Timer_Operation :=
           Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
         Candidate_2 : aliased Flyology.IO.Timers.Timer_Operation :=
           Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
         Quorum : Flyology.Operations.Gate_Operation :=
           Flyology.Operations.Wait_For_Successes
             (Set'Access,
              [Ref (Candidate_1), Ref (Candidate_2)],
              Required => 2);
         Matches : Flyology.Operations.Completion_Batch (Set.Capacity);
      begin
         Flyology.Operations.Cancel (Candidate_1);
         Passed := Passed
           and then Flyology.Operations.Is_Terminal (Quorum)
           and then Flyology.Operations.Outcome (Quorum) =
             Flyology.Operations.Failed;
         Flyology.Operations.Finish (Quorum, Matches);
         Passed := Passed
           and then Matches.Count = 1
           and then Contains
             (Matches, Flyology.Operations.Id (Candidate_1))
           and then Flyology.Operations.Is_Active (Candidate_2);

         Flyology.Operations.Cancel (Candidate_2);
         begin
            Flyology.IO.Timers.Finish (Candidate_1);
         exception
            when Flyology.Operations.Operation_Cancelled =>
               null;
         end;
         begin
            Flyology.IO.Timers.Finish (Candidate_2);
         exception
            when Flyology.Operations.Operation_Cancelled =>
               null;
         end;
      end;
      Check (Passed, "impossible success gate failed");

      --  Gate cancellation detaches only the observer. Its child remains a
      --  normal active operation and may be cancelled or completed separately.
      declare
         Set : aliased Flyology.Operations.Completion_Set (4);
         Child : aliased Flyology.IO.Timers.Timer_Operation :=
           Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
         Gate : Flyology.Operations.Gate_Operation :=
           Flyology.Operations.Wait_All (Set'Access, [Ref (Child)]);
         Matches : Flyology.Operations.Completion_Batch (Set.Capacity);
         Gate_Cancelled : Boolean := False;
      begin
         Flyology.Operations.Cancel (Gate);
         begin
            Flyology.Operations.Finish (Gate, Matches);
         exception
            when Flyology.Operations.Operation_Cancelled =>
               Gate_Cancelled := True;
         end;
         Passed := Passed
           and then Gate_Cancelled
           and then Matches.Count = 0
           and then Flyology.Operations.Is_Active (Child);
         Flyology.Operations.Cancel (Child);
         begin
            Flyology.IO.Timers.Finish (Child);
         exception
            when Flyology.Operations.Operation_Cancelled =>
               null;
         end;
      end;
      Check (Passed, "gate cancellation detach failed");

      declare
         Set : aliased Flyology.Operations.Completion_Set (4);
         Input_1 : aliased Ada.Streams.Stream_Element_Array := [1 => 0];
         Input_2 : aliased Ada.Streams.Stream_Element_Array := [1 => 0];
         Receive_1 : aliased Flyology.IO.Sockets.Receive_Operation :=
           Flyology.IO.Sockets.Receive
             (Set'Access, Left_1'Access, Input_1'Access, 1.0);
         Receive_2 : aliased Flyology.IO.Sockets.Receive_Operation :=
           Flyology.IO.Sockets.Receive
             (Set'Access, Left_2'Access, Input_2'Access, 1.0);
         Alarm : Flyology.IO.Timers.Timer_Operation :=
           Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
         Receives_Done : Flyology.Operations.Gate_Operation :=
           Flyology.Operations.Wait_For_Successes
             (Set'Access, [Ref (Receive_1), Ref (Receive_2)], 2);
         Batch : Flyology.Operations.Completion_Batch (Set.Capacity);
         Gate_Matches :
           Flyology.Operations.Completion_Batch (Set.Capacity);
         Last_1, Last_2 : Ada.Streams.Stream_Element_Offset;
      begin
         while not Flyology.Operations.Is_Terminal (Receives_Done) loop
            Flyology.Operations.Wait_Some (Set, Batch);
         end loop;
         Flyology.Operations.Finish (Receives_Done, Gate_Matches);
         Passed := Passed
           and then Gate_Matches.Count = 2
           and then Contains
             (Gate_Matches, Flyology.Operations.Id (Receive_1))
           and then Contains
             (Gate_Matches, Flyology.Operations.Id (Receive_2));
         Flyology.IO.Sockets.Finish (Receive_1, Last_1);
         Flyology.IO.Sockets.Finish (Receive_2, Last_2);
         Passed := Passed
           and then Last_1 = Input_1'Last
           and then Last_2 = Input_2'Last
           and then Input_1 (Input_1'First) = 42
           and then Input_2 (Input_2'First) = 42;
         Flyology.Operations.Cancel (Alarm);
         begin
            Flyology.IO.Timers.Finish (Alarm);
         exception
            when Flyology.Operations.Operation_Cancelled =>
               null;
         end;
      end;
      Check (Passed, "socket receive gate failed");

      declare
         Set : aliased Flyology.Operations.Completion_Set (3);
         Input : aliased Ada.Streams.Stream_Element_Array := [0, 0];
         Output : aliased Ada.Streams.Stream_Element_Array := [11, 12];
         Receive_All : aliased
           Flyology.IO.Sockets.Receive_Exactly_Operation :=
           Flyology.IO.Sockets.Receive_Exactly
             (Set'Access, Left_1'Access, Input'Access, 1.0);
         Send_All : aliased Flyology.IO.Sockets.Send_All_Operation :=
           Flyology.IO.Sockets.Send_All
             (Set'Access, Right_1'Access, Output'Access, 1.0);
         Transfer_Done : Flyology.Operations.Gate_Operation :=
           Flyology.Operations.Wait_All
             (Set'Access, [Ref (Receive_All), Ref (Send_All)]);
         Batch : Flyology.Operations.Completion_Batch (Set.Capacity);
         Gate_Matches :
           Flyology.Operations.Completion_Batch (Set.Capacity);
      begin
         while not Flyology.Operations.Is_Terminal (Transfer_Done) loop
            Flyology.Operations.Wait_Some (Set, Batch);
         end loop;
         Flyology.Operations.Finish (Transfer_Done, Gate_Matches);
         Flyology.IO.Sockets.Finish (Receive_All);
         Flyology.IO.Sockets.Finish (Send_All);
         Passed := Passed
           and then Gate_Matches.Count = 2
           and then Input = Output;
      end;
      Check (Passed, "socket exact/send-all gate failed");

      declare
         Storage : aliased Flyology.Buffers.Pool
           (Block_Size => 16, Capacity => 2);
         Incoming : aliased Flyology.Buffers.Unique_Buffer (Storage'Access);
         Outgoing : aliased Flyology.Buffers.Unique_Buffer (Storage'Access);
         Set : aliased Flyology.Operations.Completion_Set (3);
         Batch : Flyology.Operations.Completion_Batch (Set.Capacity);
         Received, Sent : Natural;
      begin
         Flyology.Buffers.Acquire (Incoming);
         Flyology.Buffers.Acquire (Outgoing);
         Flyology.Buffers.Copy_From (Outgoing, [7, 8, 9]);
         declare
            Receive_Buffer : aliased
              Flyology.IO.Sockets.Buffer_Receive_Operation :=
                Flyology.IO.Sockets.Receive
                  (Set'Access, Left_2'Access, Incoming'Access, 1.0);
            Send_Buffer : aliased
              Flyology.IO.Sockets.Buffer_Send_Operation :=
              Flyology.IO.Sockets.Send
                (Set'Access, Right_2'Access, Outgoing'Access, 1.0);
            Buffers_Done : Flyology.Operations.Gate_Operation :=
              Flyology.Operations.Wait_All
                (Set'Access,
                 [Ref (Receive_Buffer), Ref (Send_Buffer)]);
            Gate_Matches :
              Flyology.Operations.Completion_Batch (Set.Capacity);
         begin
            while not Flyology.Operations.Is_Terminal (Buffers_Done) loop
               Flyology.Operations.Wait_Some (Set, Batch);
            end loop;
            Flyology.Operations.Finish (Buffers_Done, Gate_Matches);
            Flyology.IO.Sockets.Finish (Receive_Buffer, Received);
            Flyology.IO.Sockets.Finish (Send_Buffer, Sent);
            Passed := Passed
              and then Received = 3
              and then Sent = 3
              and then Gate_Matches.Count = 2
              and then Flyology.Buffers.Length (Incoming) = 3;
         end;
      end;
      Check (Passed, "unique-buffer receive/send gate failed");

      --  Cover the partial array-send operation through a one-member gate.
      declare
         Set : aliased Flyology.Operations.Completion_Set (2);
         Output : aliased Ada.Streams.Stream_Element_Array :=
           [1 => 21, 2 => 22];
         Input : Ada.Streams.Stream_Element_Array := [1 => 0, 2 => 0];
         Send_One : aliased Flyology.IO.Sockets.Send_Operation :=
           Flyology.IO.Sockets.Send
             (Set'Access, Right_1'Access, Output'Access, 1.0);
         Sent : Flyology.Operations.Gate_Operation :=
           Flyology.Operations.Wait_For_Success
             (Set'Access, [Ref (Send_One)]);
         Batch : Flyology.Operations.Completion_Batch (Set.Capacity);
         Matches : Flyology.Operations.Completion_Batch (Set.Capacity);
         Sent_Last, Received_Last : Ada.Streams.Stream_Element_Offset;
      begin
         while not Flyology.Operations.Is_Terminal (Sent) loop
            Flyology.Operations.Wait_Some (Set, Batch);
         end loop;
         Flyology.Operations.Finish (Sent, Matches);
         Flyology.IO.Sockets.Finish (Send_One, Sent_Last);
         Flyology.IO.Sockets.Receive_Socket
           (Left_1, Input, Received_Last);
         Passed := Passed
           and then Matches.Count = 1
           and then Sent_Last = Output'Last
           and then Received_Last = Input'Last
           and then Input = Output;
      end;
      Check (Passed, "array send gate failed");

      --  Cover the complete unique-buffer send operation and retained buffer
      --  ownership through its gate and Finish transition.
      declare
         Storage : aliased Flyology.Buffers.Pool
           (Block_Size => 16, Capacity => 1);
         Outgoing : aliased Flyology.Buffers.Unique_Buffer (Storage'Access);
         Set : aliased Flyology.Operations.Completion_Set (2);
         Input : Ada.Streams.Stream_Element_Array :=
           [1 => 0, 2 => 0, 3 => 0];
         Batch : Flyology.Operations.Completion_Batch (Set.Capacity);
         Matches : Flyology.Operations.Completion_Batch (Set.Capacity);
         Received_Last : Ada.Streams.Stream_Element_Offset;
      begin
         Flyology.Buffers.Acquire (Outgoing);
         Flyology.Buffers.Copy_From (Outgoing, [31, 32, 33]);
         declare
            Send_All_Buffer : aliased
              Flyology.IO.Sockets.Buffer_Send_All_Operation :=
                Flyology.IO.Sockets.Send_All
                  (Set'Access, Right_2'Access, Outgoing'Access, 1.0);
            Sent : Flyology.Operations.Gate_Operation :=
              Flyology.Operations.Wait_All
                (Set'Access, [Ref (Send_All_Buffer)]);
         begin
            while not Flyology.Operations.Is_Terminal (Sent) loop
               Flyology.Operations.Wait_Some (Set, Batch);
            end loop;
            Flyology.Operations.Finish (Sent, Matches);
            Flyology.IO.Sockets.Finish (Send_All_Buffer);
         end;
         Flyology.IO.Sockets.Receive_Socket
           (Left_2, Input, Received_Last);
         Passed := Passed
           and then Matches.Count = 1
           and then Received_Last = Input'Last
           and then Input = [1 => 31, 2 => 32, 3 => 33]
           and then Flyology.Buffers.Length (Outgoing) = 3;
      end;
      Check (Passed, "unique-buffer send-all gate failed");

      --  Cancelling a pending socket operation terminalizes its gate but does
      --  not report the provider exception until the typed Finish call.
      declare
         Set : aliased Flyology.Operations.Completion_Set (2);
         Input : aliased Ada.Streams.Stream_Element_Array := [1 => 0];
         Receive_One : aliased Flyology.IO.Sockets.Receive_Operation :=
           Flyology.IO.Sockets.Receive
             (Set'Access, Left_1'Access, Input'Access, 1.0);
         Done : Flyology.Operations.Gate_Operation :=
           Flyology.Operations.Wait_All
             (Set'Access, [Ref (Receive_One)]);
         Matches : Flyology.Operations.Completion_Batch (Set.Capacity);
         Cancelled : Boolean := False;
         Received_Last : Ada.Streams.Stream_Element_Offset;
      begin
         Flyology.Operations.Cancel (Receive_One);
         Flyology.Operations.Finish (Done, Matches);
         begin
            Flyology.IO.Sockets.Finish (Receive_One, Received_Last);
         exception
            when Flyology.Operations.Operation_Cancelled =>
               Cancelled := True;
         end;
         Passed := Passed
           and then Cancelled
           and then Matches.Count = 1;
      end;

      declare
         Storage : aliased Flyology.Buffers.Pool
           (Block_Size => 16, Capacity => 1);
         Incoming : aliased Flyology.Buffers.Unique_Buffer (Storage'Access);
         Set : aliased Flyology.Operations.Completion_Set (2);
         Cancelled : Boolean := False;
         Received : Natural;
      begin
         Flyology.Buffers.Acquire (Incoming);
         Flyology.Buffers.Copy_From (Incoming, [91, 92]);
         declare
            Receive_Buffer : aliased
              Flyology.IO.Sockets.Buffer_Receive_Operation :=
                Flyology.IO.Sockets.Receive
                  (Set'Access, Left_2'Access, Incoming'Access, 1.0);
            Done : Flyology.Operations.Gate_Operation :=
              Flyology.Operations.Wait_All
                (Set'Access, [Ref (Receive_Buffer)]);
            Matches :
              Flyology.Operations.Completion_Batch (Set.Capacity);
         begin
            Flyology.Operations.Cancel (Receive_Buffer);
            Flyology.Operations.Finish (Done, Matches);
            begin
               Flyology.IO.Sockets.Finish (Receive_Buffer, Received);
            exception
               when Flyology.Operations.Operation_Cancelled =>
                  Cancelled := True;
            end;
            Passed := Passed
              and then Cancelled
              and then Matches.Count = 1
              and then Flyology.Buffers.Length (Incoming) = 2;
         end;
      end;
      Check (Passed, "socket cancellation gates failed");

      --  A provider deadline becomes a Failed operation. The success gate
      --  becomes impossible, while Timeout_Error remains retained for the
      --  socket-specific Finish operation.
      declare
         Set : aliased Flyology.Operations.Completion_Set (2);
         Input : aliased Ada.Streams.Stream_Element_Array := [1 => 0];
         Receive_One : aliased Flyology.IO.Sockets.Receive_Operation :=
           Flyology.IO.Sockets.Receive
             (Set'Access, Left_1'Access, Input'Access, 0.01);
         Succeeded : Flyology.Operations.Gate_Operation :=
           Flyology.Operations.Wait_For_Success
             (Set'Access, [Ref (Receive_One)]);
         Batch : Flyology.Operations.Completion_Batch (Set.Capacity);
         Matches : Flyology.Operations.Completion_Batch (Set.Capacity);
         Timed_Out : Boolean := False;
         Received_Last : Ada.Streams.Stream_Element_Offset;
      begin
         while not Flyology.Operations.Is_Terminal (Succeeded) loop
            Flyology.Operations.Wait_Some (Set, Batch);
         end loop;
         Passed := Passed
           and then Flyology.Operations.Outcome (Receive_One) =
             Flyology.Operations.Failed
           and then Flyology.Operations.Outcome (Succeeded) =
             Flyology.Operations.Failed;
         Flyology.Operations.Finish (Succeeded, Matches);
         begin
            Flyology.IO.Sockets.Finish (Receive_One, Received_Last);
         exception
            when Flyology.IO.Timeout_Error =>
               Timed_Out := True;
         end;
         Passed := Passed
           and then Timed_Out
           and then Matches.Count = 1;
      end;
      Check (Passed, "socket timeout success gate failed");

      --  Orderly closure is a successful zero-byte partial receive, but it is
      --  a failure for Receive_Exactly when the requested array is nonempty.
      declare
         Peer_Left, Peer_Right : aliased Flyology.IO.Sockets.Socket_Type;
         Input : aliased Ada.Streams.Stream_Element_Array := [1 => 0, 2 => 0];
         Partial_Last : Ada.Streams.Stream_Element_Offset;
      begin
         Flyology.IO.Sockets.Create_Socket_Pair (Peer_Left, Peer_Right);
         Flyology.IO.Sockets.Prepare (Peer_Left);
         Flyology.IO.Sockets.Close_Socket (Peer_Right);
         declare
            Set : aliased Flyology.Operations.Completion_Set (2);
            Partial : aliased Flyology.IO.Sockets.Receive_Operation :=
              Flyology.IO.Sockets.Receive
                (Set'Access, Peer_Left'Access, Input'Access, 1.0);
            Done : Flyology.Operations.Gate_Operation :=
              Flyology.Operations.Wait_All
                (Set'Access, [Ref (Partial)]);
            Batch : Flyology.Operations.Completion_Batch (Set.Capacity);
            Matches :
              Flyology.Operations.Completion_Batch (Set.Capacity);
         begin
            while not Flyology.Operations.Is_Terminal (Done) loop
               Flyology.Operations.Wait_Some (Set, Batch);
            end loop;
            Flyology.Operations.Finish (Done, Matches);
            Flyology.IO.Sockets.Finish (Partial, Partial_Last);
            Passed := Passed
              and then Partial_Last = Input'First - 1
              and then Matches.Count = 1;
         end;
         declare
            Set : aliased Flyology.Operations.Completion_Set (2);
            Exact : aliased
              Flyology.IO.Sockets.Receive_Exactly_Operation :=
                Flyology.IO.Sockets.Receive_Exactly
                  (Set'Access, Peer_Left'Access, Input'Access, 1.0);
            Succeeded : Flyology.Operations.Gate_Operation :=
              Flyology.Operations.Wait_For_Success
                (Set'Access, [Ref (Exact)]);
            Batch : Flyology.Operations.Completion_Batch (Set.Capacity);
            Matches :
              Flyology.Operations.Completion_Batch (Set.Capacity);
            Failed : Boolean := False;
         begin
            while not Flyology.Operations.Is_Terminal (Succeeded) loop
               Flyology.Operations.Wait_Some (Set, Batch);
            end loop;
            Passed := Passed
              and then Flyology.Operations.Outcome (Succeeded) =
                Flyology.Operations.Failed;
            Flyology.Operations.Finish (Succeeded, Matches);
            begin
               Flyology.IO.Sockets.Finish (Exact);
            exception
               when Flyology.IO.Device_Error =>
                  Failed := True;
            end;
            Passed := Passed and then Failed and then Matches.Count = 1;
         end;
         Flyology.IO.Sockets.Close_Socket (Peer_Left);
      exception
         when others =>
            Flyology.IO.Sockets.Close_Socket (Peer_Left);
            Flyology.IO.Sockets.Close_Socket (Peer_Right);
            raise;
      end;
      Check (Passed, "socket EOF gate semantics failed");

      if Model = Flyology.Lightweight_Task then
         declare
            Path : constant String := "/tmp/flyology_operations_smoke.dat";
            File : Flyology.IO.Files.File_Descriptor :=
              Flyology.IO.Files.Open
                (Path,
                 Mode => Flyology.IO.Files.Read_Write,
                 Create => True,
                 Truncate => True);
            Left_Data : aliased Ada.Streams.Stream_Element_Array :=
              [1, 2, 3, 4];
            Right_Data : aliased Ada.Streams.Stream_Element_Array :=
              [5, 6, 7, 8];
            Read_Left : aliased Ada.Streams.Stream_Element_Array :=
              [0, 0, 0, 0];
            Read_Right : aliased Ada.Streams.Stream_Element_Array :=
              [0, 0, 0, 0];
         begin
            declare
               Set : aliased Flyology.Operations.Completion_Set (4);
               Write_Left : aliased Flyology.IO.Files.Write_Operation :=
                 Flyology.IO.Files.Write_At
                   (Set'Access, File, 0, Left_Data'Access, 1.0);
               Write_Right : aliased Flyology.IO.Files.Write_Operation :=
                 Flyology.IO.Files.Write_At
                   (Set'Access, File, 4, Right_Data'Access, 1.0);
               Alarm : Flyology.IO.Timers.Timer_Operation :=
                 Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
               Writes_Done : Flyology.Operations.Gate_Operation :=
                 Flyology.Operations.Wait_For_Successes
                   (Set'Access,
                    [Ref (Write_Left), Ref (Write_Right)],
                    Required => 2);
               Batch : Flyology.Operations.Completion_Batch (Set.Capacity);
               Gate_Matches :
                 Flyology.Operations.Completion_Batch (Set.Capacity);
               Last_Left, Last_Right :
                 Ada.Streams.Stream_Element_Offset;
            begin
               while not Flyology.Operations.Is_Terminal (Writes_Done) loop
                  Flyology.Operations.Wait_Some (Set, Batch);
               end loop;
               Flyology.Operations.Finish (Writes_Done, Gate_Matches);
               Passed := Passed
                 and then Gate_Matches.Count = 2
                 and then Contains
                   (Gate_Matches, Flyology.Operations.Id (Write_Left))
                 and then Contains
                   (Gate_Matches, Flyology.Operations.Id (Write_Right));
               Flyology.IO.Files.Finish (Write_Left, Last_Left);
               Flyology.IO.Files.Finish (Write_Right, Last_Right);
               Passed := Passed
                 and then Last_Left = Left_Data'Last
                 and then Last_Right = Right_Data'Last;
               Flyology.Operations.Cancel (Alarm);
               begin
                  Flyology.IO.Timers.Finish (Alarm);
               exception
                  when Flyology.Operations.Operation_Cancelled =>
                     null;
               end;
            end;

            declare
               Set : aliased Flyology.Operations.Completion_Set (3);
               Get_Left : aliased Flyology.IO.Files.Read_Operation :=
                 Flyology.IO.Files.Read_At
                   (Set'Access, File, 0, Read_Left'Access, 1.0);
               Get_Right : aliased Flyology.IO.Files.Read_Operation :=
                 Flyology.IO.Files.Read_At
                   (Set'Access, File, 4, Read_Right'Access, 1.0);
               Reads_Done : Flyology.Operations.Gate_Operation :=
                 Flyology.Operations.Wait_All
                   (Set'Access, [Ref (Get_Left), Ref (Get_Right)]);
               Batch : Flyology.Operations.Completion_Batch (Set.Capacity);
               Gate_Matches :
                 Flyology.Operations.Completion_Batch (Set.Capacity);
               Last_Left, Last_Right :
                 Ada.Streams.Stream_Element_Offset;
            begin
               while not Flyology.Operations.Is_Terminal (Reads_Done) loop
                  Flyology.Operations.Wait_Some (Set, Batch);
               end loop;
               Flyology.Operations.Finish (Reads_Done, Gate_Matches);
               Flyology.IO.Files.Finish (Get_Left, Last_Left);
               Flyology.IO.Files.Finish (Get_Right, Last_Right);
               Passed := Passed
                 and then Gate_Matches.Count = 2
                 and then Last_Left = Read_Left'Last
                 and then Last_Right = Read_Right'Last
                 and then Read_Left = Left_Data
                 and then Read_Right = Right_Data;
            end;

            --  The start-into-existing overloads are the public composition
            --  form. Exercise a heterogeneous file pair without constructing
            --  temporary operation values.
            declare
               Set : aliased Flyology.Operations.Completion_Set (2);
               Procedure_Read : Flyology.IO.Files.Read_Operation (Set'Access);
               Procedure_Write :
                 Flyology.IO.Files.Write_Operation (Set'Access);
               Procedure_Input : aliased
                 Ada.Streams.Stream_Element_Array := [0, 0, 0, 0];
               Procedure_Output : aliased
                 Ada.Streams.Stream_Element_Array := [9, 10, 11, 12];
               Last_Read, Last_Written :
                 Ada.Streams.Stream_Element_Offset;
            begin
               Flyology.IO.Files.Read_At
                 (File, 0, Procedure_Input'Access, 1.0, Procedure_Read);
               Flyology.IO.Files.Write_At
                 (File, 8, Procedure_Output'Access, 1.0, Procedure_Write);
               Flyology.Operations.Wait_All (Set);
               Flyology.IO.Files.Finish (Procedure_Read, Last_Read);
               Flyology.IO.Files.Finish (Procedure_Write, Last_Written);
               Passed := Passed
                 and then Last_Read = Procedure_Input'Last
                 and then Procedure_Input = Left_Data
                 and then Last_Written = Procedure_Output'Last;
            end;

            --  Timeout => 0.0 retains the synchronous file contract: make one
            --  immediate completion attempt before reporting a timeout.
            declare
               Immediate_Data : aliased Ada.Streams.Stream_Element_Array :=
                 [0, 0, 0, 0];
               Set : aliased Flyology.Operations.Completion_Set (1);
               Immediate_Read : Flyology.IO.Files.Read_Operation :=
                 Flyology.IO.Files.Read_At
                   (Set'Access, File, 0, Immediate_Data'Access, 0.0);
               Last_Immediate : Ada.Streams.Stream_Element_Offset;
            begin
               Flyology.Operations.Wait_All (Set);
               Flyology.IO.Files.Finish (Immediate_Read, Last_Immediate);
               Passed := Passed
                 and then Last_Immediate = Immediate_Data'Last
                 and then Immediate_Data = Left_Data;
            end;

            declare
               Set : aliased Flyology.Operations.Completion_Set (1);
               Cancelled_Write : Flyology.IO.Files.Write_Operation :=
                 Flyology.IO.Files.Write_At
                   (Set'Access, File, 8, Left_Data'Access, 1.0);
               Last_Cancelled : Ada.Streams.Stream_Element_Offset;
               Cancellation_Observed : Boolean := False;
            begin
               Flyology.Operations.Cancel (Cancelled_Write);
               Flyology.Operations.Wait_All (Set);
               begin
                  Flyology.IO.Files.Finish
                    (Cancelled_Write, Last_Cancelled);
               exception
                  when Flyology.Operations.Operation_Cancelled =>
                     Cancellation_Observed := True;
               end;
               Passed := Passed and then Cancellation_Observed;
            end;

            declare
               Set : aliased Flyology.Operations.Completion_Set (1);
               Abandoned_Write : Flyology.IO.Files.Write_Operation :=
                 Flyology.IO.Files.Write_At
                   (Set'Access, File, 12, Right_Data'Access, 1.0);
               pragma Unreferenced (Abandoned_Write);
            begin
               null;
            end;

            --  Empty positional operations complete without submitting to a
            --  completion engine, so this supported case remains available
            --  even on a native owner.
            declare
               Empty_Input : aliased Ada.Streams.Stream_Element_Array :=
                 [1 .. 0 => 0];
               Empty_Output : aliased Ada.Streams.Stream_Element_Array :=
                 [1 .. 0 => 0];
               Set : aliased Flyology.Operations.Completion_Set (3);
               Read : aliased Flyology.IO.Files.Read_Operation :=
                 Flyology.IO.Files.Read_At
                   (Set'Access, File, 0, Empty_Input'Access, 1.0);
               Write : aliased Flyology.IO.Files.Write_Operation :=
                 Flyology.IO.Files.Write_At
                   (Set'Access, File, 0, Empty_Output'Access, 1.0);
               Both : Flyology.Operations.Gate_Operation :=
                 Flyology.Operations.Wait_For_Successes
                   (Set'Access, [Ref (Read), Ref (Write)], 2);
               Matches :
                 Flyology.Operations.Completion_Batch (Set.Capacity);
               Last_Read, Last_Written :
                 Ada.Streams.Stream_Element_Offset;
            begin
               Passed := Passed
                 and then Flyology.Operations.Is_Terminal (Both)
                 and then Flyology.Operations.Outcome (Both) =
                   Flyology.Operations.Succeeded;
               Flyology.Operations.Finish (Both, Matches);
               Flyology.IO.Files.Finish (Read, Last_Read);
               Flyology.IO.Files.Finish (Write, Last_Written);
               Passed := Passed
                 and then Matches.Count = 2
                 and then Last_Read = Empty_Input'First - 1
                 and then Last_Written = Empty_Output'First - 1;
            end;
            Flyology.IO.Files.Close (File);
         exception
            when others =>
               Flyology.IO.Files.Close (File);
               raise;
         end;
         Check (Passed, "completion-driven file overload gates failed");
      else
         --  Scoped file operations deliberately reject a native owner until a
         --  native completion engine exists. The operations and their gate
         --  still follow the normal terminal lifecycle.
         declare
            Path : constant String :=
              "/tmp/flyology_operations_native_smoke.dat";
            File : Flyology.IO.Files.File_Descriptor :=
              Flyology.IO.Files.Open
                (Path,
                 Mode => Flyology.IO.Files.Read_Write,
                 Create => True,
                 Truncate => True);
            Input : aliased Ada.Streams.Stream_Element_Array := [1 => 0];
            Output : aliased Ada.Streams.Stream_Element_Array := [1 => 1];
         begin
            declare
               Set : aliased Flyology.Operations.Completion_Set (3);
               Read : aliased
                 Flyology.IO.Files.Read_Operation (Set'Access);
               Write : aliased
                 Flyology.IO.Files.Write_Operation (Set'Access);
               Matches :
                 Flyology.Operations.Completion_Batch (Set.Capacity);
               Last_Read, Last_Written :
                 Ada.Streams.Stream_Element_Offset;
               Read_Failed, Write_Failed : Boolean := False;
            begin
               Flyology.IO.Files.Read_At
                 (File, 0, Input'Access, 1.0, Read);
               Flyology.IO.Files.Write_At
                 (File, 0, Output'Access, 1.0, Write);
               declare
                  Both_Terminal : Flyology.Operations.Gate_Operation :=
                    Flyology.Operations.Wait_All
                      (Set'Access, [Ref (Read), Ref (Write)]);
               begin
                  Passed := Passed
                    and then Flyology.Operations.Is_Terminal (Both_Terminal)
                    and then Flyology.Operations.Outcome (Both_Terminal) =
                      Flyology.Operations.Succeeded;
                  Flyology.Operations.Finish (Both_Terminal, Matches);
                  begin
                     Flyology.IO.Files.Finish (Read, Last_Read);
                  exception
                     when Flyology.IO.Device_Error =>
                        Read_Failed := True;
                  end;
                  begin
                     Flyology.IO.Files.Finish (Write, Last_Written);
                  exception
                     when Flyology.IO.Device_Error =>
                        Write_Failed := True;
                  end;
                  Passed := Passed
                    and then Matches.Count = 2
                    and then Read_Failed
                    and then Write_Failed;
               end;
            end;

            declare
               Empty_Input : aliased Ada.Streams.Stream_Element_Array :=
                 [1 .. 0 => 0];
               Empty_Output : aliased Ada.Streams.Stream_Element_Array :=
                 [1 .. 0 => 0];
               Set : aliased Flyology.Operations.Completion_Set (3);
               Read : aliased Flyology.IO.Files.Read_Operation :=
                 Flyology.IO.Files.Read_At
                   (Set'Access, File, 0, Empty_Input'Access, 1.0);
               Write : aliased Flyology.IO.Files.Write_Operation :=
                 Flyology.IO.Files.Write_At
                   (Set'Access, File, 0, Empty_Output'Access, 1.0);
               Both : Flyology.Operations.Gate_Operation :=
                 Flyology.Operations.Wait_For_Successes
                   (Set'Access, [Ref (Read), Ref (Write)], 2);
               Matches :
                 Flyology.Operations.Completion_Batch (Set.Capacity);
               Last_Read, Last_Written :
                 Ada.Streams.Stream_Element_Offset;
            begin
               Passed := Passed
                 and then Flyology.Operations.Is_Terminal (Both)
                 and then Flyology.Operations.Outcome (Both) =
                   Flyology.Operations.Succeeded;
               Flyology.Operations.Finish (Both, Matches);
               Flyology.IO.Files.Finish (Read, Last_Read);
               Flyology.IO.Files.Finish (Write, Last_Written);
               Passed := Passed
                 and then Matches.Count = 2
                 and then Last_Read = Empty_Input'First - 1
                 and then Last_Written = Empty_Output'First - 1;
            end;
            Flyology.IO.Files.Close (File);
         exception
            when others =>
               Flyology.IO.Files.Close (File);
               raise;
         end;
         Check (Passed, "native file overload rejection gate failed");
      end if;

      Flyology.IO.Sockets.Close_Socket (Left_1);
      Flyology.IO.Sockets.Close_Socket (Right_1);
      Flyology.IO.Sockets.Close_Socket (Left_2);
      Flyology.IO.Sockets.Close_Socket (Right_2);
      Result.Set (Passed);
   exception
      when Error : others =>
         Ada.Text_IO.Put_Line
           (Ada.Exceptions.Exception_Information (Error));
         Result.Set (False);
   end Runner;

   type Runner_Access is access Runner;
   Native      : Runner_Access;
   Lightweight : Runner_Access;
   pragma Unreferenced (Native, Lightweight);
   Passed : Boolean;
begin
   Native := new Runner (Flyology.Native_Task);
   Result.Wait (Passed);
   pragma Assert (Passed);

   Lightweight := new Runner (Flyology.Lightweight_Task);
   Result.Wait (Passed);
   pragma Assert (Passed);
end Operations_Smoke;
