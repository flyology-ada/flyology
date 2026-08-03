with Ada.Real_Time;
with Ada.Strings;
with Ada.Strings.Fixed;
with Flyology.IO;

package body Flyology.HTTP.Server.WebSocket_Handlers is
   use type Ada.Real_Time.Time;

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
            raise Program_Error with
              "WebSocket session byte budget underflow";
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

   function Payload_Bytes (Value : Outgoing_Message) return Natural is
     (Length (Value.Data));

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
     (Item : in out Session; Value : Outgoing_Message)
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
      Value     : Outgoing_Message;
      Available : Boolean;
   begin
      loop
         Item.Outbox.Try_Receive (Value, Available);
         exit when not Available;
         Release_Retention (Item, Value);
      end loop;
   end Drain;

   procedure Publish
     (Item     : in out Session;
      Value    : Outgoing_Message;
      Accepted : out Boolean) is
      Queued  : aliased Boolean := False;
      Granted : Boolean;
      Guard   : Reservation_Guard;
   begin
      if Length (Value.Data) > Max_Queued_Message_Bytes then
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
      Value     : Outgoing_Message;
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
      if Length (Value.Data) > Max_Queued_Message_Bytes then
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
      Value    : Outgoing_Message;
      Accepted : out Boolean) is
      Queued  : aliased Boolean := False;
      Granted : Boolean;
      Guard   : Reservation_Guard;
   begin
      if Length (Value.Data) > Max_Queued_Message_Bytes then
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

   procedure Count
     (Metric_Output : access Metrics.Sink'Class;
      Event         : Metrics.Event_Kind) is
   begin
      if Metric_Output /= null then
         Metrics.Count (Metric_Output.all, Event);
      end if;
   exception
      when others => null;
   end Count;

   procedure Run
     (X              : in out Applications.Exchange;
      Item           : in out Session;
      Open           : access procedure
        (X : in out Applications.Exchange; Item : in out Session) := null;
      Message        : access procedure
        (X    : in out Applications.Exchange;
         Item : in out Session;
         Kind : WebSocket_Data_Kind;
         Data : String) := null;
      Closed         : access procedure
        (X : in out Applications.Exchange; Item : in out Session) := null;
      Protocol       : String := "";
      Origin_Policy  : WebSocket_Origin_Policy := Reject_Browser_Origins;
      Allowed_Origin : String := "";
      Max_Message    : Natural := Max_WebSocket_Frame;
      Receive_Quantum : Duration := 0.05;
      Max_Outgoing_Burst : Positive := 16;
      Metric_Output  : access Metrics.Sink'Class := null)
   is
      Outgoing  : Outgoing_Message;
      Available : Boolean;
      Kind      : WebSocket_Data_Kind;
      Data      : Unbounded_String;
      Peer_Closed : Boolean := False;
      Close_Called : Boolean := False;
      Outgoing_Burst : Natural := 0;
   begin
      if Receive_Quantum <= 0.0 then
         raise Constraint_Error with
           "WebSocket receive quantum must be positive";
      end if;
      Count (Metric_Output, Metrics.WebSocket_Connection);
      if Ada.Strings.Fixed.Trim
        (X.Request_Header ("Sec-WebSocket-Version"), Ada.Strings.Both) /= "13"
      then
         X.Add_Header ("Sec-WebSocket-Version", "13");
         X.Problem
           (426, "websocket-version", "WebSocket version 13 is required");
         Item.Outbox.Close;
         Item.Stop.Request;
         return;
      end if;
      X.Accept_WebSocket (Protocol, Origin_Policy, Allowed_Origin);
      if Open /= null then
         Open.all (X, Item);
      end if;

      loop
         if Outgoing_Burst < Max_Outgoing_Burst then
            Item.Outbox.Try_Receive (Outgoing, Available);
         else
            Available := False;
         end if;
         if Available then
            begin
               X.Send_WebSocket (Outgoing.Kind, To_String (Outgoing.Data));
            exception
               when others =>
                  Release_Retention (Item, Outgoing);
                  raise;
            end;
            Release_Retention (Item, Outgoing);
            Count (Metric_Output, Metrics.WebSocket_Message);
            Outgoing_Burst := Outgoing_Burst + 1;
         elsif Item.Outbox.Is_Closed and then Item.Outbox.Length = 0 then
            X.Close_WebSocket;
            exit;
         else
            begin
               X.Receive_WebSocket
                 (Kind, Data, Peer_Closed, Max_Message, Receive_Quantum);
               if Peer_Closed then
                  X.Complete_WebSocket;
                  exit;
               end if;
               Count (Metric_Output, Metrics.WebSocket_Message);
               Outgoing_Burst := 0;
               if Message /= null then
                  Message.all (X, Item, Kind, To_String (Data));
               end if;
            exception
               when Flyology.IO.Timeout_Error =>
                  if X.Remaining = 0.0 then
                     raise;
                  end if;
                  Outgoing_Burst := 0;
            end;
         end if;
      end loop;

      Item.Outbox.Close;
      Drain (Item);
      Item.Stop.Request;
      if Closed /= null then
         Close_Called := True;
         Closed.all (X, Item);
      end if;
   exception
      when others =>
         Item.Outbox.Close;
         Drain (Item);
         Item.Stop.Request;
         if Closed /= null and then not Close_Called then
            begin
               Close_Called := True;
               Closed.all (X, Item);
            exception
               when others => null;
            end;
         end if;
         raise;
   end Run;

   overriding procedure Finalize (Item : in out Session) is
   begin
      Item.Outbox.Close;
      Drain (Item);
      Item.Stop.Request;
   end Finalize;

end Flyology.HTTP.Server.WebSocket_Handlers;
