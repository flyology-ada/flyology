--  Defines application-neutral HTTP metrics and a bounded in-memory sink.
package Flyology.HTTP.Server.Metrics is

   --  Bounded failure dimensions.
   --  @enum Timeout Request deadline expired
   --  @enum Cancellation Request cancellation was observed
   --  @enum Protocol HTTP protocol validation failed
   --  @enum Ingress_Denial Shared ingress budget denied buffering
   --  @enum Rate_Limit_Denial Rate limiter rejected work
   --  @enum Bulkhead_Denial Concurrency limit rejected work
   --  @enum SSE_Connection SSE lifecycle event
   --  @enum WebSocket_Connection WebSocket lifecycle event
   --  @enum WebSocket_Message WebSocket message event
   type Event_Kind is
     (Timeout,
      Cancellation,
      Protocol,
      Ingress_Denial,
      Rate_Limit_Denial,
      Bulkhead_Denial,
      SSE_Connection,
      WebSocket_Connection,
      WebSocket_Message);

   --  Counter array indexed by bounded event kind.
   type Event_Counters is array (Event_Kind) of Natural;

   --  Application-neutral thread-safe metric sink. Implementations must not
   --  retain borrowed strings and should not raise from callbacks.
   type Sink is limited interface;

   --  Increment active requests.
   --  @param Item Metric sink
   procedure Begin_Request (Item : in out Sink) is abstract;

   --  Complete one request observation.
   --  @param Item Metric sink
   --  @param Method Request method
   --  @param Route Stable route name, never an arbitrary raw path
   --  @param Status Final status or zero
   --  @param Elapsed Monotonic elapsed seconds
   --  @param Request_Bytes Decoded request body bytes
   --  @param Response_Bytes Response payload bytes
   procedure End_Request
     (Item           : in out Sink;
      Method         : String;
      Route          : String;
      Status         : Natural;
      Elapsed        : Duration;
      Request_Bytes  : Natural;
      Response_Bytes : Natural) is abstract;

   --  Increment one bounded failure or lifecycle event.
   --  @param Item Metric sink
   --  @param Kind Event kind
   procedure Count (Item : in out Sink; Kind : Event_Kind) is abstract;

   --  Aggregate in-memory metric snapshot.
   --  @field Active Current active requests
   --  @field Requests Completed requests
   --  @field Request_Bytes Total decoded request bytes
   --  @field Response_Bytes Total response payload bytes
   --  @field Latency_Total Sum of observed latency
   --  @field Latency_Max Maximum observed latency
   --  @field Series Number of bounded route/method/status-class series
   --  @field Dropped_Series New series discarded after capacity
   --  @field Events Bounded event counters
   type Snapshot is record
      Active         : Natural;
      Requests       : Natural;
      Request_Bytes  : Natural;
      Response_Bytes : Natural;
      Latency_Total  : Duration;
      Latency_Max    : Duration;
      Series         : Natural;
      Dropped_Series : Natural;
      Events         : Event_Counters;
   end record;

   --  Default bounded-cardinality in-memory metric sink. Capacity is the
   --  maximum route/method/status-class series.
   type In_Memory (Capacity : Positive := 256) is
     limited new Sink with private;

   --  Increment active requests in the in-memory sink.
   --  @param Item In-memory sink
   overriding procedure Begin_Request (Item : in out In_Memory);

   --  Complete one in-memory request observation.
   --  @param Item In-memory sink
   --  @param Method Request method
   --  @param Route Stable route name
   --  @param Status Final status or zero
   --  @param Elapsed Monotonic elapsed seconds
   --  @param Request_Bytes Decoded request body bytes
   --  @param Response_Bytes Response payload bytes
   overriding procedure End_Request
     (Item           : in out In_Memory;
      Method         : String;
      Route          : String;
      Status         : Natural;
      Elapsed        : Duration;
      Request_Bytes  : Natural;
      Response_Bytes : Natural);

   --  Increment one bounded in-memory event counter.
   --  @param Item In-memory sink
   --  @param Kind Event kind
   overriding procedure Count
     (Item : in out In_Memory;
      Kind : Event_Kind);

   --  Read an atomic aggregate snapshot.
   --  @param Item In-memory sink
   --  @return Current counters
   function Read (Item : In_Memory) return Snapshot;

private
   Max_Route_Length  : constant := 128;
   Max_Method_Length : constant := 16;

   type Series_Entry is record
      Used          : Boolean := False;
      Route         : String (1 .. Max_Route_Length) := (others => ' ');
      Route_Length  : Natural := 0;
      Method        : String (1 .. Max_Method_Length) := (others => ' ');
      Method_Length : Natural := 0;
      Status_Class  : Natural range 0 .. 5 := 0;
      Requests      : Natural := 0;
   end record;
   type Series_Array is array (Positive range <>) of Series_Entry;

   protected type Metric_State (Capacity : Positive) is
      procedure Begin_Request;
      procedure End_Request
        (Method         : String;
         Route          : String;
         Status         : Natural;
         Elapsed        : Duration;
         Request_Bytes  : Natural;
         Response_Bytes : Natural);
      procedure Count (Kind : Event_Kind);
      function Read return Snapshot;
   private
      Value  : Snapshot :=
        (Active => 0, Requests => 0, Request_Bytes => 0,
         Response_Bytes => 0, Latency_Total => 0.0, Latency_Max => 0.0,
         Series => 0, Dropped_Series => 0, Events => (others => 0));
      Values : Series_Array (1 .. Capacity);
   end Metric_State;

   type In_Memory (Capacity : Positive := 256) is
     limited new Sink with record
      State : Metric_State (Capacity);
   end record;

end Flyology.HTTP.Server.Metrics;
