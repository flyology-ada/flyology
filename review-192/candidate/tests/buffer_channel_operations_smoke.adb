with Ada.Exceptions;
with Ada.Text_IO;
with Flyology;
with Flyology.Buffers;
with Flyology.Buffers.Channels;
with Flyology.IO.Timers;
with Flyology.Operations;
with Interfaces;

procedure Buffer_Channel_Operations_Smoke is
   package Buffers renames Flyology.Buffers;
   package Channels renames Flyology.Buffers.Channels;

   use type Channels.Transfer_Metadata;
   use type Channels.Try_Receive_Result;
   use type Interfaces.Unsigned_64;

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
      Storage       : aliased Buffers.Pool (Block_Size => 16, Capacity => 12);
      Other_Storage : aliased Buffers.Pool (Block_Size => 16, Capacity => 2);
      Passed        : Boolean := True;

      procedure Acquire_Tagged (Item : in out Buffers.Unique_Buffer; Tag : Interfaces.Unsigned_64) is
      begin
         Buffers.Acquire (Item);
         Buffers.Set_Tag (Item, Tag);
      end Acquire_Tagged;
   begin
      --  A receive owns the dequeued token until Finish and composes with an
      --  ordinary timer through the same success gate as every other provider.
      declare
         Queue    : aliased Channels.Channel (Storage'Access, Capacity => 2);
         Set      : aliased Flyology.Operations.Completion_Set (3);
         Outgoing : Buffers.Unique_Buffer (Storage'Access);
         Incoming : Buffers.Unique_Buffer (Storage'Access);
         Get      : aliased Channels.Receive_Operation :=
           Channels.Receive_Move (Set'Access, Queue'Unchecked_Access, 1.0);
         Alarm    : aliased Flyology.IO.Timers.Timer_Operation :=
           Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
         First    : Flyology.Operations.Gate_Operation :=
           Flyology.Operations.Wait_For_Success (Set'Access, [Ref (Get), Ref (Alarm)]);
         Batch    : Flyology.Operations.Completion_Batch (Set.Capacity);
         Matches  : Flyology.Operations.Completion_Batch (Set.Capacity);
         Metadata : Channels.Transfer_Metadata;
      begin
         Acquire_Tagged (Outgoing, 101);
         Channels.Send_Move (Queue, Outgoing, 11);
         Check (not Buffers.Has_Buffer (Outgoing), "synchronous send retained ownership");
         loop
            Flyology.Operations.Wait_Some (Set, Batch);
            exit when Flyology.Operations.Is_Terminal (First);
         end loop;
         Flyology.Operations.Finish (First, Matches);
         Channels.Finish (Get, Incoming, Metadata);
         Passed :=
           Passed
           and then Buffers.Has_Buffer (Incoming)
           and then Buffers.Tag (Incoming) = 101
           and then Metadata = 11
           and then Matches.Count = 1;
         Buffers.Release (Incoming);
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

      --  One channel can wake several ownership-transferring operations in a
      --  stable completion-set batch. The gate observes both terminal members
      --  while each typed Finish performs its own ownership transfer.
      declare
         Queue                                  : aliased Channels.Channel (Storage'Access, Capacity => 2);
         Set                                    : aliased Flyology.Operations.Completion_Set (3);
         Left                                   : aliased Channels.Receive_Operation :=
           Channels.Receive_Move (Set'Access, Queue'Unchecked_Access, 1.0);
         Right                                  : aliased Channels.Receive_Operation :=
           Channels.Receive_Move (Set'Access, Queue'Unchecked_Access, 1.0);
         Both                                   : Flyology.Operations.Gate_Operation :=
           Flyology.Operations.Wait_All (Set'Access, [Ref (Left), Ref (Right)]);
         Batch                                  : Flyology.Operations.Completion_Batch (Set.Capacity);
         Matches                                : Flyology.Operations.Completion_Batch (Set.Capacity);
         First, Second, Left_Value, Right_Value : Buffers.Unique_Buffer (Storage'Access);
         Left_Metadata, Right_Metadata          : Channels.Transfer_Metadata;
      begin
         Acquire_Tagged (First, 151);
         Acquire_Tagged (Second, 152);
         Channels.Send_Move (Queue, First, 51);
         Channels.Send_Move (Queue, Second, 52);
         loop
            Flyology.Operations.Wait_Some (Set, Batch);
            exit when Flyology.Operations.Is_Terminal (Both);
         end loop;
         Flyology.Operations.Finish (Both, Matches);
         Channels.Finish (Left, Left_Value, Left_Metadata);
         Channels.Finish (Right, Right_Value, Right_Metadata);
         Passed :=
           Passed
           and then Matches.Count = 2
           and then ((Buffers.Tag (Left_Value) = 151
                      and then Left_Metadata = 51
                      and then Buffers.Tag (Right_Value) = 152
                      and then Right_Metadata = 52)
                     or else (Buffers.Tag (Left_Value) = 152
                              and then Left_Metadata = 52
                              and then Buffers.Tag (Right_Value) = 151
                              and then Right_Metadata = 51));
         Buffers.Release (Left_Value);
         Buffers.Release (Right_Value);
      end;

      --  A pending send owns its token. Releasing capacity commits that token
      --  to the channel; successful Finish leaves the source handle vacant.
      declare
         Queue                     : aliased Channels.Channel (Storage'Access, Capacity => 1);
         Set                       : aliased Flyology.Operations.Completion_Set (1);
         Filler, Outgoing, Drained : Buffers.Unique_Buffer (Storage'Access);
         Result                    : Channels.Try_Receive_Result;
         Metadata                  : Channels.Transfer_Metadata;
      begin
         Acquire_Tagged (Filler, 201);
         Channels.Send_Move (Queue, Filler);
         Acquire_Tagged (Outgoing, 202);
         declare
            Put : Channels.Send_Operation :=
              Channels.Send_Move (Set'Access, Queue'Unchecked_Access, Outgoing, 22, 1.0);
         begin
            Check (not Buffers.Has_Buffer (Outgoing), "pending send did not move ownership");
            Channels.Try_Receive_Move (Queue, Drained, Result, Metadata);
            Check
              (Result = Channels.Item_Received and then Buffers.Tag (Drained) = 201,
               "capacity release missed filler");
            Buffers.Release (Drained);
            Flyology.Operations.Wait_All (Set);
            Channels.Finish (Put, Outgoing);
            Check
              (not Buffers.Has_Buffer (Outgoing), "successful send Finish restored transferred ownership");
         end;
         Channels.Try_Receive_Move (Queue, Drained, Result, Metadata);
         Passed :=
           Passed
           and then Result = Channels.Item_Received
           and then Buffers.Tag (Drained) = 202
           and then Metadata = 22;
         Buffers.Release (Drained);
      end;

      --  Timeout and cancellation return a pending send's owned token before
      --  typed Finish raises its retained terminal outcome.
      declare
         Queue                                                       :
           aliased Channels.Channel (Storage'Access, Capacity => 1);
         Set                                                         :
           aliased Flyology.Operations.Completion_Set (2);
         Filler, Timed_Value, Cancelled_Value, Closed_Value, Drained : Buffers.Unique_Buffer (Storage'Access);
         Wrong_Pool                                                  :
           Buffers.Unique_Buffer (Other_Storage'Access);
         Result                                                      : Channels.Try_Receive_Result;
         Timed_Out, Was_Cancelled, Was_Closed                        : Boolean := False;
         Pool_Mismatch                                               : Boolean := False;
      begin
         Acquire_Tagged (Filler, 301);
         Channels.Send_Move (Queue, Filler);
         Acquire_Tagged (Timed_Value, 302);
         declare
            Put : Channels.Send_Operation :=
              Channels.Send_Move (Set'Access, Queue'Unchecked_Access, Timed_Value, Timeout => 0.005);
         begin
            Flyology.Operations.Wait_All (Set);
            begin
               Channels.Finish (Put, Wrong_Pool);
            exception
               when Program_Error =>
                  Pool_Mismatch := True;
            end;
            Check (Flyology.Operations.Is_Terminal (Put), "wrong-pool Finish consumed the send operation");
            begin
               Channels.Finish (Put, Timed_Value);
            exception
               when Channels.Timeout_Error =>
                  Timed_Out := True;
            end;
         end;
         Acquire_Tagged (Cancelled_Value, 303);
         declare
            Put : Channels.Send_Operation :=
              Channels.Send_Move (Set'Access, Queue'Unchecked_Access, Cancelled_Value);
         begin
            Flyology.Operations.Cancel (Put);
            begin
               Channels.Finish (Put, Cancelled_Value);
            exception
               when Channels.Operation_Cancelled =>
                  Was_Cancelled := True;
            end;
         end;
         Acquire_Tagged (Closed_Value, 304);
         declare
            Put : Channels.Send_Operation :=
              Channels.Send_Move (Set'Access, Queue'Unchecked_Access, Closed_Value);
         begin
            Channels.Close (Queue);
            Flyology.Operations.Wait_All (Set);
            begin
               Channels.Finish (Put, Closed_Value);
            exception
               when Channels.Channel_Closed =>
                  Was_Closed := True;
            end;
         end;
         Passed :=
           Passed
           and then Timed_Out
           and then Was_Cancelled
           and then Was_Closed
           and then Pool_Mismatch
           and then Buffers.Tag (Timed_Value) = 302
           and then Buffers.Tag (Cancelled_Value) = 303
           and then Buffers.Tag (Closed_Value) = 304;
         Buffers.Release (Timed_Value);
         Buffers.Release (Cancelled_Value);
         Buffers.Release (Closed_Value);
         Channels.Try_Receive_Move (Queue, Drained, Result);
         Check (Result = Channels.Item_Received, "buffer channel filler disappeared");
         Buffers.Release (Drained);
      end;

      --  Procedure overloads restart consumed send and receive objects without
      --  allocating a replacement operation or changing ownership semantics.
      declare
         Queue         : aliased Channels.Channel (Storage'Access, Capacity => 1);
         Set           : aliased Flyology.Operations.Completion_Set (2);
         Put           : Channels.Send_Operation (Set'Access);
         Get           : Channels.Receive_Operation (Set'Access);
         Value, Target : Buffers.Unique_Buffer (Storage'Access);
         Metadata      : Channels.Transfer_Metadata;
      begin
         for Pass in 1 .. 2 loop
            Acquire_Tagged (Value, Interfaces.Unsigned_64 (500 + Pass));
            Channels.Send_Move
              (Queue'Unchecked_Access, Value, Channels.Transfer_Metadata (60 + Pass), 0.0, Put);
            Flyology.Operations.Wait_All (Set);
            Channels.Finish (Put, Value);
            Check (not Buffers.Has_Buffer (Value), "restarted send restored successful ownership");

            Channels.Receive_Move (Queue'Unchecked_Access, 0.0, Get);
            Flyology.Operations.Wait_All (Set);
            Channels.Finish (Get, Target, Metadata);
            Passed :=
              Passed
              and then Buffers.Tag (Target) = Interfaces.Unsigned_64 (500 + Pass)
              and then Metadata = Channels.Transfer_Metadata (60 + Pass);
            Buffers.Release (Target);
         end loop;
      end;

      --  Receive timeout, close, and cancellation never invent ownership.
      declare
         Queue                                : aliased Channels.Channel (Storage'Access, Capacity => 1);
         Set                                  : aliased Flyology.Operations.Completion_Set (3);
         Timed                                : Channels.Receive_Operation :=
           Channels.Receive_Move (Set'Access, Queue'Unchecked_Access, 0.005);
         Closed                               : Channels.Receive_Operation (Set'Access);
         Cancelled                            : Channels.Receive_Operation (Set'Access);
         Target                               : Buffers.Unique_Buffer (Storage'Access);
         Metadata                             : Channels.Transfer_Metadata;
         Timed_Out, Was_Closed, Was_Cancelled : Boolean := False;
      begin
         Flyology.Operations.Wait_All (Set);
         begin
            Channels.Finish (Timed, Target, Metadata);
         exception
            when Channels.Timeout_Error =>
               Timed_Out := True;
         end;
         Channels.Receive_Move (Queue'Unchecked_Access, 1.0, Closed);
         Channels.Receive_Move (Queue'Unchecked_Access, 1.0, Cancelled);
         Flyology.Operations.Cancel (Cancelled);
         Channels.Close (Queue);
         Flyology.Operations.Wait_All (Set);
         begin
            Channels.Finish (Closed, Target, Metadata);
         exception
            when Channels.Channel_Closed =>
               Was_Closed := True;
         end;
         begin
            Channels.Finish (Cancelled, Target, Metadata);
         exception
            when Channels.Operation_Cancelled =>
               Was_Cancelled := True;
         end;
         Passed :=
           Passed
           and then Timed_Out
           and then Was_Closed
           and then Was_Cancelled
           and then not Buffers.Has_Buffer (Target);
      end;

      --  Abandoning a pending send or a successful receive releases the token
      --  owned by the operation; no caller stack or pool slot is leaked.
      declare
         Queue                  : aliased Channels.Channel (Storage'Access, Capacity => 1);
         Set                    : aliased Flyology.Operations.Completion_Set (1);
         Filler, Value, Drained : Buffers.Unique_Buffer (Storage'Access);
         Result                 : Channels.Try_Receive_Result;
      begin
         Acquire_Tagged (Filler, 401);
         Channels.Send_Move (Queue, Filler);
         Acquire_Tagged (Value, 402);
         declare
            Abandoned : Channels.Send_Operation :=
              Channels.Send_Move (Set'Access, Queue'Unchecked_Access, Value);
            pragma Unreferenced (Abandoned);
         begin
            null;
         end;
         Check (Buffers.Current (Storage).Outstanding = 1, "abandoned send leaked its owned token");
         Channels.Try_Receive_Move (Queue, Drained, Result);
         Check (Result = Channels.Item_Received, "abandoned-send filler disappeared");
         Buffers.Release (Drained);

         Acquire_Tagged (Value, 403);
         Channels.Send_Move (Queue, Value);
         declare
            Abandoned : Channels.Receive_Operation :=
              Channels.Receive_Move (Set'Access, Queue'Unchecked_Access);
            pragma Unreferenced (Abandoned);
         begin
            null;
         end;
         Passed := Passed and then Buffers.Current (Storage).Outstanding = 0;
      end;

      Check (Passed, "buffer channel operation matrix failed");
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
end Buffer_Channel_Operations_Smoke;
