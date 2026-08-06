with Ada.Real_Time;
with Ada.Streams;
with Ada.Task_Identification;
with Flyology.Bytes;
with Flyology.Cancellation;
with Flyology.IO.Sockets;

--  Supplies a request-scoped application exchange above the raw HTTP engine.
--  Exchange borrows its request, connection, application context, and optional
--  cancellation token. It must not escape the handler call that created it.
package Flyology.HTTP.Server.Applications is

   --  Maximum named parameters installed by one matched route.
   Max_Path_Parameters : constant := 16;

   --  Route-selected request-body handling.
   --  @enum Reject_Body Reject a request carrying a body
   --  @enum Stream_Body Decode into caller buffers
   --  @enum Buffer_Body Buffer under the shared ingress budget
   --  @enum Discard_Request_Body Explicitly consume and ignore the body
   type Request_Body_Policy is
     (Reject_Body, Stream_Body, Buffer_Body, Discard_Request_Body);

   --  Observable request-body lifecycle.
   --  @enum Body_Pending Admission or consumption has not completed
   --  @enum Body_Streaming Caller reads decoded chunks
   --  @enum Body_Buffered Buffered content is available
   --  @enum Body_Completed No retained content remains to consume
   --  @enum Body_Rejected Route policy does not accept the pending body
   type Request_Body_State is
     (Body_Pending, Body_Streaming, Body_Buffered, Body_Completed,
      Body_Rejected);

   --  Route authentication requirement interpreted by optional middleware.
   --  @enum No_Authentication Route does not request authentication
   --  @enum Optional_Authentication Install a principal when credentials exist
   --  @enum Required_Authentication Reject unauthenticated requests
   type Authentication_Mode is
     (No_Authentication, Optional_Authentication, Required_Authentication);

   --  Route-selected application protocol upgrade.
   --  @enum No_Upgrade Ordinary HTTP responses only
   --  @enum Allow_SSE Server-sent event lifecycle is permitted
   --  @enum Allow_WebSocket WebSocket lifecycle is permitted
   type Upgrade_Mode is (No_Upgrade, Allow_SSE, Allow_WebSocket);

   --  High-level response lifecycle observed through this exchange.
   --  @enum Not_Started No response bytes have been written
   --  @enum Completed One complete fixed response was written
   --  @enum Streaming_Response A chunked/close-delimited response is active
   --  @enum Streaming_SSE A server-sent event response is active
   --  @enum Upgraded A protocol upgrade owns the connection
   --  @enum Failed Response completion is unsafe or failed
   type Response_State is
     (Not_Started, Completed, Streaming_Response, Streaming_SSE,
      Upgraded, Failed);

   --  Borrowed request scope. The object is tagged for Ada prefixed calls such
   --  as X.Text, but concrete helpers do not require dynamic dispatch.
   type Exchange (<>) is tagged limited private;

   --  Construct one exchange around values owned by the active handler.
   --  Access discriminants let Ada reject an exchange whose request,
   --  connection, or token would not outlive it.
   --  @param Value Parsed request owned by the handler
   --  @param Item Sole-writer HTTP connection owned by the handler
   --  @param Peer Connected peer address
   --  @param Token Optional borrowed cancellation token
   --  @param Deadline Absolute monotonic request deadline
   --  @return Request-scoped exchange
   function Create
      (Value    : aliased in out Request;
      Item     : aliased in out Connection;
      Peer     : Flyology.IO.Sockets.Endpoint;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time) return Exchange;

   --  Return a copy of the parsed request. Body storage is present after a
   --  buffered body policy has completed.
   --  @param Item Request exchange
   --  @return Parsed request value
   function Request_Value (Item : Exchange) return Request;

   --  Return the request method without copying the complete request.
   --  @param Item Request exchange
   --  @return Request method
   function Request_Method (Item : Exchange) return String;

   --  Return the original request target.
   --  @param Item Request exchange
   --  @return Request target
   function Request_Target (Item : Exchange) return String;

   --  Return a case-insensitive request header value. Repeated fields retain
   --  the core parser's comma-joined wire order.
   --  @param Item Request exchange
   --  @param Name Header field name
   --  @return Header value or an empty string
   function Request_Header (Item : Exchange; Name : String) return String;

   --  Count physical occurrences of a case-insensitive request field.
   --  @param Item Request exchange
   --  @param Name Header field name
   --  @return Physical field count before comma joining
   function Request_Header_Count
     (Item : Exchange; Name : String) return Natural;

   --  Report whether the protocol engine has emitted response bytes. This
   --  narrow query supports safe error mapping without exposing the borrowed
   --  connection.
   --  @param Item Request exchange
   --  @return True after response framing begins on the wire
   function Wire_Response_Started (Item : Exchange) return Boolean;

   --  Return the portable connected-peer endpoint supplied by the server
   --  adapter.
   --  @param Item Request exchange
   --  @return Peer endpoint
   function Peer (Item : Exchange) return Flyology.IO.Sockets.Endpoint;

   --  Borrow the request cancellation token, or null when none was supplied.
   --  @param Item Request exchange
   --  @return Borrowed cancellation token
   function Cancellation
     (Item : Exchange) return access Flyology.Cancellation.Token;

   --  Return the current absolute deadline.
   --  @param Item Request exchange
   --  @return Original or narrowed monotonic deadline
   function Deadline (Item : Exchange) return Ada.Real_Time.Time;

   --  Return time remaining, or a negative value for an unlimited deadline.
   --  @param Item Request exchange
   --  @return Remaining seconds
   function Remaining (Item : Exchange) return Duration;

   --  Shorten the request deadline. Extending it raises Program_Error.
   --  @param Item Request exchange
   --  @param Value Earlier absolute monotonic deadline
   procedure Narrow_Deadline
     (Item  : in out Exchange;
      Value : Ada.Real_Time.Time);

   --  Return the normalized matched route name.
   --  @param Item Request exchange
   --  @return Stable configured route name, or an empty string before routing
   function Route_Name (Item : Exchange) return String;

   --  Return the normalized decoded path used by the router.
   --  @param Item Request exchange
   --  @return Decoded path
   function Path (Item : Exchange) return String;

   --  Return a decoded named route parameter. Names are case-sensitive.
   --  @param Item Request exchange
   --  @param Name Parameter name
   --  @return Parameter value, or an empty string when absent
   function Parameter (Item : Exchange; Name : String) return String;

   --  Report whether a named route parameter is present, distinguishing an
   --  absent value from a present empty remainder.
   --  @param Item Request exchange
   --  @param Name Parameter name
   --  @return True when the route installed Name
   function Has_Parameter (Item : Exchange; Name : String) return Boolean;

   --  Return the request identifier installed by middleware.
   --  @param Item Request exchange
   --  @return Bounded validated request identifier, or an empty string
   function Request_ID (Item : Exchange) return String;

   --  Install a validated request identifier for helpers and observation.
   --  Control bytes and values longer than 128 bytes are rejected.
   --  @param Item Request exchange
   --  @param Value Request identifier
   procedure Set_Request_ID (Item : in out Exchange; Value : String);

   --  Report whether authentication middleware installed a principal.
   --  @param Item Request exchange
   --  @return True when a principal is present
   function Has_Principal (Item : Exchange) return Boolean;

   --  Return the authenticated principal, or an empty string.
   --  @param Item Request exchange
   --  @return Application-defined bounded principal
   function Principal (Item : Exchange) return String;

   --  Install an authenticated principal. Header control bytes and values
   --  longer than 256 bytes are rejected.
   --  @param Item Request exchange
   --  @param Value Application-defined principal
   procedure Set_Principal (Item : in out Exchange; Value : String);

   --  Return the selected route authentication requirement.
   --  @param Item Request exchange
   --  @return Route authentication mode
   function Authentication (Item : Exchange) return Authentication_Mode;

   --  Return the selected bounded CORS policy registry slot.
   --  @param Item Request exchange
   --  @return CORS policy slot or zero
   function CORS_Policy (Item : Exchange) return Natural;

   --  Return the route concurrency limit; zero means unlimited.
   --  @param Item Request exchange
   --  @return Route concurrency bound
   function Concurrency_Limit (Item : Exchange) return Natural;

   --  Return the route per-client request rate; zero means unlimited.
   --  @param Item Request exchange
   --  @return Requests per second
   function Rate_Per_Second (Item : Exchange) return Natural;

   --  Return the route-selected body policy.
   --  @param Item Request exchange
   --  @return Current body policy
   function Body_Policy (Item : Exchange) return Request_Body_Policy;

   --  Return the current body lifecycle without forcing body consumption.
   --  @param Item Request exchange
   --  @return Current body state
   function Body_State (Item : Exchange) return Request_Body_State;

   --  Report whether the decoded body and trailers are fully consumed.
   --  @param Item Request exchange
   --  @return True when body processing is complete
   function Body_Complete (Item : Exchange) return Boolean;

   --  Return decoded request-body bytes observed so far.
   --  @param Item Request exchange
   --  @return Decoded request bytes
   function Request_Body_Bytes (Item : Exchange) return Natural;

   --  Stream decoded request bytes under the current absolute deadline.
   --  @param Item Request exchange configured for Stream_Body
   --  @param Data Caller-owned destination
   --  @param Last Last decoded byte, or Data'First - 1
   --  @param Finished True after body framing and trailers are consumed
   procedure Read_Body
     (Item     : in out Exchange;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean);

   --  Return buffered request content.
   --  @param Item Request exchange
   --  @return Buffered decoded body
   function Content (Item : Exchange) return String;

   --  Add one response header for the next high-level fixed response. Header
   --  names and values are validated immediately against injection.
   --  @param Item Request exchange
   --  @param Name Header field name
   --  @param Value Header field value
   procedure Add_Header
     (Item  : in out Exchange;
      Name  : String;
      Value : String);

   --  Send one complete response through the borrowed connection.
   --  @param Item Request exchange
   --  @param Status HTTP status
   --  @param Content_Type Media type, or empty to omit
   --  @param Payload Response representation
   --  @param Close Force connection close
   procedure Respond
     (Item         : in out Exchange;
      Status       : Positive;
      Content_Type : String;
      Payload      : String;
      Close        : Boolean := False);

   --  Send a UTF-8 text response.
   --  @param Item Request exchange
   --  @param Status HTTP status
   --  @param Value Response text
   procedure Text
     (Item   : in out Exchange;
      Status : Positive;
      Value  : String);

   --  Send a caller-serialized JSON response without choosing a JSON library.
   --  @param Item Request exchange
   --  @param Status HTTP status
   --  @param Serialized Complete JSON representation
   procedure JSON
     (Item       : in out Exchange;
      Status     : Positive;
      Serialized : String);

   --  Send a redirect with a validated Location header.
   --  @param Item Request exchange
   --  @param Status Redirect status
   --  @param Location Redirect target
   procedure Redirect
     (Item     : in out Exchange;
      Status   : Positive;
      Location : String);

   --  Send a 204 response.
   --  @param Item Request exchange
   procedure No_Content (Item : in out Exchange);

   --  Send a small application/problem+json response.
   --  @param Item Request exchange
   --  @param Status HTTP status
   --  @param Kind Stable application problem identifier
   --  @param Detail Safe human-readable detail
   procedure Problem
     (Item   : in out Exchange;
      Status : Positive;
      Kind   : String;
      Detail : String);

   --  Start an optional high-level streaming response. The active handler
   --  remains its sole writer; child tasks must communicate through a bounded
   --  mailbox rather than retaining Item or its connection.
   --  @param Item Request exchange
   --  @param Status HTTP status
   --  @param Content_Type Media type, or empty to omit
   --  @param Close Force connection close after the stream
   procedure Begin_Stream
     (Item         : in out Exchange;
      Status       : Positive;
      Content_Type : String;
      Close        : Boolean := False);

   --  Write one response chunk with synchronous transport backpressure.
   --  @param Item Exchange with an active streaming response
   --  @param Data Response bytes
   procedure Write_Chunk (Item : in out Exchange; Data : String);

   --  Write one binary response chunk with synchronous transport
   --  backpressure.
   --  @param Item Exchange with an active streaming response
   --  @param Data Response bytes
   procedure Write_Chunk
     (Item : in out Exchange;
      Data : Ada.Streams.Stream_Element_Array);

   --  Complete an active streaming response.
   --  @param Item Exchange with an active streaming response
   procedure End_Stream (Item : in out Exchange);

   --  Start a server-sent event response through the raw SSE engine while
   --  retaining Exchange response observation.
   --  @param Item Request exchange
   procedure Begin_SSE (Item : in out Exchange);

   --  Send one SSE event with transport backpressure.
   --  @param Item Exchange with an active SSE response
   --  @param Data Event data
   --  @param Event Optional event type
   --  @param Id Optional event id
   --  @param Retry Optional retry milliseconds
   --  @param Include_Id Emit id even when Id is empty
   --  @param Include_Retry Emit retry even when Retry is zero
   procedure Send_SSE
     (Item  : in out Exchange;
      Data  : String;
      Event : String := "";
      Id    : String := "";
      Retry : Natural := 0;
      Include_Id : Boolean := False;
      Include_Retry : Boolean := False);

   --  Send an SSE comment heartbeat without dispatching an application event.
   --  @param Item Exchange with an active SSE response
   --  @param Comment Optional comment text
   procedure Send_SSE_Comment
     (Item : in out Exchange; Comment : String := "");

   --  Complete an active SSE response.
   --  @param Item Request exchange
   procedure End_SSE (Item : in out Exchange);

   --  Upgrade through the raw WebSocket engine while retaining Exchange
   --  response observation. The calling handler remains the sole writer.
   --  @param Item Request exchange
   --  @param Protocol Optional selected subprotocol
   --  @param Origin_Policy Browser-origin policy
   --  @param Allowed_Origin Exact origin for Require_Exact_Origin
   --  @param Compression Explicit RFC 7692 negotiation policy
   procedure Accept_WebSocket
     (Item           : in out Exchange;
      Protocol       : String := "";
      Origin_Policy  : WebSocket_Origin_Policy := Reject_Browser_Origins;
      Allowed_Origin : String := "";
      Compression    : WebSocket_Compression_Mode :=
        No_WebSocket_Compression);

   --  Receive one complete WebSocket message through the borrowed connection.
   --  A retry-quantum expiry raises Timeout_Error while the exchange remains
   --  active. A whole-message or control-write timeout makes the exchange
   --  failed and re-raises Timeout_Error.
   --  @param Item Upgraded request exchange
   --  @param Kind Text or binary message kind
   --  @param Data Complete message payload
   --  @param Closed True when the peer completed the close handshake
   --  @param Max_Message Maximum retained/reassembled message bytes
   --  @param Timeout Receive quantum capped by the request deadline
   --  @param Message_Timeout Whole-message deadline, also request-capped
   procedure Receive_WebSocket
     (Item        : in out Exchange;
      Kind        : out WebSocket_Data_Kind;
      Data        : out Flyology.Bytes.Unbounded_Bytes;
      Closed      : out Boolean;
      Max_Message : Natural := Default_Max_WebSocket_Message;
      Timeout     : Duration := 30.0;
      Message_Timeout : Duration := 30.0);

   --  Send one WebSocket message from the sole connection-owner handler.
   --  @param Item Upgraded request exchange
   --  @param Kind Text or binary message kind
   --  @param Data Message payload
   procedure Send_WebSocket
     (Item : in out Exchange;
      Kind : WebSocket_Data_Kind;
      Data : Ada.Streams.Stream_Element_Array);

   --  Send one owned WebSocket message without a contiguous task-stack copy.
   --  @param Item Upgraded request exchange
   --  @param Kind Text or binary message kind
   --  @param Data Owned message payload
   procedure Send_WebSocket
     (Item : in out Exchange;
      Kind : WebSocket_Data_Kind;
      Data : Flyology.Bytes.Unbounded_Bytes);

   --  Send a validated UTF-8 text message from the sole connection owner.
   --  @param Item Upgraded request exchange
   --  @param Data UTF-8 byte string
   procedure Send_WebSocket
     (Item : in out Exchange;
      Data : String);

   --  Complete an upgraded WebSocket with a normal close frame.
   --  @param Item Upgraded request exchange
   --  @param Code RFC 6455 close status
   --  @param Reason Optional UTF-8 close reason
   procedure Close_WebSocket
     (Item   : in out Exchange;
      Code   : Positive := 1_000;
      Reason : String := "");

   --  Record a peer-initiated WebSocket close already completed by the raw
   --  protocol engine. Intended for lifecycle adapters.
   --  @param Item Upgraded request exchange
   procedure Complete_WebSocket (Item : in out Exchange);

   --  Return the high-level response lifecycle.
   --  @param Item Request exchange
   --  @return Current response state
   function Response (Item : Exchange) return Response_State;

   --  Return the fixed response status, or zero before a response.
   --  @param Item Request exchange
   --  @return HTTP status or zero
   function Response_Status (Item : Exchange) return Natural;

   --  Return response payload bytes written, excluding suppressed HEAD data.
   --  @param Item Request exchange
   --  @return Observed payload bytes
   function Response_Bytes (Item : Exchange) return Natural;

   --  Mark response framing unsafe and require connection close. Error
   --  middleware uses this after a failure once response bytes may exist.
   --  @param Item Request exchange
   procedure Mark_Failed (Item : in out Exchange);

   --  Apply the configured route body policy after request-head middleware
   --  accepts the request. This is the only application-layer operation that
   --  may emit delayed 100 Continue. Rejection sends a final response and
   --  returns Accepted false.
   --  @param Item Request exchange
   --  @param Accepted True when downstream application work may run
   procedure Apply_Body_Policy
     (Item     : in out Exchange;
      Accepted : out Boolean);

   --  Configure routing metadata before invoking application components.
   --  This integration operation is intended for Flyology router packages.
   --  @param Item Request exchange
   --  @param Name Stable route name
   --  @param Normalized_Path Decoded path used for matching
   --  @param Policy Route body policy
   --  @param Authentication Route authentication requirement
   --  @param CORS_Policy Bounded CORS registry slot
   --  @param Concurrency Route concurrency limit
   --  @param Rate_Per_Second Route per-client request rate
   --  @param Upgrade Permitted application protocol lifecycle
   procedure Configure_Route
     (Item            : in out Exchange;
      Name            : String;
      Normalized_Path : String;
      Policy          : Request_Body_Policy;
      Authentication  : Authentication_Mode;
      CORS_Policy     : Natural;
      Concurrency     : Natural;
      Rate_Per_Second : Natural;
      Upgrade         : Upgrade_Mode);

   --  Append one decoded route parameter. Duplicate names or capacity excess
   --  raise Program_Error. Intended for Flyology router packages.
   --  @param Item Request exchange
   --  @param Name Parameter name
   --  @param Value Decoded parameter value
   procedure Add_Parameter
     (Item  : in out Exchange;
      Name  : String;
      Value : String);

   --  Freeze router-owned identity and policy before middleware runs.
   --  @param Item Configured request exchange
   procedure Seal_Route (Item : in out Exchange);

private

   type Parameter_Entry is record
      Name  : Unbounded_String;
      Value : Unbounded_String;
   end record;
   type Parameter_Array is
     array (Positive range 1 .. Max_Path_Parameters) of Parameter_Entry;

   type Exchange
     (Request_Handle    : not null access Request;
      Connection_Handle : not null access Connection;
      Token_Handle      : access Flyology.Cancellation.Token)
   is tagged limited record
      Owner_Task        : Ada.Task_Identification.Task_Id :=
        Ada.Task_Identification.Current_Task;
      Peer_Value        : Flyology.IO.Sockets.Endpoint;
      Deadline_Value    : Ada.Real_Time.Time := Ada.Real_Time.Time_Last;
      Route_Value       : Unbounded_String;
      Path_Value        : Unbounded_String;
      Parameters        : Parameter_Array;
      Parameter_Count   : Natural := 0;
      Route_Sealed      : Boolean := False;
      Request_ID_Value  : Unbounded_String;
      Principal_Value   : Unbounded_String;
      Principal_Present : Boolean := False;
      Body_Mode         : Request_Body_Policy := Reject_Body;
      Authentication_Value : Authentication_Mode := No_Authentication;
      CORS_Policy_Value : Natural := 0;
      Concurrency_Value : Natural := 0;
      Rate_Value        : Natural := 0;
      Upgrade_Value     : Upgrade_Mode := No_Upgrade;
      Extra_Headers     : Unbounded_String;
      Response_Value    : Response_State := Not_Started;
      Status_Value      : Natural := 0;
      Response_Length   : Natural := 0;
   end record;

end Flyology.HTTP.Server.Applications;
