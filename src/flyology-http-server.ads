with Ada.Streams;
with Ada.Strings.Unbounded;
with Flyology.Cancellation;

--  Provides a bounded HTTP/1.1 connection engine over a task-aware transport.
--  The engine supports persistent requests, fixed-length request and response
--  bodies, chunked server-sent events, and RFC 6455 WebSocket upgrades.
package Flyology.HTTP.Server is

   --  Maximum bytes before the terminating empty request-header line.
   Max_Header_Bytes : constant := 16 * 1_024;
   --  Maximum fixed-length request representation.
   Max_Request_Body : constant := 1_024 * 1_024;
   --  Maximum accepted or generated WebSocket frame payload.
   Max_WebSocket_Frame : constant := 1_024 * 1_024;

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
   --  Report whether a comma-separated header contains a token.
   --  @param Item Request to inspect
   --  @param Name Header field name
   --  @param Value Token sought case-insensitively
   --  @return True when the token occurs as a complete list member
   function Header_Has_Token
     (Item : Request; Name : String; Value : String) return Boolean;
   --  Return the fixed-length request body.
   --  @param Item Request to inspect
   --  @return Body bytes represented as an Ada String
   function Content (Item : Request) return String;

   --  HTTP/WebSocket state for one transport. The object and transport must
   --  remain owned by one handler at a time. Buffered pipelined input is kept
   --  between Read_Request calls.
   --  @field Channel Borrowed transport kept alive for this object
   type Connection (Channel : not null access Transport'Class) is limited
     private;

   --  Read and parse the next request. Header and body limits are enforced
   --  before allocation grows beyond their public bounds. One monotonic
   --  Timeout covers the complete header and fixed-length body, so incremental
   --  progress cannot extend a slow client's deadline. HTTP/1.1 requires Host.
   --  Transfer-Encoding request bodies are currently rejected.
   --  @param Item HTTP connection
   --  @param Value Parsed request on success
   --  @param Peer_Closed True only when the peer closes between requests
   --  @param Timeout Deadline used by each transport receive
   --  @param Token Optional cancellation source
   --  @exception Protocol_Error Input is malformed, oversized, or unsupported
   procedure Read_Request
     (Item        : in out Connection;
      Value       : out Request;
      Peer_Closed : out Boolean;
      Timeout     : Duration := 30.0;
      Token       : access Flyology.Cancellation.Token := null);

   --  Send one complete fixed-length response. Reason is derived from Status.
   --  Extra_Headers is a sequence of complete CRLF-terminated fields and must
   --  not contain an empty line. HEAD sends the declared body length without
   --  body bytes. Connection persistence follows the request unless Close is
   --  true.
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
   --  repeated data fields. Empty Event, Id, and Retry values are omitted.
   --  @param Item Active SSE response
   --  @param Data Event data
   --  @param Event Optional event type
   --  @param Id Optional event id
   --  @param Retry Optional client retry interval in milliseconds
   --  @param Timeout Transport send deadline
   --  @param Token Optional cancellation source
   procedure Send_Event
     (Item    : in out Connection;
      Data    : String;
      Event   : String := "";
      Id      : String := "";
      Retry   : Natural := 0;
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
   --  @enum Text_Frame UTF-8 text payload; validation is application policy
   --  @enum Binary_Frame Binary payload
   type WebSocket_Data_Kind is (Text_Frame, Binary_Frame);

   --  Perform an RFC 6455 server upgrade for Request. The client key and
   --  required Upgrade, Connection, and version fields are validated.
   --  @param Item HTTP connection
   --  @param Value Request being upgraded
   --  @param Protocol Optional selected subprotocol token
   --  @param Timeout Transport send deadline
   --  @param Token Optional cancellation source
   --  @exception Protocol_Error Request is not a valid version 13 upgrade
   procedure Accept_WebSocket
     (Item     : in out Connection;
      Value    : Request;
      Protocol : String := "";
      Timeout  : Duration := 30.0;
      Token    : access Flyology.Cancellation.Token := null);

   --  Receive one complete unfragmented client message. One monotonic Timeout
   --  covers the whole frame. Control ping frames are answered automatically
   --  and close frames set Closed. Client frames must be masked. Fragmented
   --  messages are rejected.
   --  @param Item Upgraded WebSocket connection
   --  @param Kind Text or binary message kind
   --  @param Data Message payload
   --  @param Closed True after a valid close frame
   --  @param Timeout Transport receive/send deadline
   --  @param Token Optional cancellation source
   procedure Receive_WebSocket
     (Item    : in out Connection;
      Kind    : out WebSocket_Data_Kind;
      Data    : out Ada.Strings.Unbounded.Unbounded_String;
      Closed  : out Boolean;
      Timeout : Duration := 30.0;
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

   type Connection_State is (Reading_HTTP, Streaming_SSE, WebSocket, Terminal);

   type Connection (Channel : not null access Transport'Class) is limited
     record
      Pending          : Unbounded_String;
      State            : Connection_State := Reading_HTTP;
      Request_Close    : Boolean := False;
      Response_Begun   : Boolean := False;
      Current_Is_Head  : Boolean := False;
   end record;

end Flyology.HTTP.Server;
