with Ada.Finalization;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Flyology.Bytes;
with Flyology.Cancellation;
with Flyology.HTTP.Headers;
with Flyology.IO.TLS;

--  Provides an origin-bound synchronous HTTP client with bounded connection
--  pooling. Lightweight callers suspend on Flyology I/O; native callers block
--  only their pthread. HTTP/1.1 is the initial protocol engine, while the
--  request/response API does not expose connection ownership.
package Flyology.HTTP.Client is

   --  Raised after client shutdown rejects a request or interrupts pool
   --  admission.
   Client_Closed : exception;
   --  Raised when the origin cannot be resolved or every resolved address
   --  fails before an HTTP exchange starts.
   Connection_Error : exception;
   --  Raised when retained response metadata or a Read_All body exceeds its
   --  bound.
   Response_Too_Large : exception;

   --  Pool reuse and retention policy. Capacity remains the Client
   --  discriminant and bounds open plus connecting slots.
   --  @field Max_Idle Maximum reusable connections retained, capped by client
   --     capacity; zero disables reuse without disabling concurrent requests
   --  @field Idle_Timeout Seconds an unused connection may remain reusable;
   --     negative disables the age check
   --  @field Max_Connection_Age Total reusable lifetime in seconds; negative
   --     disables the age check
   --  @field Max_Requests_Per_Connection Total requests before rotation; zero
   --     disables request-count rotation
   type Pool_Configuration is record
      Max_Idle                   : Natural := 1;
      Idle_Timeout               : Duration := 30.0;
      Max_Connection_Age         : Duration := 300.0;
      Max_Requests_Per_Connection : Natural := 0;
   end record;

   --  Default conservative pool policy.
   Default_Pool_Configuration : constant Pool_Configuration := (others => <>);

   --  Coherent client counters. Exchange and transport counts are separate so
   --  a later multiplexed protocol can report several exchanges on one
   --  transport without changing this record's meaning.
   --  @field Transport_Capacity Configured transport slot bound
   --  @field Pending_Transports Transports being established
   --  @field Active_Exchanges Requests that own protocol exchanges
   --  @field Reusable_Transports Established transports eligible for reuse
   --  @field Closing_Transports Transports being closed outside the pool lock
   --  @field Admission_Waiters Requests waiting for exchange capacity
   --  @field Transports_Created Successfully established transports
   --  @field Transport_Reuses Exchanges assigned an existing transport
   --  @field Transports_Closed Transports removed from the client
   --  @field Stale_Retries Idempotent exchanges retried once after an existing
   --     transport failed before producing response bytes
   --  @field Admission_Timeouts Pool waits whose request deadline expired
   type Client_Diagnostics is record
      Transport_Capacity : Positive;
      Pending_Transports : Natural;
      Active_Exchanges    : Natural;
      Reusable_Transports : Natural;
      Closing_Transports  : Natural;
      Admission_Waiters   : Natural;
      Transports_Created  : Natural;
      Transport_Reuses    : Natural;
      Transports_Closed   : Natural;
      Stale_Retries       : Natural;
      Admission_Timeouts  : Natural;
   end record;

   --  Mutable request value. Bodies are retained as owned bytes so request
   --  transmission remains valid across task suspension.
   type Request is private;

   --  Replace the request method.
   --  @param Item Request to change
   --  @param Value Validated method
   procedure Set_Method (Item : in out Request; Value : Method);

   --  Replace the origin-form request target. Asterisk-form is retained for
   --  OPTIONS and validated when Execute observes the complete Request.
   --  Absolute-form, authority-form, fragments, non-ASCII bytes, spaces,
   --  control characters, and targets over 8 KiB are rejected.
   --  @param Item Request to change
   --  @param Value Origin-form target
   --  @exception Constraint_Error Value is not a supported request target
   procedure Set_Target (Item : in out Request; Value : String);

   --  Append one end-to-end request field. Framing, connection, upgrade, and
   --  Expect fields are client-controlled and rejected here.
   --  @param Item Request to change
   --  @param Name Field name
   --  @param Value Field value
   procedure Add_Header
     (Item : in out Request; Name : String; Value : String);

   --  Replace the request body using a one-to-one byte mapping.
   --  @param Item Request to change
   --  @param Value Request representation bytes
   procedure Set_Body (Item : in out Request; Value : String);

   --  Replace the request body from contiguous bytes.
   --  @param Item Request to change
   --  @param Value Request representation bytes
   procedure Set_Body
     (Item : in out Request; Value : Ada.Streams.Stream_Element_Array);

   --  Origin-bound client. Capacity is the maximum number of open plus
   --  connecting transports. Configure must complete before concurrent use.
   --  Finalize requests shutdown and closes transports. Execute's aliased
   --  controlling parameter lets Ada accessibility reject a response that
   --  would escape Item's lifetime. Internal retention also protects cleanup
   --  during abort and finalization races. Application TLS providers and
   --  cancellation tokens must satisfy their separately documented lifetimes.
   type Client (Capacity : Positive := 4) is limited private;

   --  Bind a new client to one origin and immutable pool policy. The call does
   --  no DNS, socket, TLS, task, or event-loop work. Reconfiguration and an
   --  HTTPS origin without a backend are rejected.
   --  @param Item Unconfigured client
   --  @param Origin_Value Normalized origin
   --  @param Pool Pool retention policy
   --  @exception Program_Error Item is configured or arguments are invalid
   procedure Configure
     (Item         : in out Client;
      Origin_Value : Origin;
      Pool         : Pool_Configuration := Default_Pool_Configuration);

   --  Bind a new client to one origin using an explicit TLS provider. Backend
   --  must outlive Item. This overload is required for HTTPS and is also
   --  accepted for HTTP so callers may share configuration code.
   --  @param Item Unconfigured client
   --  @param Origin_Value Normalized origin
   --  @param Backend TLS provider retained by Item
   --  @param Pool Pool retention policy
   --  @exception Program_Error Item is configured or arguments are invalid
   procedure Configure
     (Item         : in out Client;
      Origin_Value : Origin;
      Backend      : not null access Flyology.IO.TLS.Provider'Class;
      Pool         : Pool_Configuration := Default_Pool_Configuration);

   --  Limited response owning one exchange lease until its body is consumed.
   --  Reading the complete body returns a reusable connection to the pool.
   --  Finalizing an incomplete response closes it without draining.
   type Response is limited private;

   --  Execute one request. One monotonic Timeout starts before pool admission
   --  and covers admission, DNS, all address attempts, TLS, request send, the
   --  response head, and later body reads. Negative is unlimited and zero is
   --  immediate. Token must outlive the returned Response when nonnull.
   --  @param Item Shared configured client that outlives the result
   --  @param Value Request to execute
   --  @param Timeout Whole-exchange deadline interval
   --  @param Token Optional cancellation source
   --  An idempotent request assigned a reused transport is retried once when
   --  that transport fails before any response byte is received. The retry
   --  remains inside the original deadline. Non-idempotent requests are never
   --  retried automatically.
   --  @return Response head with a streaming body lease
   --  @exception Client_Closed Client is stopping
   --  @exception Connection_Error Resolution or all address attempts fail
   --  @exception Constraint_Error Request fields, target, or method-body
   --     combination is unsupported; CONNECT is not implemented
   --  @exception Protocol_Error Response framing is malformed or unsupported
   --  @exception Response_Too_Large Response head exceeds its bound
   --  @exception Flyology.IO.Timeout_Error Whole-exchange deadline expires
   --  @exception Flyology.Cancellation.Operation_Cancelled Token is requested
   function Execute
     (Item    : aliased in out Client;
      Value   : Request;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null) return Response;

   --  Return the final response status.
   --  @param Item Response to inspect
   --  @return Three-digit status
   function Status (Item : Response) return Status_Code;

   --  Return the final response reason phrase. HTTP/2 and later protocols may
   --  return an empty string because they do not carry one.
   --  @param Item Response to inspect
   --  @return Preserved HTTP/1.x reason phrase after its status separator
   function Reason_Phrase (Item : Response) return String;

   --  Return the negotiated protocol.
   --  @param Item Response to inspect
   --  @return HTTP_1_1_Protocol in the initial implementation
   function Negotiated_Protocol (Item : Response) return Protocol;

   --  Count physical response fields with a case-insensitive name.
   --  @param Item Response to inspect
   --  @param Name Field name
   --  @return Physical occurrence count
   function Header_Count (Item : Response; Name : String) return Natural;

   --  Return the number of physical response fields.
   --  @param Item Response to inspect
   --  @return Field count
   function Header_Count (Item : Response) return Natural;

   --  Return one response field name by wire order.
   --  @param Item Response to inspect
   --  @param Index One-based physical field index
   --  @return Preserved field name, or empty when absent
   function Header_Name (Item : Response; Index : Positive) return String;

   --  Return one response field value by wire order.
   --  @param Item Response to inspect
   --  @param Index One-based physical field index
   --  @return Preserved field value, or empty when absent
   function Header_Value (Item : Response; Index : Positive) return String;

   --  Return one physical response field occurrence.
   --  @param Item Response to inspect
   --  @param Name Field name
   --  @param Occurrence One-based occurrence
   --  @return Field value or empty when absent
   function Header
     (Item : Response; Name : String; Occurrence : Positive := 1)
      return String;

   --  Count completed chunked trailer fields with a case-insensitive name.
   --  @param Item Response whose body has completed
   --  @param Name Trailer name
   --  @return Physical occurrence count
   function Trailer_Count (Item : Response; Name : String) return Natural;

   --  Return the number of physical trailer fields available after body
   --  completion.
   --  @param Item Response to inspect
   --  @return Trailer field count
   function Trailer_Count (Item : Response) return Natural;

   --  Return one trailer field name by wire order.
   --  @param Item Response to inspect
   --  @param Index One-based physical field index
   --  @return Preserved trailer name, or empty when absent
   function Trailer_Name (Item : Response; Index : Positive) return String;

   --  Return one trailer field value by wire order.
   --  @param Item Response to inspect
   --  @param Index One-based physical field index
   --  @return Preserved trailer value, or empty when absent
   function Trailer_Value (Item : Response; Index : Positive) return String;

   --  Return one completed chunked trailer occurrence.
   --  @param Item Response whose body has completed
   --  @param Name Trailer name
   --  @param Occurrence One-based occurrence
   --  @return Trailer value or empty when absent
   function Trailer
     (Item : Response; Name : String; Occurrence : Positive := 1)
      return String;

   --  Stream decoded response representation bytes. Fixed-length and chunked
   --  framing are removed. Last is Data'First - 1 when no bytes are produced.
   --  Finished becomes true only after complete framing; that transition
   --  releases or closes the underlying connection. The Execute deadline and
   --  token remain authoritative and are never restarted.
   --  @param Item Active response
   --  @param Data Caller-owned destination
   --  @param Last Last decoded byte, or Data'First - 1
   --  @param Finished Whether response framing is complete
   procedure Read_Body
     (Item     : in out Response;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean);

   --  Report whether body framing is complete and no connection lease remains.
   --  @param Item Response to inspect
   --  @return True after complete body consumption
   function Body_Complete (Item : Response) return Boolean;

   --  Read the complete remaining body into owned storage under the original
   --  deadline. Maximum bounds decoded bytes retained by this convenience
   --  operation.
   --  @param Item Active response
   --  @param Maximum Maximum decoded bytes
   --  @return Complete retained body
   --  @exception Response_Too_Large Maximum would be exceeded
   function Read_All
     (Item    : in out Response;
      Maximum : Natural := 1_024 * 1_024)
      return Flyology.Bytes.Unbounded_Bytes;

   --  Return coherent exchange and transport diagnostics without starting I/O.
   --  @param Item Client to inspect
   --  @return Current and cumulative counters
   function Diagnostics (Item : Client) return Client_Diagnostics;

   --  Close every currently idle connection. Active leases are unaffected.
   --  @param Item Configured client
   procedure Prune_Idle (Item : in out Client);

   --  Terminally reject admission, cancel admitted transport operations,
   --  close idle connections, and wait up to Timeout for leases and connecting
   --  slots to drain. A timeout leaves Item stopping and may be retried.
   --  @param Item Client to stop
   --  @param Timeout Drain deadline interval; negative waits indefinitely
   --  @exception Flyology.IO.Timeout_Error Active leases do not drain
   procedure Shutdown (Item : in out Client; Timeout : Duration := 5.0);

private
   --  Implementation declarations are kept in the private child so the public
   --  response abstraction can later represent a multiplexed protocol stream.
   type Client_State (Capacity : Positive);
   type Client_State_Access is access Client_State;

   --  @exclude
   procedure Validate_Response_Bytes_For_Testing
     (Value : Ada.Streams.Stream_Element_Array);

   type Client_Control is new Ada.Finalization.Limited_Controlled with record
      State : Client_State_Access := null;
   end record;

   type Request is record
      Method_Value : Method := To_Method ("GET");
      Target_Value : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.To_Unbounded_String ("/");
      Fields       : Flyology.HTTP.Headers.List;
      Body_Value   : Flyology.Bytes.Unbounded_Bytes;
   end record;

   type Client (Capacity : Positive := 4) is limited record
      Control     : Client_Control;
      TLS_Backend : access Flyology.IO.TLS.Provider'Class := null;
   end record;

   overriding procedure Finalize (Item : in out Client_Control);

   type Response_Data;
   type Response_Data_Access is access Response_Data;

   type Response is new Ada.Finalization.Limited_Controlled with record
      Data : Response_Data_Access := null;
   end record;

   overriding procedure Finalize (Item : in out Response);

end Flyology.HTTP.Client;
