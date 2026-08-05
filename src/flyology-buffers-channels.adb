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
      entry Send (Token : Buffer_Token; Accepted : out Boolean)
        when Policy.Send_Entry_Open (Stopped, Count, Capacity)
      is
      begin
         case Policy.Classify_Send (Stopped, Count, Capacity) is
            when Policy.Accept_Send =>
               Values (Tail) := Token;
               Tail := Policy.Advance (Tail, Capacity);
               Count := Policy.Count_After_Send (Count, Capacity);
               Accepted := True;
            when Policy.Reject_Send =>
               Accepted := False;
            when Policy.Wait_To_Send =>
               raise Program_Error with
                 "buffer channel send entry opened while full";
         end case;
      end Send;

      entry Receive
        (Token     : out Buffer_Token;
         Available : out Boolean)
        when Policy.Receive_Entry_Open (Stopped, Count)
      is
      begin
         case Policy.Classify_Receive (Stopped, Count) is
            when Policy.Accept_Receive =>
               Token := Values (Head);
               Values (Head) := No_Token;
               Head := Policy.Advance (Head, Capacity);
               Count := Policy.Count_After_Receive (Count);
               Available := True;
            when Policy.Reject_Receive =>
               Token := No_Token;
               Available := False;
            when Policy.Wait_To_Receive =>
               raise Program_Error with
                 "buffer channel receive entry opened while empty";
         end case;
      end Receive;

      procedure Try_Send
        (Token    : Buffer_Token;
         Result   : out Try_Send_Result;
         Accepted : out Boolean) is
      begin
         case Policy.Classify_Send (Stopped, Count, Capacity) is
            when Policy.Accept_Send =>
               Values (Tail) := Token;
               Tail := Policy.Advance (Tail, Capacity);
               Count := Policy.Count_After_Send (Count, Capacity);
               Result := Item_Sent;
               Accepted := True;
            when Policy.Wait_To_Send =>
               Result := Channel_Full;
               Accepted := False;
            when Policy.Reject_Send =>
               Result := Send_Closed;
               Accepted := False;
         end case;
      end Try_Send;

      procedure Try_Receive
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
      end Try_Receive;

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

   type Send_Guard
     (Target      : not null access Unique_Buffer;
      Token       : not null access Buffer_Token;
      Transferred : not null access Boolean) is
     new Ada.Finalization.Limited_Controlled with null record;

   overriding procedure Finalize (Item : in out Send_Guard) is
   begin
      if not Item.Transferred.all and then Item.Token.Slot /= No_Slot then
         Attach (Item.Target.all, Item.Token.all);
      end if;
   end Finalize;

   type Receive_Guard
     (Target : not null access Unique_Buffer;
      Token  : not null access Buffer_Token) is
     new Ada.Finalization.Limited_Controlled with null record;

   overriding procedure Finalize (Item : in out Receive_Guard) is
   begin
      if Item.Token.Slot /= No_Slot
        and then not Owns (Item.Target.all, Item.Token.all)
      then
         Release_Token (Item.Target.Owner, Item.Token.all);
      end if;
   end Finalize;

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
      Token       : aliased Buffer_Token := No_Token;
      Transferred : aliased Boolean := False;
      Guard       : Send_Guard
        (Value'Unchecked_Access, Token'Access, Transferred'Access);
      pragma Unreferenced (Guard);
   begin
      Validate_Pools (Item, Value);
      if not Has_Buffer (Value) then
         raise Program_Error with "send of a vacant buffer";
      end if;
      Detach (Value, Token);
      Token.Channel_Metadata := To_Stored_Metadata (Metadata);
      Item.State.Send (Token, Transferred);
      if not Transferred then
         raise Channel_Closed with "send on closed buffer channel";
      end if;
      Token := No_Token;
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
      Token     : aliased Buffer_Token := No_Token;
      Available : Boolean;
      Guard     : Receive_Guard
        (Target'Unchecked_Access, Token'Access);
      pragma Unreferenced (Guard);
   begin
      Metadata := No_Metadata;
      Validate_Pools (Item, Target);
      if Has_Buffer (Target) then
         raise Program_Error with "receive into an occupied buffer";
      end if;
      Item.State.Receive (Token, Available);
      if not Available then
         raise Channel_Closed with "receive from drained buffer channel";
      end if;
      Metadata := From_Stored_Metadata (Token.Channel_Metadata);
      Token.Channel_Metadata := 0;
      Attach (Target, Token);
   end Receive_Move;

   procedure Try_Send_Move
     (Item   : in out Channel;
      Value  : in out Unique_Buffer;
      Result : out Try_Send_Result;
      Metadata : Transfer_Metadata := No_Metadata)
   is
      Token       : aliased Buffer_Token := No_Token;
      Transferred : aliased Boolean := False;
      Guard       : Send_Guard
        (Value'Unchecked_Access, Token'Access, Transferred'Access);
      pragma Unreferenced (Guard);
   begin
      Validate_Pools (Item, Value);
      if not Has_Buffer (Value) then
         raise Program_Error with "send of a vacant buffer";
      end if;
      Detach (Value, Token);
      Token.Channel_Metadata := To_Stored_Metadata (Metadata);
      Item.State.Try_Send (Token, Result, Transferred);
      if Transferred then
         Token := No_Token;
      end if;
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
      Metadata : out Transfer_Metadata)
   is
      Token : aliased Buffer_Token := No_Token;
      Guard : Receive_Guard (Target'Unchecked_Access, Token'Access);
      pragma Unreferenced (Guard);
   begin
      Metadata := No_Metadata;
      Validate_Pools (Item, Target);
      if Has_Buffer (Target) then
         raise Program_Error with "receive into an occupied buffer";
      end if;
      Item.State.Try_Receive (Token, Result);
      if Result = Item_Received then
         Metadata := From_Stored_Metadata (Token.Channel_Metadata);
         Token.Channel_Metadata := 0;
         Attach (Target, Token);
      end if;
   end Try_Receive_Move;

   procedure Timed_Send_Move
     (Item    : in out Channel;
      Value   : in out Unique_Buffer;
      Timeout : Duration;
      Metadata : Transfer_Metadata := No_Metadata)
   is
      Token       : aliased Buffer_Token := No_Token;
      Transferred : aliased Boolean := False;
      Guard       : Send_Guard
        (Value'Unchecked_Access, Token'Access, Transferred'Access);
      pragma Unreferenced (Guard);
      Result : Try_Send_Result;
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
      Detach (Value, Token);
      Token.Channel_Metadata := To_Stored_Metadata (Metadata);
      select
         Item.State.Send (Token, Transferred);
         if not Transferred then
            raise Channel_Closed with "send on closed buffer channel";
         end if;
         Token := No_Token;
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
      Token     : aliased Buffer_Token := No_Token;
      Available : Boolean;
      Guard     : Receive_Guard
        (Target'Unchecked_Access, Token'Access);
      pragma Unreferenced (Guard);
      Result : Try_Receive_Result;
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
         Item.State.Receive (Token, Available);
         if not Available then
            raise Channel_Closed with
              "receive from drained buffer channel";
         end if;
         Metadata := From_Stored_Metadata (Token.Channel_Metadata);
         Token.Channel_Metadata := 0;
         Attach (Target, Token);
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
         Item.State.Try_Receive (Token, Result);
         exit when Result /= Item_Received;
         Release_Token (Item.Owner, Token);
      end loop;
   end Finalize;

end Flyology.Buffers.Channels;
