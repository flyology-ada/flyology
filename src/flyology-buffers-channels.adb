with Flyology.Channel_Policy;
with Interfaces;

package body Flyology.Buffers.Channels is
   package Policy renames Flyology.Channel_Policy;

   function To_Stored_Metadata
     (Value : Transfer_Metadata) return Interfaces.Unsigned_64 is
     (Interfaces.Unsigned_64 (Value));

   function From_Stored_Metadata
     (Value : Interfaces.Unsigned_64) return Transfer_Metadata is
     (Transfer_Metadata (Value));

   protected body Channel_State is
      --  Take Value's token into the queue. Detach and the queue update run
      --  in one protected action, so no abort can leave the slot owned by
      --  both Value and the channel.
      procedure Enqueue
        (Value    : in out Unique_Buffer;
         Metadata : Transfer_Metadata)
      is
         Token : Buffer_Token;
      begin
         Detach (Value, Token);
         Token.Channel_Metadata := To_Stored_Metadata (Metadata);
         Values (Tail) := Token;
         Tail := Policy.Advance (Tail, Capacity);
         Count := Policy.Count_After_Send (Count, Capacity);
      end Enqueue;

      --  Hand the oldest queued token to Target. Attach commits the transfer
      --  before the queue advances, so a rejected token stays queued instead
      --  of being lost, and the caller never holds a dequeued token outside
      --  this protected action.
      procedure Deliver
        (Target   : in out Unique_Buffer;
         Metadata : out Transfer_Metadata)
      is
         Token : Buffer_Token := Values (Head);
      begin
         Metadata := From_Stored_Metadata (Token.Channel_Metadata);
         Token.Channel_Metadata := 0;
         Attach (Target, Token);
         Values (Head) := No_Token;
         Head := Policy.Advance (Head, Capacity);
         Count := Policy.Count_After_Receive (Count);
      end Deliver;

      entry Send
        (Value    : in out Unique_Buffer;
         Metadata : Transfer_Metadata;
         Accepted : out Boolean)
        when Policy.Send_Entry_Open (Stopped, Count, Capacity)
      is
      begin
         case Policy.Classify_Send (Stopped, Count, Capacity) is
            when Policy.Accept_Send =>
               Enqueue (Value, Metadata);
               Accepted := True;
            when Policy.Reject_Send =>
               Accepted := False;
            when Policy.Wait_To_Send =>
               raise Program_Error with
                 "buffer channel send entry opened while full";
         end case;
      end Send;

      entry Receive
        (Target    : in out Unique_Buffer;
         Metadata  : out Transfer_Metadata;
         Available : out Boolean)
        when Policy.Receive_Entry_Open (Stopped, Count)
      is
      begin
         case Policy.Classify_Receive (Stopped, Count) is
            when Policy.Accept_Receive =>
               Deliver (Target, Metadata);
               Available := True;
            when Policy.Reject_Receive =>
               Metadata := No_Metadata;
               Available := False;
            when Policy.Wait_To_Receive =>
               raise Program_Error with
                 "buffer channel receive entry opened while empty";
         end case;
      end Receive;

      procedure Try_Send
        (Value    : in out Unique_Buffer;
         Metadata : Transfer_Metadata;
         Result   : out Try_Send_Result) is
      begin
         case Policy.Classify_Send (Stopped, Count, Capacity) is
            when Policy.Accept_Send =>
               Enqueue (Value, Metadata);
               Result := Item_Sent;
            when Policy.Wait_To_Send =>
               Result := Channel_Full;
            when Policy.Reject_Send =>
               Result := Send_Closed;
         end case;
      end Try_Send;

      procedure Try_Receive
        (Target   : in out Unique_Buffer;
         Metadata : out Transfer_Metadata;
         Result   : out Try_Receive_Result) is
      begin
         case Policy.Classify_Receive (Stopped, Count) is
            when Policy.Accept_Receive =>
               Deliver (Target, Metadata);
               Result := Item_Received;
            when Policy.Wait_To_Receive =>
               Metadata := No_Metadata;
               Result := Channel_Empty;
            when Policy.Reject_Receive =>
               Metadata := No_Metadata;
               Result := Receive_Closed;
         end case;
      end Try_Receive;

      procedure Take_Undelivered
        (Token  : out Buffer_Token;
         Result : out Try_Receive_Result) is
      begin
         case Policy.Classify_Receive (Stopped, Count) is
            when Policy.Accept_Receive =>
               Token := Values (Head);
               Values (Head) := No_Token;
               Head := Policy.Advance (Head, Capacity);
               Count := Policy.Count_After_Receive (Count);
               Result := Item_Received;
            when Policy.Wait_To_Receive =>
               Token := No_Token;
               Result := Channel_Empty;
            when Policy.Reject_Receive =>
               Token := No_Token;
               Result := Receive_Closed;
         end case;
      end Take_Undelivered;

      procedure Close is
      begin
         Stopped := True;
      end Close;

      entry Await_Drained when Policy.Is_Drained (Stopped, Count) is
      begin
         null;
      end Await_Drained;

      function Current return Snapshot is
        (Closed            => Stopped,
         Pending           => Count,
         Waiting_Senders   => Send'Count,
         Waiting_Receivers => Receive'Count);
   end Channel_State;

   procedure Validate_Pools
     (Item  : Channel;
      Value : Unique_Buffer) is
   begin
      if Item.Owner /= Value.Owner then
         raise Program_Error with "buffer belongs to another channel pool";
      end if;
   end Validate_Pools;

   procedure Send_Move
     (Item  : in out Channel;
      Value : in out Unique_Buffer;
      Metadata : Transfer_Metadata := No_Metadata)
   is
      Accepted : Boolean;
   begin
      Validate_Pools (Item, Value);
      if not Has_Buffer (Value) then
         raise Program_Error with "send of a vacant buffer";
      end if;
      Item.State.Send (Value, Metadata, Accepted);
      if not Accepted then
         raise Channel_Closed with "send on closed buffer channel";
      end if;
   end Send_Move;

   procedure Receive_Move
     (Item   : in out Channel;
      Target : in out Unique_Buffer)
   is
      Metadata : Transfer_Metadata;
   begin
      Receive_Move (Item, Target, Metadata);
   end Receive_Move;

   procedure Receive_Move
     (Item     : in out Channel;
      Target   : in out Unique_Buffer;
      Metadata : out Transfer_Metadata)
   is
      Available : Boolean;
   begin
      Metadata := No_Metadata;
      Validate_Pools (Item, Target);
      if Has_Buffer (Target) then
         raise Program_Error with "receive into an occupied buffer";
      end if;
      Item.State.Receive (Target, Metadata, Available);
      if not Available then
         raise Channel_Closed with "receive from drained buffer channel";
      end if;
   end Receive_Move;

   procedure Try_Send_Move
     (Item   : in out Channel;
      Value  : in out Unique_Buffer;
      Result : out Try_Send_Result;
      Metadata : Transfer_Metadata := No_Metadata) is
   begin
      Validate_Pools (Item, Value);
      if not Has_Buffer (Value) then
         raise Program_Error with "send of a vacant buffer";
      end if;
      Item.State.Try_Send (Value, Metadata, Result);
   end Try_Send_Move;

   procedure Try_Receive_Move
     (Item   : in out Channel;
      Target : in out Unique_Buffer;
      Result : out Try_Receive_Result)
   is
      Metadata : Transfer_Metadata;
   begin
      Try_Receive_Move (Item, Target, Result, Metadata);
   end Try_Receive_Move;

   procedure Try_Receive_Move
     (Item     : in out Channel;
      Target   : in out Unique_Buffer;
      Result   : out Try_Receive_Result;
      Metadata : out Transfer_Metadata) is
   begin
      Metadata := No_Metadata;
      Validate_Pools (Item, Target);
      if Has_Buffer (Target) then
         raise Program_Error with "receive into an occupied buffer";
      end if;
      Item.State.Try_Receive (Target, Metadata, Result);
   end Try_Receive_Move;

   procedure Timed_Send_Move
     (Item    : in out Channel;
      Value   : in out Unique_Buffer;
      Timeout : Duration;
      Metadata : Transfer_Metadata := No_Metadata)
   is
      Accepted : Boolean;
      Result   : Try_Send_Result;
   begin
      if Timeout < 0.0 then
         Send_Move (Item, Value, Metadata);
         return;
      elsif Timeout = 0.0 then
         Try_Send_Move (Item, Value, Result, Metadata);
         case Result is
            when Item_Sent => return;
            when Send_Closed =>
               raise Channel_Closed with "send on closed buffer channel";
            when Channel_Full =>
               raise Timeout_Error with "buffer channel send timed out";
         end case;
      end if;

      Validate_Pools (Item, Value);
      if not Has_Buffer (Value) then
         raise Program_Error with "send of a vacant buffer";
      end if;
      select
         Item.State.Send (Value, Metadata, Accepted);
         if not Accepted then
            raise Channel_Closed with "send on closed buffer channel";
         end if;
      or
         delay Timeout;
         raise Timeout_Error with "buffer channel send timed out";
      end select;
   end Timed_Send_Move;

   procedure Timed_Receive_Move
     (Item    : in out Channel;
      Target  : in out Unique_Buffer;
      Timeout : Duration)
   is
      Metadata : Transfer_Metadata;
   begin
      Timed_Receive_Move (Item, Target, Timeout, Metadata);
   end Timed_Receive_Move;

   procedure Timed_Receive_Move
     (Item    : in out Channel;
      Target  : in out Unique_Buffer;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      Metadata : Transfer_Metadata;
   begin
      Timed_Receive_Move (Item, Target, Timeout, Metadata, Token);
   end Timed_Receive_Move;

   procedure Timed_Receive_Move
     (Item     : in out Channel;
      Target   : in out Unique_Buffer;
      Timeout  : Duration;
      Metadata : out Transfer_Metadata)
   is
      Available : Boolean;
      Result    : Try_Receive_Result;
   begin
      Metadata := No_Metadata;
      if Timeout < 0.0 then
         Receive_Move (Item, Target, Metadata);
         return;
      elsif Timeout = 0.0 then
         Try_Receive_Move (Item, Target, Result, Metadata);
         case Result is
            when Item_Received => return;
            when Receive_Closed =>
               raise Channel_Closed with
                 "receive from drained buffer channel";
            when Channel_Empty =>
               raise Timeout_Error with "buffer channel receive timed out";
         end case;
      end if;

      Validate_Pools (Item, Target);
      if Has_Buffer (Target) then
         raise Program_Error with "receive into an occupied buffer";
      end if;
      select
         Item.State.Receive (Target, Metadata, Available);
         if not Available then
            raise Channel_Closed with
              "receive from drained buffer channel";
         end if;
      or
         delay Timeout;
         raise Timeout_Error with "buffer channel receive timed out";
      end select;
   end Timed_Receive_Move;

   procedure Timed_Receive_Move
     (Item     : in out Channel;
      Target   : in out Unique_Buffer;
      Timeout  : Duration;
      Metadata : out Transfer_Metadata;
      Token    : access Flyology.Cancellation.Token) is
   begin
      Metadata := No_Metadata;
      if Token = null then
         Timed_Receive_Move (Item, Target, Timeout, Metadata);
      elsif Token.Requested then
         raise Operation_Cancelled;
      else
         select
            Token.Await_Request;
            raise Operation_Cancelled;
         then abort
            Timed_Receive_Move (Item, Target, Timeout, Metadata);
         end select;
      end if;
   end Timed_Receive_Move;

   procedure Close (Item : in out Channel) is
   begin
      Item.State.Close;
   end Close;

   procedure Await_Drained (Item : in out Channel) is
   begin
      Item.State.Await_Drained;
   end Await_Drained;

   function Current (Item : Channel) return Snapshot is
     (Item.State.Current);

   overriding procedure Finalize (Item : in out Channel) is
      Token  : Buffer_Token;
      Result : Try_Receive_Result;
   begin
      Item.State.Close;
      loop
         Item.State.Take_Undelivered (Token, Result);
         exit when Result /= Item_Received;
         Release_Token (Item.Owner, Token);
      end loop;
   end Finalize;

end Flyology.Buffers.Channels;
