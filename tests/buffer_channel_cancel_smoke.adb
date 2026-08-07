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

   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Channels.Try_Receive_Result;

   Attempts : constant := 16;
   Payload  : constant Ada.Streams.Stream_Element_Array :=
     (11, 22, 33, 44);

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
                 = Payload
                     (Payload'First
                      + Ada.Streams.Stream_Element_Offset (Offset)),
               "recovered payload differs");
         end loop;
      end Check;
   begin
      Buffers.With_Readable_Data (Item, Check'Access);
   end Check_Payload;

   --  Block the sender until the receiver is queued on the channel entry.
   --  Both tasks share one execution group, so the poll must yield.
   procedure Await_Waiting_Receiver (Queue : in out Channels.Channel) is
      Spins : Natural := 0;
   begin
      while Channels.Current (Queue).Waiting_Receivers = 0 loop
         Assert (Spins < 100_000_000, "receiver never queued on the channel");
         Spins := Spins + 1;
         delay 0.0;
      end loop;
   end Await_Waiting_Receiver;

   --  Account for the message after the receive was cancelled: it is either
   --  delivered into Target or still queued, never destroyed.
   procedure Account_For_Message
     (Queue  : in out Channels.Channel;
      Target : in out Buffers.Unique_Buffer;
      Path   : String)
   is
      Result : Channels.Try_Receive_Result;
   begin
      if not Buffers.Has_Buffer (Target) then
         Channels.Try_Receive_Move (Queue, Target, Result);
         Assert
           (Result = Channels.Item_Received,
            Path & " destroyed a successfully sent message");
      end if;
      Check_Payload (Target);
      Buffers.Release (Target);
      Assert
        (Buffers.Current (Storage).Outstanding = 0,
         Path & " leaked a pool slot");
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
         task Receiver with CPU => 1 is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Receiver;

         task Sender with CPU => 1 is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Sender;

         task body Receiver is
            Metadata : Channels.Transfer_Metadata;
         begin
            Channels.Timed_Receive_Move
              (Queue, Target, 30.0, Metadata, Stop'Access);
         exception
            when Flyology.Cancellation.Operation_Cancelled =>
               Notified := True;
         end Receiver;

         task body Sender is
            Outgoing : Buffers.Unique_Buffer (Storage'Access);
         begin
            Buffers.Acquire (Outgoing);
            Buffers.Copy_From (Outgoing, Payload);
            Await_Waiting_Receiver (Queue);
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
         task Receiver with CPU => 1 is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Receiver;

         task Sender with CPU => 1 is
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
            Await_Waiting_Receiver (Queue);
            Channels.Send_Move (Queue, Outgoing);
            abort Receiver;
         end Sender;
      begin
         null;
      end;
      Observed_Abort := not Completed;
      Account_For_Message (Queue, Target, "aborted receive");
   end Aborted_Receive;

   Cancellations : Natural := 0;
   Aborts        : Natural := 0;
   Observed      : Boolean;

begin
   for Attempt in 1 .. Attempts loop
      Cancelled_Receive (Observed);
      if Observed then
         Cancellations := Cancellations + 1;
      end if;
      Assert
        (Buffers.Current (Storage).Outstanding = 0,
         "cancellation attempt left the pool unbalanced");
   end loop;

   for Attempt in 1 .. Attempts loop
      Aborted_Receive (Observed);
      if Observed then
         Aborts := Aborts + 1;
      end if;
      Assert
        (Buffers.Current (Storage).Outstanding = 0,
         "abort attempt left the pool unbalanced");
   end loop;

   --  The scenarios are worthless if the receive always completed normally.
   Assert (Cancellations > 0, "no receive observed its cancellation token");
   Assert (Aborts > 0, "no receive was aborted before it completed");
end Buffer_Channel_Cancel_Smoke;
