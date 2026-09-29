package body Flyology.Supervision.Service_Slots is

   use type Child_Id;

   protected body Directory_State is
      procedure Next_Token (Value : out Publication_Token) is
      begin
         if Last_Token = Publication_Token'Last then
            raise Program_Error with "service publication identity space exhausted";
         end if;
         Last_Token := Last_Token + 1;
         Value := Last_Token;
      end Next_Token;

      procedure Reserve
        (Kind : Service_Kind; Value : Child_Handle; Token : Publication_Token; Accepted : out Boolean) is
      begin
         Accepted := not Claimed (Kind);
         if Accepted then
            Claimed (Kind) := True;
            Handles (Kind) := Value;
            Tokens (Kind) := Token;
         end if;
      end Reserve;

      procedure Activate (Kind : Service_Kind; Value : Child_Handle; Token : Publication_Token) is
      begin
         if not Claimed (Kind) or else Handles (Kind) /= Value or else Tokens (Kind) /= Token then
            raise Program_Error with "service publication reservation was lost";
         end if;
         Published (Kind) := True;
      end Activate;

      procedure Revoke (Kind : Service_Kind; Value : Child_Handle; Token : Publication_Token) is
      begin
         if Claimed (Kind) and then Handles (Kind) = Value and then Tokens (Kind) = Token then
            Published (Kind) := False;
            Claimed (Kind) := False;
            Tokens (Kind) := 0;
         end if;
      end Revoke;

      function Acquire (Kind : Service_Kind) return Service_Observation is
      begin
         if Published (Kind) then
            return (Status => Available, Lease => (Kind => Kind, Value => Handles (Kind)));
         end if;
         return (Status => Unavailable);
      end Acquire;

      function Current (Lease : Service_Lease) return Boolean
      is (Published (Lease.Kind) and then Handles (Lease.Kind) = Lease.Value);
   end Directory_State;

   procedure Publish_Ready
     (Item : in out Publication; Service : Service_Kind; Control : in out Generation_Control)
   is
      Accepted : Boolean;
      Value    : constant Child_Handle := Handle (Control);
   begin
      if Item.Owned then
         raise Program_Error with "service publication is already active";
      elsif Child (Value) /= Logical_Id (Service) then
         raise Program_Error with "service publication handle names another child";
      end if;

      Item.From.State.Next_Token (Item.Token);
      Item.Kind := Service;
      Item.Value := Value;
      Item.Owned := True;
      Item.From.State.Reserve (Service, Value, Item.Token, Accepted);
      if not Accepted then
         Item.Token := 0;
         Item.Owned := False;
         raise Program_Error with "service is already published";
      end if;
      begin
         Mark_Ready (Control);
         Item.From.State.Activate (Service, Value, Item.Token);
      exception
         when others =>
            Withdraw (Item);
            raise;
      end;
   end Publish_Ready;

   procedure Withdraw (Item : in out Publication) is
   begin
      if Item.Owned then
         Item.From.State.Revoke (Item.Kind, Item.Value, Item.Token);
         Item.Token := 0;
         Item.Owned := False;
      end if;
   end Withdraw;

   function Active (Item : Publication) return Boolean
   is (Item.Owned);

   function Acquire (From : Directory; Service : Service_Kind) return Service_Observation
   is (From.State.Acquire (Service));

   function Current (From : Directory; Lease : Service_Lease) return Boolean
   is (From.State.Current (Lease));

   function Service (Lease : Service_Lease) return Service_Kind
   is (Lease.Kind);

   function Handle (Lease : Service_Lease) return Child_Handle
   is (Lease.Value);

   overriding
   procedure Finalize (Item : in out Publication) is
   begin
      Withdraw (Item);
   exception
      when others =>
         null;
   end Finalize;

begin
   for Left in Service_Kind loop
      for Right in Service_Kind loop
         if Left /= Right and then Logical_Id (Left) = Logical_Id (Right) then
            raise Configuration_Error with "service logical ids must be unique";
         end if;
      end loop;
   end loop;
end Flyology.Supervision.Service_Slots;
