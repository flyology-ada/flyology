with Flyology.Channel_Policy;

package body Flyology.Channels.Bounded is

   package Policy renames Flyology.Channel_Policy;

   protected body Channel is
      entry Send (Value : Element_Type)
        when Policy.Send_Entry_Open (Stopped, Count, Capacity)
      is
      begin
         case Policy.Classify_Send (Stopped, Count, Capacity) is
            when Policy.Accept_Send =>
               Buffer (Tail) := Value;
               Tail := Policy.Advance (Tail, Capacity);
               Count := Policy.Count_After_Send (Count, Capacity);
            when Policy.Reject_Send =>
               raise Channel_Closed with "send on closed channel";
            when Policy.Wait_To_Send =>
               raise Program_Error with "channel send entry opened while full";
         end case;
      end Send;

      entry Receive (Value : out Element_Type)
        when Policy.Receive_Entry_Open (Stopped, Count)
      is
      begin
         case Policy.Classify_Receive (Stopped, Count) is
            when Policy.Accept_Receive =>
               Value := Buffer (Head);
               Head := Policy.Advance (Head, Capacity);
               Count := Policy.Count_After_Receive (Count);
            when Policy.Reject_Receive =>
               raise Channel_Closed with "receive from drained channel";
            when Policy.Wait_To_Receive =>
               raise Program_Error with
                 "channel receive entry opened while empty";
         end case;
      end Receive;

      procedure Try_Send
        (Value  : Element_Type;
         Result : out Try_Send_Result)
      is
      begin
         case Policy.Classify_Send (Stopped, Count, Capacity) is
            when Policy.Accept_Send =>
               Buffer (Tail) := Value;
               Tail := Policy.Advance (Tail, Capacity);
               Count := Policy.Count_After_Send (Count, Capacity);
               Result := Item_Sent;
            when Policy.Wait_To_Send =>
               Result := Channel_Full;
            when Policy.Reject_Send =>
               Result := Send_Closed;
         end case;
      end Try_Send;

      procedure Try_Receive
        (Value  : in out Element_Type;
         Result : out Try_Receive_Result)
      is
      begin
         case Policy.Classify_Receive (Stopped, Count) is
            when Policy.Accept_Receive =>
               Value := Buffer (Head);
               Head := Policy.Advance (Head, Capacity);
               Count := Policy.Count_After_Receive (Count);
               Result := Item_Received;
            when Policy.Wait_To_Receive =>
               Result := Channel_Empty;
            when Policy.Reject_Receive =>
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
   end Channel;

   procedure Timed_Send
     (Item    : in out Channel;
      Value   : Element_Type;
      Timeout : Duration)
   is
   begin
      if Timeout < 0.0 then
         Item.Send (Value);
      else
         select
            Item.Send (Value);
         or
            delay Timeout;
            raise Timeout_Error with "channel send timed out";
         end select;
      end if;
   end Timed_Send;

   procedure Timed_Receive
     (Item    : in out Channel;
      Value   : out Element_Type;
      Timeout : Duration)
   is
   begin
      if Timeout < 0.0 then
         Item.Receive (Value);
      else
         select
            Item.Receive (Value);
         or
            delay Timeout;
            raise Timeout_Error with "channel receive timed out";
         end select;
      end if;
   end Timed_Receive;

end Flyology.Channels.Bounded;
