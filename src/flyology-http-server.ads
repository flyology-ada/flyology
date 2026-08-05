with Ada.Streams;
with Ada.Finalization;
with Ada.Real_Time;
with Ada.Strings.Unbounded;
with Flyology.Bytes;
with Flyology.Cancellation;

--  Provides a bounded HTTP/1.1 connection engine over a task-aware transport.
--  The engine supports persistent requests, fixed-length and chunked request
--  bodies, fixed responses, server-sent events, and RFC 6455 WebSockets.
package Flyology.HTTP.Server is

   --  Maximum bytes before the terminating empty request-header line.
   Max_Header_Bytes : constant := 16 * 1_024;
   --  Maximum decoded request representation.
   Max_Request_Body : constant := 1_024 * 1_024;
   --  Default maximum retained or reassembled inbound WebSocket message.
   Default_Max_WebSocket_Message : constant := 1_024 * 1_024;
   --  Maximum supported inbound or generated WebSocket frame payload. Callers
   --  may opt into this bound with Receive_WebSocket's Max_Message parameter.
   Max_WebSocket_Frame : constant := 16 * 1_024 * 1_024;
   --  Process-wide retained-payload budget used by connections that do not
   --  attach a server-specific Ingress_Budget.
   Default_Ingress_Budget_Bytes : constant := 64 * 1_024 * 1_024;
   --  Process-wide retained outbound-message budget used by high-level SSE
   --  and WebSocket sessions without an application-supplied budget.
   Default_Outbound_Budget_Bytes : constant := 64 * 1_024 * 1_024;

   --  Raised when a buffered compatibility operation cannot reserve its
   --  payload from the configured shared ingress budget.
   Resource_Exhausted : exception;
   --  Raised when the declared or decoded body exceeds the active limit.
   Payload_Too_Large : exception;
   --  Raised for an unsupported or malformed Expect request field.
   Expectation_Failed : exception;

   --  Snapshot of shared buffered-ingress accounting.
   --  @field Limit Configured maximum reserved bytes
   --  @field Current Bytes currently reserved
   --  @field Peak Highest observed reservation
   --  @field Denials Failed nonblocking reservation attempts
   type Ingress_Budget_Snapshot is record
      Limit   : Positive;
      Current : Natural;
      Peak    : Natural;
      Denials : Natural;
   end record;

   --  Nonblocking shared budget for retained request bodies and WebSocket
   --  messages. Streaming operations write into caller-owned buffers and do
   --  not reserve their payload bytes here.
   --  @field Limit Maximum simultaneously reserved payload bytes
   type Ingress_Budget (Limit : Positive) is limited private;

   --  Attempt to reserve Bytes without suspending a handler.
   --  @param Item Shared server budget
   --  @param Bytes Requested buffered payload bytes
   --  @param Granted True only when the reservation was recorded
   procedure Try_Reserve
     (Item : in out Ingress_Budget;
      Bytes : Natural;
      Granted : out Boolean);

   --  Release a prior successful reservation.
   --  @param Item Shared server budget
   --  @param Bytes Reserved bytes to return
   procedure Release (Item : in out Ingress_Budget; Bytes : Natural);

   --  Read current budget counters.
   --  @param Item Shared server budget
   --  @return Stable accounting snapshot
   function Current (Item : Ingress_Budget) return Ingress_Budget_Snapshot;

   --  Snapshot of shared queued-outbound accounting.
   subtype Outbound_Budget_Snapshot is Ingress_Budget_Snapshot;

   --  Nonblocking shared budget for application messages retained by the
   --  optional SSE and WebSocket lifecycle APIs.
   --  @field Limit Maximum simultaneously retained outbound bytes
   type Outbound_Budget (Limit : Positive) is limited private;

   --  Attempt to reserve outbound bytes without suspending a producer.
   --  @param Item Shared application/server budget
   --  @param Bytes Requested retained bytes
   --  @param Granted True only when recorded
   procedure Try_Reserve
     (Item : in out Outbound_Budget;
      Bytes : Natural;
      Granted : out Boolean);

   --  Release a prior outbound reservation.
   --  @param Item Shared application/server budget
   --  @param Bytes Reserved bytes to return
   procedure Release (Item : in out Outbound_Budget; Bytes : Natural);

   --  Read current outbound budget counters.
   --  @param Item Shared application/server budget
   --  @return Stable accounting snapshot
   function Current (Item : Outbound_Budget) return Outbound_Budget_Snapshot;

   --  Transport boundary shared by plain and TLS connections. Implementations
   --  retain closing ownership and must preserve Flyology cancellation and
   --  deadline semantics.
   type Transport is limited interface;

   --  Receive one available transport chunk.
   --  @param Item Transport to read
   --  @param Data Destination buffer
   --  @param Last Last byte received, or Data'First - 1 on orderly closure
   --  @param Timeout Operation deadline interval in seconds
   --  @param Token Optional cancellation source that must outlive the call
   procedure Receive
     (Item    : in out Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token) is abstract;

   --  Send a complete transport chunk.
   --  @param Item Transport to write
   --  @param Data Source bytes
   --  @param Timeout Operation deadline interval in seconds
   --  @param Token Optional cancellation source that must outlive the call
   procedure Send_All
     (Item    : in out Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token) is abstract;

   --  One parsed request. Values are replaced by Read_Request.
   type Request is private;

   --  Return the request method exactly as received.
   --  @param Item Request to inspect
   --  @return Case-sensitive method token
   function Method (Item : Request) return String;
   --  Return the request target exactly as received.
   --  @param Item Request to inspect
   --  @return Origin-form or application-defined target
   function Target (Item : Request) return String;
   --  Return the parsed protocol version.
   --  @param Item Request to inspect
   --  @return HTTP/1.0 or HTTP/1.1
   function Version (Item : Request) return HTTP_Version;
   --  Return a case-insensitive header value with surrounding whitespace
   --  removed. Repeated fields are comma-joined in wire order.
   --  @param Item Request to inspect
   --  @param Name Header field name
   --  @return Header value, or an empty string when absent
   function Header (Item : Request; Name : String) return String;
   --  Count physical occurrences of one case-insensitive request field.
   --  @param Item Request to inspect
   --  @param Name Header field name
   --  @return Physical field count before comma joining
   function Header_Count (Item : Request; Name : String) return Natural;
   --  Report whether a comma-separated header contains a token.
   --  @param Item Request to inspect
   --  @param Name Header field name
   --  @param Value Token sought case-insensitively
   --  @return True when the token occurs as a complete list member
   function Header_Has_Token
     (Item : Request; Name : String; Value : String) return Boolean;
   --  Return the decoded fixed-length or chunked request body.
   --  @param Item Request to inspect
   --  @return Body bytes represented as an Ada String
   function Content (Item : Request) return String;

   --  HTTP/WebSocket state for one transport. The object and transport must
   --  remain owned by one handler at a time. Buffered pipelined input is kept
   --  between Read_Request calls.
   --  @field Channel Borrowed transport kept alive for this object
   type Connection (Channel : not null access Transport'Class) is limited
     private;

   --  Attach one shared ingress budget before the first request is read.
   --  The budget must outlive Item and cannot be replaced while bytes are
   --  reserved.
   --  @param Item HTTP connection to configure
   --  @param Budget Shared server budget
   procedure Configure_Ingress_Budget
     (Item   : in out Connection;
      Budget : not null access Ingress_Budget);

   --  Read and validate the next request head without buffering its body.
   --  Body framing remains attached to Item and must be consumed with
   --  Read_Body or Discard_Body before another request can be read. One
   --  monotonic Timeout begins here and covers the complete streamed body.
   --  Expect: 100-continue is not emitted until Accept_Body is called.
   --  @param Item HTTP connection
   --  @param Value Parsed request head on success; Content is empty
   --  @param Peer_Closed True only when the peer closes between requests
   --  @param Timeout Absolute header-and-body deadline interval
   --  @param Max_Body Application body limit, capped by Max_Request_Body
   --  @param Token Optional cancellation source
   procedure Read_Request_Head
     (Item        : in out Connection;
      Value       : out Request;
      Peer_Closed : out Boolean;
      Timeout     : Duration := 30.0;
      Max_Body    : Natural := Max_Request_Body;
      Token       : access Flyology.Cancellation.Token := null);

   --  Read and validate a request head with distinct absolute budgets for the
   --  header and complete request. Both clocks start before the first header
   --  byte, so neither incremental headers nor a streamed body can restart a
   --  deadline. Request_Timeout may exceed Header_Timeout for explicitly
   --  admitted long-lived responses such as SSE and WebSocket lifecycles.
   --  @param Item HTTP connection
   --  @param Value Parsed request head on success; Content is empty
   --  @param Peer_Closed True only when the peer closes between requests
   --  @param Header_Timeout Absolute request-head deadline interval
   --  @param Request_Timeout Absolute complete-request deadline interval
   --  @param Max_Body Application body limit, capped by Max_Request_Body
   --  @param Token Optional cancellation source
   procedure Read_Request_Head
     (Item            : in out Connection;
      Value           : out Request;
      Peer_Closed     : out Boolean;
      Header_Timeout  : Duration;
      Request_Timeout : Duration;
      Max_Body        : Natural := Max_Request_Body;
      Token           : access Flyology.Cancellation.Token := null);

   --  Accept the current request body, sending 100 Continue when requested.
   --  The original Read_Request_Head deadline remains authoritative.
   --  @param Item HTTP connection with an unread request body
   --  @param Token Optional cancellation source
   procedure Accept_Body
     (Item  : in out Connection;
      Token : access Flyology.Cancellation.Token := null);

   --  Stream decoded body bytes into caller-owned storage. Fixed-length and
   --  chunked framing are removed. Finished becomes true only after all body
   --  framing and trailers are consumed. The request-head deadline is never
   --  restarted by incremental reads.
   --  @param Item HTTP connection with a current request
   --  @param Data Caller-owned destination
   --  @param Last Last decoded byte, or Data'First - 1 when none
   --  @param Finished True after the complete body and trailers
   --  @param Token Optional cancellation source
   procedure Read_Body
     (Item     : in out Connection;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Token    : access Flyology.Cancellation.Token := null);

   --  Consume and discard the current body under the original absolute
   --  deadline. This is explicit because silently draining an unwanted body
   --  can itself be a slow-client attack.
   --  @param Item HTTP connection with a current request
   --  @param Token Optional cancellation source
   procedure Discard_Body
     (Item  : in out Connection;
      Token : access Flyology.Cancellation.Token := null);

   --  Report whether the current request body and trailers are consumed.
   --  @param Item HTTP connection
   --  @return True when another request may be parsed after the response
   function Body_Complete (Item : Connection) return Boolean;

   --  Return the absolute monotonic deadline established for the current
   --  request. Time_Last represents an unlimited deadline.
   --  @param Item HTTP connection
   --  @return Original or narrowed request deadline
   function Request_Deadline (Item : Connection) return Ada.Real_Time.Time;

   --  Shorten the current request deadline. A later value is rejected so no
   --  application layer can restart or extend slow-client protection.
   --  @param Item HTTP connection with a current request
   --  @param Deadline Earlier absolute monotonic deadline
   procedure Narrow_Request_Deadline
     (Item     : in out Connection;
      Deadline : Ada.Real_Time.Time);

   --  Reduce the decoded body limit after request-head routing. This must be
   --  called before body consumption and can never increase the parser limit.
   --  @param Item HTTP connection with an unread request body
   --  @param Maximum New decoded-body maximum
   procedure Narrow_Body_Limit
     (Item    : in out Connection;
      Maximum : Natural);

   --  Buffer the current decoded body into Value under the configured shared
   --  ingress budget. This is the routed equivalent of Read_Request's body
   --  phase and preserves the request-head deadline.
   --  @param Item HTTP connection with an unread body
   --  @param Value Request head previously read from Item
   --  @param Token Optional cancellation source
   --  @exception Resource_Exhausted Shared buffered ingress budget is full
   procedure Buffer_Request_Body
     (Item  : in out Connection;
      Value : in out Request;
      Token : access Flyology.Cancellation.Token := null);

   --  Read and parse the next request, buffering its complete decoded body.
   --  This compatibility operation is implemented over Read_Request_Head and
   --  Read_Body. When Item has an ingress budget, fixed bodies reserve their
   --  declared length and chunked bodies reserve Max_Body before allocation.
   --  Resource_Exhausted is raised without waiting when reservation fails.
   --  Header and body limits are enforced
   --  before allocation grows beyond their public bounds. One monotonic
   --  Timeout covers the complete header and decoded body, so incremental
   --  progress cannot extend a slow client's deadline. HTTP/1.1 requires Host.
   --  @param Item HTTP connection
   --  @param Value Parsed request on success
   --  @param Peer_Closed True only when the peer closes between requests
   --  @param Timeout Deadline used by each transport receive
   --  @param Max_Body Application body limit, capped by Max_Request_Body
   --  @param Token Optional cancellation source
   --  @exception Protocol_Error Input is malformed, oversized, or unsupported
   --  @exception Resource_Exhausted Shared buffered ingress budget is full
   procedure Read_Request
     (Item        : in out Connection;
      Value       : out Request;
      Peer_Closed : out Boolean;
      Timeout     : Duration := 30.0;
      Max_Body    : Natural := Max_Request_Body;
      Token       : access Flyology.Cancellation.Token := null);

   --  Send one complete fixed-length response. Reason is derived from Status.
   --  Extra_Headers is a sequence of complete CRLF-terminated fields and must
   --  not contain an empty line. HEAD sends the declared body length without
   --  body bytes. Statuses 204, 205, and 304 reject nonempty Payload; 204 and
   --  304 omit Content-Length. Connection persistence follows the request
   --  unless Close is true.
   --  @param Item HTTP connection
   --  @param Status Three-digit HTTP status
   --  @param Content_Type Media type, or empty to omit
   --  @param Payload Response representation
   --  @param Extra_Headers Additional validated header fields
   --  @param Close Force connection closure after the response
   --  @param Timeout Transport send deadline
   --  @param Token Optional cancellation source
   procedure Respond
     (Item          : in out Connection;
      Status        : Positive;
      Content_Type  : String;
      Payload       : String;
      Extra_Headers : String := "";
      Close         : Boolean := False;
      Timeout       : Duration := 30.0;
      Token         : access Flyology.Cancellation.Token := null);

   --  Start an arbitrary streaming response. HTTP/1.1 uses chunked framing;
   --  HTTP/1.0 uses connection-close delimiting. The handler remains the sole
   --  writer until End_Response_Stream completes.
   --  @param Item HTTP connection
   --  @param Status HTTP status
   --  @param Content_Type Media type, or empty to omit
   --  @param Extra_Headers Additional validated response fields
   --  @param Close Force connection closure after the stream
   --  @param Timeout Transport send deadline
   --  @param Token Optional cancellation source
   procedure Begin_Response_Stream
     (Item          : in out Connection;
      Status        : Positive;
      Content_Type  : String;
      Extra_Headers : String := "";
      Close         : Boolean := False;
      Timeout       : Duration := 30.0;
      Token         : access Flyology.Cancellation.Token := null);

   --  Send one streaming response chunk with transport backpressure.
   --  Empty data is a no-op and HEAD suppresses data bytes.
   --  @param Item Active streaming response
   --  @param Data Response bytes
   --  @param Timeout Transport send deadline
   --  @param Token Optional cancellation source
   procedure Write_Response_Chunk
     (Item    : in out Connection;
      Data    : String;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null);

   --  Send one binary streaming response chunk with transport backpressure.
   --  Empty data is a no-op and HEAD suppresses data bytes.
   --  @param Item Active streaming response
   --  @param Data Response bytes
   --  @param Timeout Transport send deadline
   --  @param Token Optional cancellation source
   procedure Write_Response_Chunk
     (Item    : in out Connection;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null);

   --  Complete a streaming response and release the connection for another
   --  request when persistence remains safe.
   --  @param Item Active streaming response
   --  @param Timeout Transport send deadline
   --  @param Token Optional cancellation source
   procedure End_Response_Stream
     (Item    : in out Connection;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null);

   --  Report whether the last request or response requires transport close.
   --  @param Item HTTP connection
   --  @return True when no further request may be processed
   function Should_Close (Item : Connection) return Boolean;
   --  Report whether the current request already received a response or
   --  protocol upgrade.
   --  @param Item HTTP connection
   --  @return True after Respond, Begin_SSE, or Accept_WebSocket
   function Response_Started (Item : Connection) return Boolean;

   --  Start a chunked text/event-stream response.
   --  @param Item HTTP connection
   --  @param Extra_Headers Additional validated response fields
   --  @param Timeout Transport send deadline
   --  @param Token Optional cancellation source
   procedure Begin_SSE
     (Item          : in out Connection;
      Extra_Headers : String := "";
      Timeout       : Duration := 30.0;
      Token         : access Flyology.Cancellation.Token := null);

   --  Send one SSE event as one HTTP chunk. Embedded newlines in Data become
   --  repeated data fields. Empty Event and ordinary default Id/Retry values
   --  are omitted; include flags allow the valid empty-id reset and retry 0.
   --  @param Item Active SSE response
   --  @param Data Event data
   --  @param Event Optional event type
   --  @param Id Optional event id
   --  @param Retry Optional client retry interval in milliseconds
   --  @param Timeout Transport send deadline
   --  @param Token Optional cancellation source
   --  @param Include_Id Emit id even when Id is empty
   --  @param Include_Retry Emit retry even when Retry is zero
   procedure Send_Event
     (Item    : in out Connection;
      Data    : String;
      Event   : String := "";
      Id      : String := "";
      Retry   : Natural := 0;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null;
      Include_Id : Boolean := False;
      Include_Retry : Boolean := False);

   --  Send one SSE comment, commonly used as a heartbeat without dispatching
   --  an application message in EventSource clients.
   --  @param Item Active SSE response
   --  @param Comment Comment text; embedded newlines become comment fields
   --  @param Timeout Transport send deadline
   --  @param Token Optional cancellation source
   procedure Send_SSE_Comment
     (Item    : in out Connection;
      Comment : String := "";
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null);

   --  Finish a chunked SSE response. The HTTP connection can process another
   --  request when persistence remains enabled.
   --  @param Item Active SSE response
   --  @param Timeout Transport send deadline
   --  @param Token Optional cancellation source
   procedure End_SSE
     (Item    : in out Connection;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null);

   --  WebSocket application-data kind.
   --  @enum Text_Frame Validated UTF-8 text payload
   --  @enum Binary_Frame Binary payload
   type WebSocket_Data_Kind is (Text_Frame, Binary_Frame);

   --  WebSocket extension policy selected explicitly at upgrade time.
   --  Permessage_Deflate negotiates RFC 7692 with no context takeover in
   --  both directions so compression state and history do not cross message
   --  boundaries. Applications must assess compression side channels before
   --  enabling it for secret-bearing messages.
   --  @enum No_WebSocket_Compression Decline compression offers
   --  @enum Permessage_Deflate Negotiate bounded per-message raw DEFLATE
   type WebSocket_Compression_Mode is
     (No_WebSocket_Compression, Permessage_Deflate);

   --  Browser-origin policy applied before a WebSocket upgrade.
   --  @enum Reject_Browser_Origins Reject requests containing Origin
   --  @enum Allow_Any_Origin Accept zero or one syntactically bounded Origin
   --  @enum Require_Exact_Origin Require exact case-sensitive Allowed_Origin
   type WebSocket_Origin_Policy is
     (Reject_Browser_Origins, Allow_Any_Origin, Require_Exact_Origin);

   --  Perform an RFC 6455 server upgrade for Request. The client key and
   --  required Upgrade, Connection, and version fields are validated.
   --  @param Item HTTP connection
   --  @param Value Request being upgraded
   --  @param Protocol Optional selected subprotocol token
   --  @param Origin_Policy Browser-origin policy; secure non-browser default
   --  @param Allowed_Origin Exact origin required by Require_Exact_Origin
   --  @param Timeout Transport send deadline
   --  @param Token Optional cancellation source
   --  @param Compression Explicit RFC 7692 negotiation policy
   --  @exception Protocol_Error Request is not a valid version 13 upgrade
   procedure Accept_WebSocket
     (Item     : in out Connection;
      Value    : Request;
      Protocol : String := "";
      Origin_Policy : WebSocket_Origin_Policy := Reject_Browser_Origins;
      Allowed_Origin : String := "";
      Timeout  : Duration := 30.0;
      Token    : access Flyology.Cancellation.Token := null;
      Compression : WebSocket_Compression_Mode := No_WebSocket_Compression);

   --  Receive one complete client message, reassembling fragments within
   --  Max_Message. Timeout bounds one wait quantum; Message_Timeout is one
   --  monotonic deadline retained across retry quanta, all fragments, and
   --  interleaved control frames. Ping is answered automatically and close
   --  sets Closed.
   --  Client frames must be masked. Protocol failure makes Item terminal.
   --  Negotiated compression is decoded before return; compressed and
   --  decompressed storage is charged to the shared ingress budget.
   --  A Timeout expiry may be retried while Item remains active. Expiry of the
   --  retained whole-message deadline or a control-frame write makes Item
   --  terminal before raising Timeout_Error.
   --  @param Item Upgraded WebSocket connection
   --  @param Kind Text or binary message kind
   --  @param Data Message payload
   --  @param Closed True after a valid close frame
   --  @param Max_Message Application message limit, capped by the 16 MiB
   --  supported frame maximum; the default remains 1 MiB
   --  @param Timeout Transport receive/send wait quantum
   --  @param Message_Timeout Whole-message monotonic deadline
   --  @param Token Optional cancellation source
   --  @exception Resource_Exhausted Shared message reassembly budget is full
   procedure Receive_WebSocket
     (Item    : in out Connection;
      Kind    : out WebSocket_Data_Kind;
      Data    : out Flyology.Bytes.Unbounded_Bytes;
      Closed  : out Boolean;
      Max_Message : Natural := Default_Max_WebSocket_Message;
      Timeout : Duration := 30.0;
      Message_Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null);

   --  Send one unmasked, final server data frame.
   --  @param Item Upgraded WebSocket connection
   --  @param Kind Text or binary message kind
   --  @param Data Frame payload
   --  @param Timeout Transport send deadline
   --  @param Token Optional cancellation source
   procedure Send_WebSocket
     (Item    : in out Connection;
      Kind    : WebSocket_Data_Kind;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null);

   --  Send one unmasked, final server data frame directly from owned bytes.
   --  This overload writes large messages in bounded chunks and does not form
   --  a contiguous copy on the caller's task stack.
   --  @param Item Upgraded WebSocket connection
   --  @param Kind Text or binary message kind
   --  @param Data Owned frame payload
   --  @param Timeout Whole-frame transport send deadline
   --  @param Token Optional cancellation source
   procedure Send_WebSocket
     (Item    : in out Connection;
      Kind    : WebSocket_Data_Kind;
      Data    : Flyology.Bytes.Unbounded_Bytes;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null);

   --  Send one unmasked, final UTF-8 text frame. Data is interpreted as UTF-8
   --  encoded octets and validated before any frame bytes are written.
   --  @param Item Upgraded WebSocket connection
   --  @param Data UTF-8 byte string
   --  @param Timeout Transport send deadline
   --  @param Token Optional cancellation source
   procedure Send_WebSocket
     (Item    : in out Connection;
      Data    : String;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null);

   --  Send a normal WebSocket close frame and make Item terminal.
   --  @param Item Upgraded WebSocket connection
   --  @param Code RFC 6455 close status
   --  @param Reason Optional UTF-8 close reason
   --  @param Timeout Transport send deadline
   --  @param Token Optional cancellation source
   procedure Close_WebSocket
     (Item    : in out Connection;
      Code    : Positive := 1_000;
      Reason  : String := "";
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null);

private
   use Ada.Strings.Unbounded;

   type Request is record
      Method_Value  : Unbounded_String;
      Target_Value  : Unbounded_String;
      Version_Value : HTTP_Version := HTTP_1_1;
      Header_Block  : Unbounded_String;
      Body_Value    : Unbounded_String;
      Keep_Alive    : Boolean := False;
   end record;

   type Connection_State is
     (Reading_HTTP, Streaming_HTTP, Streaming_SSE, WebSocket, Terminal);

   type Request_Body_Mode is (No_Body, Fixed_Body, Chunked_Body);
   type Ingress_Budget_Access is access all Ingress_Budget;
   subtype WebSocket_Mask is Ada.Streams.Stream_Element_Array (0 .. 3);
   subtype WebSocket_Control_Buffer is
     Ada.Streams.Stream_Element_Array (1 .. 125);

   protected type Ingress_Budget_State (Limit : Positive) is
      procedure Try_Reserve (Bytes : Natural; Granted : out Boolean);
      procedure Release (Bytes : Natural);
      function Current return Ingress_Budget_Snapshot;
   private
      Used        : Natural := 0;
      High_Water  : Natural := 0;
      Denied      : Natural := 0;
   end Ingress_Budget_State;

   type Ingress_Budget (Limit : Positive) is limited record
      State : Ingress_Budget_State (Limit);
   end record;

   protected type Outbound_Budget_State (Limit : Positive) is
      procedure Try_Reserve (Bytes : Natural; Granted : out Boolean);
      procedure Release (Bytes : Natural);
      function Current return Outbound_Budget_Snapshot;
   private
      Used        : Natural := 0;
      High_Water  : Natural := 0;
      Denied      : Natural := 0;
   end Outbound_Budget_State;

   type Outbound_Budget (Limit : Positive) is limited record
      State : Outbound_Budget_State (Limit);
   end record;

   Default_Outbound_Budget : aliased Outbound_Budget
     (Limit => Default_Outbound_Budget_Bytes);

   type Connection (Channel : not null access Transport'Class)
   is limited new Ada.Finalization.Limited_Controlled with
     record
      Budget_Handle     : Ingress_Budget_Access := null;
      Reservation_Budget : Ingress_Budget_Access := null;
      Pending          : Unbounded_String;
      State            : Connection_State := Reading_HTTP;
      Request_Close    : Boolean := False;
      Response_Begun   : Boolean := False;
      Current_Is_Head  : Boolean := False;
      Current_Version  : HTTP_Version := HTTP_1_1;
      Body_Mode        : Request_Body_Mode := No_Body;
      Body_Remaining   : Natural := 0;
      Body_Total       : Natural := 0;
      Body_Limit       : Natural := 0;
      Body_Done        : Boolean := True;
      Body_Accepted    : Boolean := True;
      Continue_Pending : Boolean := False;
      Chunk_CRLF_Pending : Boolean := False;
      Body_Started     : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Body_Timeout     : Duration := 0.0;
      Buffered_Bytes   : Natural := 0;
      WebSocket_Reserved   : Boolean := False;
      WebSocket_Fragmented : Boolean := False;
      WebSocket_Receive_Active : Boolean := False;
      WebSocket_Message_Deadline : Ada.Real_Time.Time :=
        Ada.Real_Time.Time_Last;
      WebSocket_Close_Sent : Boolean := False;
      WebSocket_Message_Kind : WebSocket_Data_Kind := Text_Frame;
      WebSocket_Message : Flyology.Bytes.Unbounded_Bytes;
      WebSocket_Message_Limit : Natural := 0;
      WebSocket_Control_Count : Natural := 0;
      WebSocket_Frame_Active : Boolean := False;
      WebSocket_Frame_Opcode : Natural := 0;
      WebSocket_Frame_Final : Boolean := False;
      WebSocket_Frame_Remaining : Natural := 0;
      WebSocket_Frame_Position : Natural := 0;
      WebSocket_Frame_Mask : WebSocket_Mask := (others => 0);
      WebSocket_Control_Payload : WebSocket_Control_Buffer := (others => 0);
      WebSocket_Deflate_Enabled : Boolean := False;
      WebSocket_Message_Compressed : Boolean := False;
   end record;

   --  Release any active buffered reservation.
   --  @param Item HTTP connection being finalized
   overriding procedure Finalize (Item : in out Connection);

end Flyology.HTTP.Server;
