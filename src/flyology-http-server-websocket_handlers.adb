with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;
with Flyology.IO;
with Interfaces;

package body Flyology.HTTP.Server.WebSocket_Handlers is
   use type Ada.Real_Time.Time;
   use type Interfaces.Unsigned_64;
   use type Buffer_Channels.Try_Receive_Result;
   use type Buffer_Channels.Try_Send_Result;

   procedure Free is new Ada.Unchecked_Deallocation
     (Buffer_Channels.Channel, Buffer_Channel_Access);

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
      Moved           : access Flyology.Buffers.Unique_Buffer;
   end record;

   overriding procedure Finalize (Item : in out Reservation_Guard) is
      Ownership_Transferred : constant Boolean :=
        (Item.Transferred /= null and then Item.Transferred.all)
        or else
          (Item.Moved /= null
           and then not Flyology.Buffers.Has_Buffer (Item.Moved.all));
   begin
      if not Ownership_Transferred then
         if Item.Shared_Reserved then
            Release (Item.Shared.all, Item.Bytes);
         end if;
         if Item.Local_Reserved then
            Item.Owner.Bytes.Release (Item.Bytes);
         end if;
      end if;
   end Finalize;

   function Payload_Bytes (Value : Outgoing_Message) return Natural is
     (Flyology.Bytes.Length (Value.Data));

   procedure Require_Value_Outbox (Item : Session) is
   begin
      if Item.Buffer_Pool /= null then
         raise Program_Error with
           "WebSocket session is configured for moved buffers";
      end if;
   end Require_Value_Outbox;

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

   procedure Release_Retention
     (Item : in out Session; Value : Flyology.Buffers.Unique_Buffer)
   is
      Bytes : constant Natural := Flyology.Buffers.Length (Value);
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
      if Item.Buffer_Pool /= null then
         declare
            Buffered : Flyology.Buffers.Unique_Buffer (Item.Buffer_Pool);
            Result   : Buffer_Channels.Try_Receive_Result;
         begin
            loop
               Item.Buffer_Outbox.Try_Receive_Move (Buffered, Result);
               exit when Result /= Buffer_Channels.Item_Received;
               Release_Retention (Item, Buffered);
               Flyology.Buffers.Release (Buffered);
            end loop;
         end;
      end if;
   end Drain;

   procedure Publish
     (Item     : in out Session;
      Value    : Outgoing_Message;
      Accepted : out Boolean) is
      Queued  : aliased Boolean := False;
      Granted : Boolean;
      Guard   : Reservation_Guard;
   begin
      Require_Value_Outbox (Item);
      if Flyology.Bytes.Length (Value.Data) > Max_Queued_Message_Bytes then
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
      Require_Value_Outbox (Item);
      if Flyology.Bytes.Length (Value.Data) > Max_Queued_Message_Bytes then
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
      Require_Value_Outbox (Item);
      if Flyology.Bytes.Length (Value.Data) > Max_Queued_Message_Bytes then
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

   procedure Require_Buffer_Outbox (Item : Session) is
   begin
      if Item.Buffer_Pool = null then
         raise Program_Error with
           "WebSocket session has no configured buffer pool";
      end if;
   end Require_Buffer_Outbox;

   procedure Publish_Move
     (Item     : in out Session;
      Kind     : WebSocket_Data_Kind;
      Value    : in out Flyology.Buffers.Unique_Buffer;
      Accepted : out Boolean)
   is
      Queued  : aliased Boolean := False;
      Granted : Boolean;
      Guard   : Reservation_Guard;
   begin
      Accepted := False;
      Require_Buffer_Outbox (Item);
      if Flyology.Buffers.Length (Value) > Max_Queued_Message_Bytes then
         return;
      end if;
      Guard.Transferred := Queued'Unchecked_Access;
      Guard.Moved := Value'Unchecked_Access;
      Reserve (Item, Flyology.Buffers.Length (Value), Guard, Granted);
      if Granted then
         begin
            Item.Buffer_Outbox.Send_Move
              (Value,
               Buffer_Channels.Transfer_Metadata
                 (WebSocket_Data_Kind'Pos (Kind)));
            Queued := True;
         exception
            when Buffer_Channels.Channel_Closed => null;
         end;
      end if;
      Accepted := Granted and then Queued;
   end Publish_Move;

   procedure Publish_Move_For
     (Item      : in out Session;
      Kind      : WebSocket_Data_Kind;
      Value     : in out Flyology.Buffers.Unique_Buffer;
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
      Require_Buffer_Outbox (Item);
      if Flyology.Buffers.Length (Value) > Max_Queued_Message_Bytes then
         return;
      end if;
      Guard.Transferred := Queued'Unchecked_Access;
      Guard.Moved := Value'Unchecked_Access;
      Reserve (Item, Flyology.Buffers.Length (Value), Guard, Granted);
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
         begin
            Item.Buffer_Outbox.Timed_Send_Move
              (Value,
               (if Left < 0.0 then 0.05 else Duration'Min (Left, 0.05)),
               Buffer_Channels.Transfer_Metadata
                 (WebSocket_Data_Kind'Pos (Kind)));
            Queued := True;
            Accepted := True;
            Timed_Out := False;
            return;
         exception
            when Buffer_Channels.Channel_Closed =>
               Timed_Out := False;
               return;
            when Buffer_Channels.Timeout_Error =>
               Timed_Out := True;
         end;
         if Timeout >= 0.0 then
            Left := Timeout - Ada.Real_Time.To_Duration
              (Ada.Real_Time.Clock - Started);
            if Left <= 0.0 then
               return;
            end if;
         end if;
      end loop;
   end Publish_Move_For;

   procedure Try_Publish_Move
     (Item     : in out Session;
      Kind     : WebSocket_Data_Kind;
      Value    : in out Flyology.Buffers.Unique_Buffer;
      Accepted : out Boolean)
   is
      Queued  : aliased Boolean := False;
      Granted : Boolean;
      Guard   : Reservation_Guard;
      Result  : Buffer_Channels.Try_Send_Result;
   begin
      Accepted := False;
      Require_Buffer_Outbox (Item);
      if Flyology.Buffers.Length (Value) > Max_Queued_Message_Bytes then
         return;
      end if;
      Guard.Transferred := Queued'Unchecked_Access;
      Guard.Moved := Value'Unchecked_Access;
      Reserve (Item, Flyology.Buffers.Length (Value), Guard, Granted);
      if Granted then
         Item.Buffer_Outbox.Try_Send_Move
           (Value,
            Result,
            Buffer_Channels.Transfer_Metadata
              (WebSocket_Data_Kind'Pos (Kind)));
         Queued := Result = Buffer_Channels.Item_Sent;
      end if;
      Accepted := Granted and then Queued;
   end Try_Publish_Move;

   procedure Close (Item : in out Session) is
   begin
      Item.Outbox.Close;
      if Item.Buffer_Pool /= null then
         Item.Buffer_Outbox.Close;
      end if;
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
         Data : Flyology.Bytes.Unbounded_Bytes) := null;
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
      Data      : Flyology.Bytes.Unbounded_Bytes;
      Peer_Closed : Boolean := False;
      Close_Called : Boolean := False;
      Outgoing_Burst : Natural := 0;

      function Selected_Outbox_Drained return Boolean is
      begin
         if Item.Buffer_Pool = null then
            return Item.Outbox.Is_Closed and then Item.Outbox.Length = 0;
         end if;
         declare
            State : constant Buffer_Channels.Snapshot :=
              Item.Buffer_Outbox.Current;
         begin
            return State.Closed and then State.Pending = 0;
         end;
      end Selected_Outbox_Drained;

      procedure Send_One_Value (Sent : out Boolean) is
      begin
         Item.Outbox.Try_Receive (Outgoing, Sent);
         if Sent then
            begin
               X.Send_WebSocket
                 (Outgoing.Kind, Flyology.Bytes.To_Array (Outgoing.Data));
            exception
               when others =>
                  Release_Retention (Item, Outgoing);
                  raise;
            end;
            Release_Retention (Item, Outgoing);
         end if;
      end Send_One_Value;

      procedure Send_One_Buffer (Sent : out Boolean) is
         Buffered : Flyology.Buffers.Unique_Buffer (Item.Buffer_Pool);
         Result   : Buffer_Channels.Try_Receive_Result;
         Metadata : Buffer_Channels.Transfer_Metadata;
      begin
         Item.Buffer_Outbox.Try_Receive_Move
           (Buffered, Result, Metadata);
         Sent := Result = Buffer_Channels.Item_Received;
         if Sent then
            declare
               Position : constant Interfaces.Unsigned_64 := Metadata;
               Buffered_Kind : WebSocket_Data_Kind;
               procedure Send_Buffer
                 (Payload : Ada.Streams.Stream_Element_Array) is
               begin
                  X.Send_WebSocket (Buffered_Kind, Payload);
               end Send_Buffer;
            begin
               if Position > Interfaces.Unsigned_64
                 (WebSocket_Data_Kind'Pos (WebSocket_Data_Kind'Last))
               then
                  raise Program_Error with
                    "invalid queued WebSocket buffer kind";
               end if;
               Buffered_Kind := WebSocket_Data_Kind'Val (Position);
               Flyology.Buffers.With_Readable_Data
                 (Buffered, Send_Buffer'Access);
            exception
               when others =>
                  Release_Retention (Item, Buffered);
                  raise;
            end;
            Release_Retention (Item, Buffered);
         end if;
      end Send_One_Buffer;
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
         Close (Item);
         Drain (Item);
         Item.Stop.Request;
         return;
      end if;
      X.Accept_WebSocket (Protocol, Origin_Policy, Allowed_Origin);
      if Open /= null then
         Open.all (X, Item);
      end if;

      loop
         if Outgoing_Burst < Max_Outgoing_Burst then
            if Item.Buffer_Pool = null then
               Send_One_Value (Available);
            else
               Send_One_Buffer (Available);
            end if;
         else
            Available := False;
         end if;
         if Available then
            Count (Metric_Output, Metrics.WebSocket_Message);
            Outgoing_Burst := Outgoing_Burst + 1;
         elsif Selected_Outbox_Drained then
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
                  Message.all (X, Item, Kind, Data);
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

      Close (Item);
      Drain (Item);
      Item.Stop.Request;
      if Closed /= null then
         Close_Called := True;
         Closed.all (X, Item);
      end if;
   exception
      when others =>
         Close (Item);
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
      if Item.Buffer_Pool /= null then
         Item.Buffer_Outbox.Close;
      end if;
      Drain (Item);
      Free (Item.Buffer_Outbox);
      Item.Stop.Request;
   end Finalize;

end Flyology.HTTP.Server.WebSocket_Handlers;
