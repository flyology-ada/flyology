with Flyology.IO;

package body Flyology.HTTP.Server.WebSocket_Handlers is
   procedure Publish
     (Item     : in out Session;
      Value    : Outgoing_Message;
      Accepted : out Boolean) is
   begin
      Item.Outbox.Send (Value, Accepted);
   end Publish;

   procedure Try_Publish
     (Item     : in out Session;
      Value    : Outgoing_Message;
      Accepted : out Boolean) is
   begin
      Item.Outbox.Try_Send (Value, Accepted);
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
      Open           : Open_Handler := null;
      Message        : Message_Handler := null;
      Closed         : Close_Handler := null;
      Protocol       : String := "";
      Origin_Policy  : WebSocket_Origin_Policy := Reject_Browser_Origins;
      Allowed_Origin : String := "";
      Max_Message    : Natural := Max_WebSocket_Frame;
      Receive_Quantum : Duration := 0.05;
      Metric_Output  : access Metrics.Sink'Class := null)
   is
      Outgoing  : Outgoing_Message;
      Available : Boolean;
      Kind      : WebSocket_Data_Kind;
      Data      : Unbounded_String;
      Peer_Closed : Boolean := False;
      Close_Called : Boolean := False;
   begin
      if Receive_Quantum <= 0.0 then
         raise Constraint_Error with
           "WebSocket receive quantum must be positive";
      end if;
      Count (Metric_Output, Metrics.WebSocket_Connection);
      X.Accept_WebSocket (Protocol, Origin_Policy, Allowed_Origin);
      if Open /= null then
         Open.all (X, Item);
      end if;

      loop
         Item.Outbox.Try_Receive (Outgoing, Available);
         if Available then
            X.Send_WebSocket (Outgoing.Kind, To_String (Outgoing.Data));
            Count (Metric_Output, Metrics.WebSocket_Message);
         elsif Item.Outbox.Is_Closed then
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
               if Message /= null then
                  Message.all (X, Item, Kind, To_String (Data));
               end if;
            exception
               when Flyology.IO.Timeout_Error =>
                  if X.Remaining = 0.0 then
                     raise;
                  end if;
            end;
         end if;
      end loop;

      Item.Outbox.Close;
      Item.Stop.Request;
      if Closed /= null then
         Close_Called := True;
         Closed.all (X, Item);
      end if;
   exception
      when others =>
         Item.Outbox.Close;
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

end Flyology.HTTP.Server.WebSocket_Handlers;
