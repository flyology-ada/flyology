with Ada.Real_Time;
with Flyology.IO;

package body Flyology.HTTP.Server.SSE_Handlers is
   use type Ada.Real_Time.Time;
   use type Ada.Real_Time.Time_Span;

   protected body Retained_Bytes is
      procedure Try_Reserve (Bytes : Natural; Granted : out Boolean) is
      begin
         Granted := Bytes <= Limit - Used;
         if Granted then
            Used := Used + Bytes;
         end if;
      end Try_Reserve;

      procedure Release (Bytes : Natural) is
      begin
         if Bytes > Used then
            raise Program_Error with "SSE session byte budget underflow";
         end if;
         Used := Used - Bytes;
      end Release;
   end Retained_Bytes;

   type Reservation_Guard is new Ada.Finalization.Limited_Controlled with
     record
      Shared          : Outbound_Budget_Access;
      Owner           : Session_Access;
      Bytes           : Natural := 0;
      Local_Reserved  : Boolean := False;
      Shared_Reserved : Boolean := False;
      Transferred     : Boolean_Access;
   end record;

   overriding procedure Finalize (Item : in out Reservation_Guard) is
   begin
      if Item.Transferred = null or else not Item.Transferred.all then
         if Item.Shared_Reserved then
            Release (Item.Shared.all, Item.Bytes);
         end if;
         if Item.Local_Reserved then
            Item.Owner.Bytes.Release (Item.Bytes);
         end if;
      end if;
   end Finalize;

   function Payload_Bytes (Value : Event_Value) return Natural is
     (Length (Value.Data) + Length (Value.Event) + Length (Value.Id));

   procedure Reserve
     (Item    : in out Session;
      Bytes   : Natural;
      Guard   : in out Reservation_Guard;
      Granted : out Boolean)
   is
   begin
      Guard.Bytes := Bytes;
      Guard.Owner := Item'Unchecked_Access;
      Guard.Shared :=
        (if Item.Budget = null
         then Default_Outbound_Budget'Access
         else Item.Budget.all'Unchecked_Access);
      Item.Bytes.Try_Reserve (Bytes, Granted);
      Guard.Local_Reserved := Granted;
      if not Granted then
         return;
      end if;
      Try_Reserve (Guard.Shared.all, Bytes, Granted);
      Guard.Shared_Reserved := Granted;
      if not Granted then
         Item.Bytes.Release (Bytes);
         Guard.Local_Reserved := False;
      end if;
   end Reserve;

   procedure Release_Retention
     (Item : in out Session; Value : Event_Value)
   is
      Bytes : constant Natural := Payload_Bytes (Value);
      Shared : constant Outbound_Budget_Access :=
        (if Item.Budget = null
         then Default_Outbound_Budget'Access
         else Item.Budget.all'Unchecked_Access);
   begin
      Release (Shared.all, Bytes);
      Item.Bytes.Release (Bytes);
   end Release_Retention;

   procedure Drain (Item : in out Session) is
      Value     : Event_Value;
      Available : Boolean;
   begin
      loop
         Item.Outbox.Try_Receive (Value, Available);
         exit when not Available;
         Release_Retention (Item, Value);
      end loop;
   end Drain;

   function Within_Limit (Value : Event_Value) return Boolean is
      Data_Length  : constant Natural := Length (Value.Data);
      Event_Length : constant Natural := Length (Value.Event);
      Id_Length    : constant Natural := Length (Value.Id);
   begin
      return Data_Length <= Max_Queued_Message_Bytes
        and then Event_Length <= Max_Queued_Message_Bytes - Data_Length
        and then Id_Length <=
          Max_Queued_Message_Bytes - Data_Length - Event_Length;
   end Within_Limit;

   procedure Publish
     (Item     : in out Session;
      Value    : Event_Value;
      Accepted : out Boolean) is
      Queued  : aliased Boolean := False;
      Granted : Boolean;
      Guard   : Reservation_Guard;
   begin
      if not Within_Limit (Value) then
         Accepted := False;
      else
         Guard.Transferred := Queued'Unchecked_Access;
         Reserve (Item, Payload_Bytes (Value), Guard, Granted);
         if Granted then
            Item.Outbox.Send (Value, Queued);
         end if;
         Accepted := Granted and then Queued;
      end if;
   end Publish;

   procedure Publish_For
     (Item      : in out Session;
      Value     : Event_Value;
      Accepted  : out Boolean;
      Timeout   : Duration;
      Timed_Out : out Boolean;
      Token     : access Flyology.Cancellation.Token := null)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Left    : Duration := Timeout;
      Queued  : aliased Boolean := False;
      Granted : Boolean;
      Guard   : Reservation_Guard;
   begin
      Accepted := False;
      Timed_Out := False;
      if not Within_Limit (Value) then
         return;
      end if;
      Guard.Transferred := Queued'Unchecked_Access;
      Reserve (Item, Payload_Bytes (Value), Guard, Granted);
      if not Granted then
         return;
      end if;
      loop
         if Item.Stop.Requested then
            Timed_Out := False;
            return;
         elsif Token /= null and then Token.Requested then
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
         Item.Outbox.Send_For
           (Value, Queued,
            (if Left < 0.0 then 0.05 else Duration'Min (Left, 0.05)),
            Timed_Out);
         Accepted := Queued;
         exit when Queued or else not Timed_Out;
         if Timeout >= 0.0 then
            Left := Timeout - Ada.Real_Time.To_Duration
              (Ada.Real_Time.Clock - Started);
            if Left <= 0.0 then
               Timed_Out := True;
               exit;
            end if;
         end if;
      end loop;
   end Publish_For;

   procedure Try_Publish
     (Item     : in out Session;
      Value    : Event_Value;
      Accepted : out Boolean) is
      Queued  : aliased Boolean := False;
      Granted : Boolean;
      Guard   : Reservation_Guard;
   begin
      if not Within_Limit (Value) then
         Accepted := False;
      else
         Guard.Transferred := Queued'Unchecked_Access;
         Reserve (Item, Payload_Bytes (Value), Guard, Granted);
         if Granted then
            Item.Outbox.Try_Send (Value, Queued);
         end if;
         Accepted := Granted and then Queued;
      end if;
   end Try_Publish;

   procedure Close (Item : in out Session) is
   begin
      Item.Outbox.Close;
   end Close;

   function Cancelled (Item : Session) return Boolean is
     (Item.Stop.Requested);

   procedure Count_Connection
     (Metric_Output : access Metrics.Sink'Class) is
   begin
      if Metric_Output /= null then
         Metrics.Count (Metric_Output.all, Metrics.SSE_Connection);
      end if;
   exception
      when others => null;
   end Count_Connection;

   procedure Run
     (X             : in out Applications.Exchange;
      Item          : in out Session;
      Metric_Output : access Metrics.Sink'Class := null;
      Idle_Quantum  : Duration := 0.05;
      Heartbeat     : Duration := 15.0)
   is
      Value     : Event_Value;
      Available : Boolean;
      Timed_Out : Boolean;
      Last_Write : Ada.Real_Time.Time := Ada.Real_Time.Clock;

      procedure Check_Stop is
         Token : constant access Flyology.Cancellation.Token := X.Cancellation;
      begin
         if Token /= null and then Token.Requested then
            raise Flyology.Cancellation.Operation_Cancelled;
         elsif X.Remaining = 0.0 then
            raise Flyology.IO.Timeout_Error with
              "SSE request deadline expired";
         end if;
      end Check_Stop;
   begin
      if Idle_Quantum <= 0.0 or else Heartbeat < 0.0 then
         raise Constraint_Error with "invalid SSE idle timing";
      end if;
      Count_Connection (Metric_Output);
      X.Begin_SSE;
      loop
         Check_Stop;
         declare
            Left : constant Duration := X.Remaining;
            Wait : constant Duration :=
              (if Left < 0.0 then Idle_Quantum
               else Duration'Min (Idle_Quantum, Left));
         begin
            Item.Outbox.Receive_For
              (Value, Available, Wait, Timed_Out);
         end;
         if Timed_Out then
            Check_Stop;
            if Heartbeat > 0.0
              and then Ada.Real_Time.Clock - Last_Write >=
                Ada.Real_Time.To_Time_Span (Heartbeat)
            then
               --  Comments keep the connection observable without dispatching
               --  an empty application message in EventSource clients.
               X.Send_SSE_Comment;
               Last_Write := Ada.Real_Time.Clock;
            end if;
         end if;
         exit when not Available and then not Timed_Out;
         if Available then
            begin
               X.Send_SSE
                 (To_String (Value.Data), To_String (Value.Event),
                  To_String (Value.Id), Value.Retry,
                  Value.Include_Id, Value.Include_Retry);
            exception
               when others =>
                  Release_Retention (Item, Value);
                  raise;
            end;
            Release_Retention (Item, Value);
            Last_Write := Ada.Real_Time.Clock;
         end if;
      end loop;
      X.End_SSE;
   exception
      when others =>
         Item.Outbox.Close;
         Drain (Item);
         Item.Stop.Request;
         raise;
   end Run;

   overriding procedure Finalize (Item : in out Session) is
   begin
      Item.Outbox.Close;
      Drain (Item);
      Item.Stop.Request;
   end Finalize;

end Flyology.HTTP.Server.SSE_Handlers;
