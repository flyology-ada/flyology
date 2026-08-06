package body Flyology.HTTP.Server.Metrics is

   function Saturating_Add (Left, Right : Natural) return Natural is
     (if Right > Natural'Last - Left then Natural'Last else Left + Right);

   function Saturating_Add
     (Left, Right : Duration) return Duration is
     (if Right <= 0.0 then Left
      elsif Left > Duration'Last - Right then Duration'Last
      else Left + Right);

   function Status_Class (Status : Natural) return Natural is
     (if Status in 100 .. 599 then Status / 100 else 0);

   protected body Metric_State is
      procedure Begin_Request is
      begin
         Value.Active := Saturating_Add (Value.Active, 1);
      end Begin_Request;

      procedure End_Request
        (Method         : String;
         Route          : String;
         Status         : Natural;
         Elapsed        : Duration;
         Request_Bytes  : Natural;
         Response_Bytes : Natural)
      is
         Found : Natural := 0;
         Class : constant Natural := Status_Class (Status);
      begin
         if Value.Active > 0 then
            Value.Active := Value.Active - 1;
         end if;
         Value.Requests := Saturating_Add (Value.Requests, 1);
         Value.Request_Bytes :=
           Saturating_Add (Value.Request_Bytes, Request_Bytes);
         Value.Response_Bytes :=
           Saturating_Add (Value.Response_Bytes, Response_Bytes);
         Value.Latency_Total :=
           Saturating_Add (Value.Latency_Total, Elapsed);
         Value.Latency_Max := Duration'Max (Value.Latency_Max, Elapsed);

         if Route'Length > Max_Route_Length
           or else Method'Length > Max_Method_Length
         then
            Value.Dropped_Series :=
              Saturating_Add (Value.Dropped_Series, 1);
            return;
         end if;
         for Index in 1 .. Value.Series loop
            if Values (Index).Route_Length = Route'Length
              and then Values (Index).Method_Length = Method'Length
              and then Values (Index).Status_Class = Class
              and then Values (Index).Route (1 .. Route'Length) = Route
              and then Values (Index).Method (1 .. Method'Length) = Method
            then
               Found := Index;
               exit;
            end if;
         end loop;
         if Found = 0 then
            if Value.Series = Capacity then
               Value.Dropped_Series :=
                 Saturating_Add (Value.Dropped_Series, 1);
               return;
            end if;
            Value.Series := Value.Series + 1;
            Found := Value.Series;
            Values (Found).Used := True;
            Values (Found).Route_Length := Route'Length;
            Values (Found).Method_Length := Method'Length;
            Values (Found).Status_Class := Class;
            if Route'Length > 0 then
               Values (Found).Route (1 .. Route'Length) := Route;
            end if;
            if Method'Length > 0 then
               Values (Found).Method (1 .. Method'Length) := Method;
            end if;
         end if;
         Values (Found).Requests :=
           Saturating_Add (Values (Found).Requests, 1);
      end End_Request;

      procedure Count (Kind : Event_Kind) is
      begin
         Value.Events (Kind) := Saturating_Add (Value.Events (Kind), 1);
      end Count;

      function Read return Snapshot is (Value);
   end Metric_State;

   overriding procedure Begin_Request (Item : in out In_Memory) is
   begin
      Item.State.Begin_Request;
   end Begin_Request;

   overriding procedure End_Request
     (Item           : in out In_Memory;
      Method         : String;
      Route          : String;
      Status         : Natural;
      Elapsed        : Duration;
      Request_Bytes  : Natural;
      Response_Bytes : Natural)
   is
   begin
      Item.State.End_Request
        (Method, Route, Status, Elapsed, Request_Bytes, Response_Bytes);
   end End_Request;

   overriding procedure Count
     (Item : in out In_Memory;
      Kind : Event_Kind)
   is
   begin
      Item.State.Count (Kind);
   end Count;

   function Read (Item : In_Memory) return Snapshot is (Item.State.Read);

end Flyology.HTTP.Server.Metrics;
