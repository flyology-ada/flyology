with Ada.Real_Time;
with Ada.Streams;
with GNAT.Sockets;
with System;
with Flyology.Cancellation;

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

   --  Route authentication requirement interpreted by optional middleware.
   --  @enum No_Authentication Route does not request authentication
   --  @enum Optional_Authentication Install a principal when credentials exist
   --  @enum Required_Authentication Reject unauthenticated requests
   type Authentication_Mode is
     (No_Authentication, Optional_Authentication, Required_Authentication);

   --  High-level response lifecycle observed through this exchange.
   --  @enum Not_Started No response bytes have been written
   --  @enum Completed One complete fixed response was written
   --  @enum Streaming A streaming response owns the connection
   --  @enum Upgraded A protocol upgrade owns the connection
   --  @enum Failed Response completion is unsafe or failed
   type Response_State is
     (Not_Started, Completed, Streaming, Upgraded, Failed);

   --  Borrowed request scope. The object is tagged for Ada prefixed calls such
   --  as X.Text, but concrete helpers do not require dynamic dispatch.
   type Exchange is tagged limited private;

   --  Construct one exchange around values owned by the active handler.
   --  Context is opaque here because routing remains generic over the
   --  application context type. Every borrowed object must outlive the result.
   --  @param Value Parsed request owned by the handler
   --  @param Item Sole-writer HTTP connection owned by the handler
   --  @param Context Opaque address of the application context
   --  @param Peer Connected peer address
   --  @param Token Optional borrowed cancellation token
   --  @param Deadline Absolute monotonic request deadline
   --  @return Request-scoped exchange
   function Create
     (Value    : aliased in out Request;
      Item     : aliased in out Connection;
      Context  : System.Address;
      Peer     : GNAT.Sockets.Sock_Addr_Type;
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

   --  Borrow the raw HTTP connection. Only the active handler may use it and
   --  no child task may write through it.
   --  @param Item Request exchange
   --  @return Borrowed raw connection
   function Connection_Access
     (Item : in out Exchange) return not null access Connection;

   --  Return the opaque address of the generic application context.
   --  @param Item Request exchange
   --  @return Borrowed context address
   function Context_Address (Item : Exchange) return System.Address;

   --  Return the connected peer address supplied by the server adapter.
   --  @param Item Request exchange
   --  @return Peer socket address
   function Peer (Item : Exchange) return GNAT.Sockets.Sock_Addr_Type;

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

   --  Return the route-selected body policy.
   --  @param Item Request exchange
   --  @return Current body policy
   function Body_Policy (Item : Exchange) return Request_Body_Policy;

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

   --  Complete an active streaming response.
   --  @param Item Exchange with an active streaming response
   procedure End_Stream (Item : in out Exchange);

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
   procedure Configure_Route
     (Item            : in out Exchange;
      Name            : String;
      Normalized_Path : String;
      Policy          : Request_Body_Policy;
      Authentication  : Authentication_Mode;
      CORS_Policy     : Natural);

   --  Append one decoded route parameter. Duplicate names or capacity excess
   --  raise Program_Error. Intended for Flyology router packages.
   --  @param Item Request exchange
   --  @param Name Parameter name
   --  @param Value Decoded parameter value
   procedure Add_Parameter
     (Item  : in out Exchange;
      Name  : String;
      Value : String);

private

   type Request_Access is access all Request;
   type Connection_Access_Type is access all Connection;
   type Cancellation_Access is access all Flyology.Cancellation.Token;

   type Parameter_Entry is record
      Name  : Unbounded_String;
      Value : Unbounded_String;
   end record;
   type Parameter_Array is
     array (Positive range 1 .. Max_Path_Parameters) of Parameter_Entry;

   type Exchange is tagged limited record
      Request_Handle    : Request_Access;
      Connection_Handle : Connection_Access_Type;
      Context_Handle    : System.Address := System.Null_Address;
      Peer_Value        : GNAT.Sockets.Sock_Addr_Type;
      Token_Handle      : Cancellation_Access;
      Deadline_Value    : Ada.Real_Time.Time := Ada.Real_Time.Time_Last;
      Route_Value       : Unbounded_String;
      Path_Value        : Unbounded_String;
      Parameters        : Parameter_Array;
      Parameter_Count   : Natural := 0;
      Request_ID_Value  : Unbounded_String;
      Principal_Value   : Unbounded_String;
      Principal_Present : Boolean := False;
      Body_Mode         : Request_Body_Policy := Reject_Body;
      Authentication_Value : Authentication_Mode := No_Authentication;
      CORS_Policy_Value : Natural := 0;
      Extra_Headers     : Unbounded_String;
      Response_Value    : Response_State := Not_Started;
      Status_Value      : Natural := 0;
      Response_Length   : Natural := 0;
   end record;

end Flyology.HTTP.Server.Applications;
