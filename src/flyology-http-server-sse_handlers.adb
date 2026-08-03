package body Flyology.HTTP.Server.SSE_Handlers is
   procedure Publish
     (Item     : in out Session;
      Value    : Event_Value;
      Accepted : out Boolean) is
   begin
      Item.Outbox.Send (Value, Accepted);
   end Publish;

   procedure Try_Publish
     (Item     : in out Session;
      Value    : Event_Value;
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
      Metric_Output : access Metrics.Sink'Class := null)
   is
      Value     : Event_Value;
      Available : Boolean;
   begin
      Count_Connection (Metric_Output);
      X.Begin_SSE;
      loop
         Item.Outbox.Receive (Value, Available);
         exit when not Available;
         X.Send_SSE
           (To_String (Value.Data), To_String (Value.Event),
            To_String (Value.Id), Value.Retry);
      end loop;
      X.End_SSE;
   exception
      when others =>
         Item.Outbox.Close;
         Item.Stop.Request;
         raise;
   end Run;

end Flyology.HTTP.Server.SSE_Handlers;
