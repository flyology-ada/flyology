with Ada.Exceptions;
with Ada.Text_IO;
with Flyology;
with Flyology.Buffers;
with Flyology.Buffers.Channels;
with Flyology.Channel_Testing;
with Flyology.Operations;
with Interfaces;

procedure Buffer_Channel_Signal_Smoke is
   package Buffers renames Flyology.Buffers;
   package Channels renames Flyology.Buffers.Channels;

   use type Channels.Try_Receive_Result;
   use type Interfaces.Unsigned_64;

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
      Storage : aliased Buffers.Pool (Block_Size => 16, Capacity => 4);
   begin
      --  Abort after enqueue must still flush the pending receive's wake.
      declare
         Queue    : aliased Channels.Channel (Storage'Access, Capacity => 1);
         Set      : aliased Flyology.Operations.Completion_Set (1);
         Get      : Channels.Receive_Operation :=
           Channels.Receive_Move (Set'Access, Queue'Unchecked_Access, 1.0);
         Outgoing : Buffers.Unique_Buffer (Storage'Access);
         Incoming : Buffers.Unique_Buffer (Storage'Access);
         Result   : Channels.Try_Send_Result;

         function Prepare return Boolean is
         begin
            Flyology.Channel_Testing.Reset;
            Buffers.Acquire (Outgoing);
            Buffers.Set_Tag (Outgoing, 91);
            Flyology.Channel_Testing.Arm_After_Buffer_Commit;
            return True;
         end Prepare;

         Armed : constant Boolean := Prepare;
         pragma Unreferenced (Armed);

         task Sender;

         task body Sender is
         begin
            Channels.Try_Send_Move (Queue, Outgoing, Result);
         end Sender;
      begin
         Flyology.Channel_Testing.Wait_After_Buffer_Commit;
         abort Sender;
         Flyology.Channel_Testing.Release_After_Buffer_Commit;
         while not Sender'Terminated loop
            delay 0.0;
         end loop;
         Flyology.Operations.Wait_All (Set);
         Channels.Finish (Get, Incoming);
         Check
           (Buffers.Tag (Incoming) = 91,
            "aborted sender lost its committed buffer or wake");
         Buffers.Release (Incoming);
         Flyology.Channel_Testing.Reset;
      exception
         when others =>
            Flyology.Channel_Testing.Release_After_Buffer_Commit;
            abort Sender;
            Flyology.Channel_Testing.Reset;
            raise;
      end;

      --  The operation's set may not finalize while its write is claimed.
      declare
         Queue     : aliased Channels.Channel (Storage'Access, Capacity => 1);
         Set       : aliased Flyology.Operations.Completion_Set (1);
         Get       : Channels.Receive_Operation :=
           Channels.Receive_Move (Set'Access, Queue'Unchecked_Access, 1.0);
         Outgoing  : Buffers.Unique_Buffer (Storage'Access);
         Drained   : Buffers.Unique_Buffer (Storage'Access);
         Result    : Channels.Try_Send_Result;
         Received  : Channels.Try_Receive_Result;
         Cancelled : Boolean := False;

         function Prepare return Boolean is
         begin
            Flyology.Channel_Testing.Reset;
            Buffers.Acquire (Outgoing);
            Buffers.Set_Tag (Outgoing, 92);
            Flyology.Channel_Testing.Arm_After_Signal_Claim;
            return True;
         end Prepare;

         Armed : constant Boolean := Prepare;
         pragma Unreferenced (Armed);

         task Sender;
         task Releaser is
            entry Start;
         end Releaser;

         task body Sender is
         begin
            Channels.Try_Send_Move (Queue, Outgoing, Result);
         end Sender;

         task body Releaser is
         begin
            accept Start;
            delay 0.02;
            Flyology.Channel_Testing.Release_After_Signal_Claim;
         end Releaser;
      begin
         Flyology.Channel_Testing.Wait_After_Signal_Claim;
         Releaser.Start;
         Flyology.Operations.Cancel (Get);
         Check
           (Flyology.Channel_Testing.Signal_Claim_Was_Released,
            "subscriber cancellation passed an in-flight signal claim");
         begin
            Channels.Finish (Get, Drained);
         exception
            when Channels.Operation_Cancelled =>
               Cancelled := True;
         end;
         Check (Cancelled, "claimed subscriber did not cancel");
         while not Sender'Terminated loop
            delay 0.0;
         end loop;
         Channels.Try_Receive_Move (Queue, Drained, Received);
         Check
           (Received = Channels.Item_Received
            and then Buffers.Tag (Drained) = 92,
            "claimed signal changed channel ownership");
         Buffers.Release (Drained);
         Flyology.Channel_Testing.Reset;
      exception
         when others =>
            Flyology.Channel_Testing.Release_After_Signal_Claim;
            abort Sender;
            abort Releaser;
            Flyology.Channel_Testing.Reset;
            raise;
      end;

      --  A failed write for the newest subscriber cannot stop delivery to
      --  an older subscriber or raise after the buffer has been enqueued.
      declare
         Queue     : aliased Channels.Channel (Storage'Access, Capacity => 1);
         First_Set : aliased Flyology.Operations.Completion_Set (1);
         Last_Set  : aliased Flyology.Operations.Completion_Set (1);
         First     : Channels.Receive_Operation :=
           Channels.Receive_Move
             (First_Set'Access, Queue'Unchecked_Access, 1.0);
         Last      : Channels.Receive_Operation :=
           Channels.Receive_Move
             (Last_Set'Access, Queue'Unchecked_Access, 1.0);
         Outgoing  : Buffers.Unique_Buffer (Storage'Access);
         Incoming  : Buffers.Unique_Buffer (Storage'Access);
         Cancelled : Boolean := False;
      begin
         Flyology.Channel_Testing.Reset;
         Buffers.Acquire (Outgoing);
         Buffers.Set_Tag (Outgoing, 93);
         Flyology.Channel_Testing.Arm_Next_Buffer_Signal_Failure;
         Channels.Send_Move (Queue, Outgoing);
         Flyology.Operations.Wait_All (First_Set);
         Channels.Finish (First, Incoming);
         Check
           (Buffers.Tag (Incoming) = 93,
            "one failed subscriber blocked the next wake");
         Buffers.Release (Incoming);
         Flyology.Operations.Cancel (Last);
         begin
            Channels.Finish (Last, Incoming);
         exception
            when Channels.Operation_Cancelled =>
               Cancelled := True;
         end;
         Check (Cancelled, "failed-signal subscriber did not cancel");
         Flyology.Channel_Testing.Reset;
      end;

      Check
        (Buffers.Current (Storage).Outstanding = 0,
         "buffer channel signal test leaked a token");
      Results.Publish (True);
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
end Buffer_Channel_Signal_Smoke;
