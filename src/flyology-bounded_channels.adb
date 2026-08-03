package body Flyology.Bounded_Channels is

   protected body Channel_State is
      entry Send (Value : Element_Type; Accepted : out Boolean)
        when Count < Capacity or else Closed
      is
      begin
         if Closed then
            Accepted := False;
            return;
         end if;
         Values (Tail) := Value;
         Tail := (if Tail = Capacity then 1 else Tail + 1);
         Count := Count + 1;
         Accepted := True;
      end Send;

      entry Receive (Value : out Element_Type; Available : out Boolean)
        when Count > 0 or else Closed
      is
      begin
         if Count = 0 then
            Available := False;
            return;
         end if;
         Value := Values (Head);
         Values (Head) := Empty_Value;
         Head := (if Head = Capacity then 1 else Head + 1);
         Count := Count - 1;
         Available := True;
      end Receive;

      procedure Try_Send (Value : Element_Type; Accepted : out Boolean) is
      begin
         if Closed or else Count = Capacity then
            Accepted := False;
            return;
         end if;
         Values (Tail) := Value;
         Tail := (if Tail = Capacity then 1 else Tail + 1);
         Count := Count + 1;
         Accepted := True;
      end Try_Send;

      procedure Try_Receive
        (Value : out Element_Type;
         Available : out Boolean)
      is
      begin
         if Count = 0 then
            Available := False;
            return;
         end if;
         Value := Values (Head);
         Values (Head) := Empty_Value;
         Head := (if Head = Capacity then 1 else Head + 1);
         Count := Count - 1;
         Available := True;
      end Try_Receive;

      procedure Close is
      begin
         Closed := True;
      end Close;

      function Is_Closed return Boolean is (Closed);
      function Length return Natural is (Count);
   end Channel_State;

   procedure Send
     (Item     : in out Channel;
      Value    : Element_Type;
      Accepted : out Boolean) is
   begin
      Item.State.Send (Value, Accepted);
   end Send;

   procedure Receive
     (Item      : in out Channel;
      Value     : out Element_Type;
      Available : out Boolean) is
   begin
      Item.State.Receive (Value, Available);
   end Receive;

   procedure Receive_For
     (Item      : in out Channel;
      Value     : out Element_Type;
      Available : out Boolean;
      Timeout   : Duration;
      Timed_Out : out Boolean) is
   begin
      Timed_Out := False;
      if Timeout < 0.0 then
         Item.State.Receive (Value, Available);
      else
         select
            Item.State.Receive (Value, Available);
         or
            delay Timeout;
            Value := Empty_Value;
            Available := False;
            Timed_Out := True;
         end select;
      end if;
   end Receive_For;

   procedure Try_Send
     (Item     : in out Channel;
      Value    : Element_Type;
      Accepted : out Boolean) is
   begin
      Item.State.Try_Send (Value, Accepted);
   end Try_Send;

   procedure Send_For
     (Item      : in out Channel;
      Value     : Element_Type;
      Accepted  : out Boolean;
      Timeout   : Duration;
      Timed_Out : out Boolean) is
   begin
      Timed_Out := False;
      if Timeout < 0.0 then
         Item.State.Send (Value, Accepted);
      else
         select
            Item.State.Send (Value, Accepted);
         or
            delay Timeout;
            Accepted := False;
            Timed_Out := True;
         end select;
      end if;
   end Send_For;

   procedure Try_Receive
     (Item      : in out Channel;
      Value     : out Element_Type;
      Available : out Boolean) is
   begin
      Item.State.Try_Receive (Value, Available);
   end Try_Receive;

   procedure Close (Item : in out Channel) is
   begin
      Item.State.Close;
   end Close;

   function Is_Closed (Item : Channel) return Boolean is
     (Item.State.Is_Closed);

   function Length (Item : Channel) return Natural is (Item.State.Length);

end Flyology.Bounded_Channels;
