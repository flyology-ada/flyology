with Ada.Real_Time;
with Ada.Streams;
with Flyology;
with Flyology.Buffers;
with Flyology.Buffers.Channels;
with Flyology.Cancellation;

--  Cancelling or aborting a buffer-channel receive must never destroy a
--  message whose send already succeeded. Both scenarios drive the sender and
--  the canceller from one execution group, so the receiver cannot resume
--  between the accepted send and the cancellation request: the receive entry
--  body has already dequeued the token when the receiver is aborted.

procedure Buffer_Channel_Cancel_Smoke is
   package Buffers renames Flyology.Buffers;
   package Channels renames Flyology.Buffers.Channels;

   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Channels.Try_Receive_Result;

   Attempts : constant := 16;
   Payload  : constant Ada.Streams.Stream_Element_Array := (11, 22, 33, 44);

   Storage : aliased Buffers.Pool (Block_Size => 16, Capacity => 4);

   procedure Assert (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Assert;

   procedure Check_Payload (Item : Buffers.Unique_Buffer) is
      procedure Check (Data : Ada.Streams.Stream_Element_Array) is
      begin
         Assert (Data'Length = Payload'Length, "recovered length differs");
         for Offset in 0 .. Payload'Length - 1 loop
            Assert
              (Data (Data'First + Ada.Streams.Stream_Element_Offset (Offset))
               = Payload (Payload'First + Ada.Streams.Stream_Element_Offset (Offset)),
               "recovered payload differs");
         end loop;
      end Check;
   begin
      Buffers.With_Readable_Data (Item, Check'Access);
   end Check_Payload;

   --  Block until the peer task is queued on the channel entry. Both tasks
   --  share one execution group, so the poll must yield cooperatively.
   procedure Await_Waiter (Queue : in out Channels.Channel; Receiver : Boolean; Message : String) is
      Deadline : constant Ada.Real_Time.Time := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (10);
      Waiting  : Natural;
   begin
      loop
         if Receiver then
            Waiting := Channels.Current (Queue).Waiting_Receivers;
         else
            Waiting := Channels.Current (Queue).Waiting_Senders;
         end if;
         exit when Waiting > 0;
         Assert (Ada.Real_Time.Clock < Deadline, Message);
         delay 0.0;
      end loop;
   end Await_Waiter;

   --  Account for the message after the receive was cancelled: it is either
   --  delivered into Target or still queued, never destroyed.
   procedure Account_For_Message
     (Queue : in out Channels.Channel; Target : in out Buffers.Unique_Buffer; Path : String)
   is
      Result : Channels.Try_Receive_Result;
   begin
      if not Buffers.Has_Buffer (Target) then
         Channels.Try_Receive_Move (Queue, Target, Result);
         Assert (Result = Channels.Item_Received, Path & " destroyed a successfully sent message");
      end if;
      Check_Payload (Target);
      Buffers.Release (Target);
      Assert (Buffers.Current (Storage).Outstanding = 0, Path & " leaked a pool slot");
   end Account_For_Message;

   --  A requested cancellation token aborts the receive after the channel
   --  entry body has handed the token over.
   procedure Cancelled_Receive (Observed_Cancellation : out Boolean) is
      Queue    : Channels.Channel (Storage'Access, Capacity => 2);
      Stop     : aliased Flyology.Cancellation.Token;
      Target   : Buffers.Unique_Buffer (Storage'Access);
      Notified : Boolean := False;
   begin
      declare
         task Receiver
           with CPU => 1 is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Receiver;

         task Sender
           with CPU => 1 is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Sender;

         task body Receiver is
            Metadata : Channels.Transfer_Metadata;
         begin
            Channels.Timed_Receive_Move (Queue, Target, 30.0, Metadata, Stop'Access);
         exception
            when Flyology.Cancellation.Operation_Cancelled =>
               Notified := True;
         end Receiver;

         task body Sender is
            Outgoing : Buffers.Unique_Buffer (Storage'Access);
         begin
            Buffers.Acquire (Outgoing);
            Buffers.Copy_From (Outgoing, Payload);
            Await_Waiter (Queue, True, "receiver never queued");
            --  No suspension between these two calls, so the receiver
            --  observes cancellation with the dequeued token in hand.
            Channels.Send_Move (Queue, Outgoing);
            Stop.Request;
         end Sender;
      begin
         null;
      end;
      Observed_Cancellation := Notified;
      Account_For_Message (Queue, Target, "cancelled receive");
   end Cancelled_Receive;

   --  Plain Ada abort of an indefinite receive opens the same window.
   procedure Aborted_Receive (Observed_Abort : out Boolean) is
      Queue     : Channels.Channel (Storage'Access, Capacity => 2);
      Target    : Buffers.Unique_Buffer (Storage'Access);
      Completed : Boolean := False;
   begin
      declare
         task Receiver
           with CPU => 1 is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Receiver;

         task Sender
           with CPU => 1 is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Sender;

         task body Receiver is
         begin
            Channels.Receive_Move (Queue, Target);
            Completed := True;
         end Receiver;

         task body Sender is
            Outgoing : Buffers.Unique_Buffer (Storage'Access);
         begin
            Buffers.Acquire (Outgoing);
            Buffers.Copy_From (Outgoing, Payload);
            Await_Waiter (Queue, True, "receiver never queued");
            Channels.Send_Move (Queue, Outgoing);
            abort Receiver;
         end Sender;
      begin
         null;
      end;
      Observed_Abort := not Completed;
      Account_For_Message (Queue, Target, "aborted receive");
   end Aborted_Receive;

   --  Plain Ada abort of a send that the channel already accepted must not
   --  hand the slot back to the sender: the channel owns it.
   procedure Aborted_Send (Observed_Abort : out Boolean) is
      Queue     : Channels.Channel (Storage'Access, Capacity => 1);
      Outgoing  : Buffers.Unique_Buffer (Storage'Access);
      Filler    : Buffers.Unique_Buffer (Storage'Access);
      Drained   : Buffers.Unique_Buffer (Storage'Access);
      Completed : Boolean := False;
      Result    : Channels.Try_Receive_Result;
   begin
      Buffers.Acquire (Filler);
      Channels.Send_Move (Queue, Filler);
      Buffers.Acquire (Outgoing);
      Buffers.Copy_From (Outgoing, Payload);
      declare
         task Sender
           with CPU => 1 is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Sender;

         task Drainer
           with CPU => 1 is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Drainer;

         task body Sender is
         begin
            Channels.Send_Move (Queue, Outgoing);
            Completed := True;
         end Sender;

         task body Drainer is
         begin
            Await_Waiter (Queue, False, "sender never queued");
            --  Freeing the single slot lets the queued send entry body run
            --  inside this protected action; the sender cannot resume before
            --  the abort request.
            Channels.Try_Receive_Move (Queue, Drained, Result);
            abort Sender;
         end Drainer;
      begin
         null;
      end;
      Observed_Abort := not Completed;
      Assert (Result = Channels.Item_Received, "drainer missed the filler");
      Buffers.Release (Drained);

      if Buffers.Has_Buffer (Outgoing) and then Channels.Current (Queue).Pending = 1 then
         --  The sender and the channel claim the same slot. Undo the
         --  duplicate before reporting it, so that the pool's stale-release
         --  diagnostic during finalization cannot mask this failure.
         Buffers.Release (Outgoing);
         Channels.Try_Receive_Move (Queue, Drained, Result);
         begin
            Buffers.Release (Drained);
         exception
            when others =>
               null;
         end;
         Assert (False, "aborted send duplicated ownership of one pool slot");
      end if;

      if Buffers.Has_Buffer (Outgoing) then
         Buffers.Release (Outgoing);
      else
         Channels.Try_Receive_Move (Queue, Drained, Result);
         Assert (Result = Channels.Item_Received, "accepted send was lost");
         Check_Payload (Drained);
         Buffers.Release (Drained);
      end if;
      Assert (Buffers.Current (Storage).Outstanding = 0, "aborted send leaked a pool slot");
   end Aborted_Send;

   Cancellations : Natural := 0;
   Aborts        : Natural := 0;
   Send_Aborts   : Natural := 0;
   Observed      : Boolean;

begin
   for Attempt in 1 .. Attempts loop
      Cancelled_Receive (Observed);
      if Observed then
         Cancellations := Cancellations + 1;
      end if;
      Assert (Buffers.Current (Storage).Outstanding = 0, "cancellation attempt left the pool unbalanced");
   end loop;

   for Attempt in 1 .. Attempts loop
      Aborted_Receive (Observed);
      if Observed then
         Aborts := Aborts + 1;
      end if;
      Assert (Buffers.Current (Storage).Outstanding = 0, "abort attempt left the pool unbalanced");
   end loop;

   for Attempt in 1 .. Attempts loop
      Aborted_Send (Observed);
      if Observed then
         Send_Aborts := Send_Aborts + 1;
      end if;
      Assert (Buffers.Current (Storage).Outstanding = 0, "send attempt left the pool unbalanced");
   end loop;

   --  The scenarios are worthless if the transfer always completed normally.
   Assert (Cancellations > 0, "no receive observed its cancellation token");
   Assert (Aborts > 0, "no receive was aborted before it completed");
   Assert (Send_Aborts > 0, "no send was aborted before it completed");
end Buffer_Channel_Cancel_Smoke;
