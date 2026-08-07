with Ada.Exceptions;
with Ada.Streams;
with Flyology.Buffers;
with Interfaces.C;

--  Owns Flyology's portable socket, Internet-address, and endpoint types.
--  Socket calls use one synchronous API in both task lanes: lightweight
--  callers suspend on readiness while native callers block only their thread.
--  The private socket representation is a limited owning handle. Ownership can
--  move between handles, but it cannot be copied by assignment.
--
--  Interrupt sets compose independent lifecycle sources such as connection
--  close, server shutdown, and per-operation cancellation. This package never
--  consumes or closes an interrupt source, and every owner must outlive the
--  operation.
package Flyology.IO.Sockets is

   --  Address family represented by an Internet address or endpoint.
   type Address_Family is
     (IPv4,  --  Internet Protocol version 4
      IPv6); --  Internet Protocol version 6

   use type Interfaces.C.int;

   --  One address octet.
   subtype Octet is Ada.Streams.Stream_Element;
   --  Four network-order IPv4 octets.
   type IPv4_Octets is array (Positive range 1 .. 4) of Octet;
   --  Sixteen network-order IPv6 octets.
   type IPv6_Octets is array (Positive range 1 .. 16) of Octet;

   --  Portable Internet address value with no dependency on sockaddr layout.
   --  @field Family Internet protocol version
   --  @field V4 Network-order IPv4 octets when Family is IPv4
   --  @field V6 Network-order IPv6 octets when Family is IPv6
   type IP_Address (Family : Address_Family := IPv4) is record
      case Family is
         when IPv4 =>
            V4 : IPv4_Octets;
         when IPv6 =>
            V6 : IPv6_Octets;
      end case;
   end record;

   --  Host-order TCP or UDP port.
   type Port is range 0 .. 65_535;
   --  Port wildcard used when the operating system should choose a local port.
   Any_Port : constant Port := 0;

   --  Host interface scope for an IPv6 endpoint; zero means unspecified.
   type Scope_ID is mod 2**32;

   --  Portable Internet address, port, and optional IPv6 interface scope.
   --  @field Family Internet protocol version
   --  @field Address Internet address in Family
   --  @field Port Host-order TCP or UDP port
   --  @field Scope IPv6 interface scope, or zero when unspecified
   type Endpoint (Family : Address_Family := IPv4) is record
      Address : IP_Address (Family);
      Port    : Flyology.IO.Sockets.Port := Any_Port;
      Scope   : Scope_ID := 0;
   end record;

   --  IPv4 wildcard address.
   Any_IPv4      : constant IP_Address (IPv4) :=
     (Family => IPv4, V4 => (others => 0));
   --  IPv4 loopback address.
   Loopback_IPv4 : constant IP_Address (IPv4) :=
     (Family => IPv4, V4 => (127, 0, 0, 1));
   --  IPv6 wildcard address.
   Any_IPv6      : constant IP_Address (IPv6) :=
     (Family => IPv6, V6 => (others => 0));
   --  IPv6 loopback address.
   Loopback_IPv6 : constant IP_Address (IPv6) :=
     (Family => IPv6, V6 => (16 => 1, others => 0));
   --  Sentinel endpoint used when no Internet endpoint is available.
   No_Endpoint   : constant Endpoint :=
     (Family => IPv4, Address => Any_IPv4, Port => Any_Port, Scope => 0);

   --  Explicit Congestion Notification value carried by a received IP
   --  datagram. Unavailable is retained as a narrow extension seam for an
   --  adopted socket or a future platform backend that cannot expose the IP
   --  traffic-class ancillary value.
   --  @enum ECN_Unavailable No traffic-class ancillary value was supplied
   --  @enum Not_ECT The packet is not ECN-capable
   --  @enum ECT_One The packet carries the ECT(1) codepoint
   --  @enum ECT_Zero The packet carries the ECT(0) codepoint
   --  @enum Congestion_Experienced The packet carries the CE codepoint
   type ECN_Codepoint is
     (ECN_Unavailable,
      Not_ECT,
      ECT_One,
      ECT_Zero,
      Congestion_Experienced);

   --  Addressing and delivery information for one received datagram.
   --  Source and Destination retain the peer and the local address selected by
   --  the kernel, including the bound local port. Original_Length is the whole
   --  datagram length even when only Item'Length bytes were copied.
   --  @field Source Remote source endpoint
   --  @field Destination Local destination endpoint selected by the kernel
   --  @field Original_Length Whole datagram length before caller truncation
   --  @field Truncated True when Original_Length exceeds the receive buffer
   --  @field ECN Received Explicit Congestion Notification value
   type Datagram_Metadata is record
      Source          : Endpoint;
      Destination     : Endpoint;
      Original_Length : Natural := 0;
      Truncated       : Boolean := False;
      ECN             : ECN_Codepoint := ECN_Unavailable;
   end record;

   --  Parse a numeric IPv4 or IPv6 address. Name resolution is deliberately
   --  outside this operation.
   --  @param Text Numeric address text
   --  @return Parsed Internet address
   --  @exception Constraint_Error Text is not a numeric Internet address
   function Parse_IP_Address (Text : String) return IP_Address;

   --  Report whether Text is a numeric address in Family.
   --  @param Text Candidate numeric address
   --  @param Family Required address family
   --  @return True when Text parses in Family
   function Is_IP_Address
     (Text : String; Family : Address_Family) return Boolean;

   --  Format an Internet address without a port.
   --  @param Value Address to format
   --  @return Canonical numeric address text selected by the host
   function Image (Value : IP_Address) return String;

   --  Format an endpoint, enclosing IPv6 addresses in brackets.
   --  @param Value Endpoint to format
   --  @return Numeric address and port
   function Image (Value : Endpoint) return String;

   --  Construct an endpoint from an address and host-order port.
   --  @param Address Internet address
   --  @param Port Host-order port
   --  @param Scope Optional IPv6 interface scope
   --  @return Endpoint containing the supplied values
   function Network_Endpoint
     (Address : IP_Address;
      Port    : Flyology.IO.Sockets.Port;
      Scope   : Scope_ID := 0) return Endpoint
     with Pre => Address.Family = IPv6 or else Scope = 0;

   --  Limited owning operating-system socket handle. A default-initialized
   --  handle is closed. Use Move, Adopt, or Release for explicit ownership
   --  transfer; ordinary assignment is intentionally unavailable.
   type Socket_Type is limited private;

   --  Report whether Socket currently owns an operating-system descriptor.
   --  @param Socket Socket to inspect
   --  @return True when Socket owns an open descriptor
   function Is_Open (Socket : Socket_Type) return Boolean;

   --  Return Socket's operating-system descriptor without transferring
   --  ownership.
   --  @param Socket Socket to inspect
   --  @return Borrowed descriptor; Socket remains its owner
   function Native_Descriptor (Socket : Socket_Type) return Descriptor;

   --  Transfer ownership from Source to a closed Target. Source is closed on
   --  return. Moving a closed Source leaves both handles closed.
   --  @param Source Handle whose ownership transfers
   --  @param Target Closed handle that receives ownership
   --  @exception Program_Error Target is open
   procedure Move (Source : in out Socket_Type; Target : in out Socket_Type)
     with Pre => not Is_Open (Target),
          Post => not Is_Open (Source);

   --  Transport semantics requested when a socket is created.
   --  @enum Socket_Stream Reliable byte stream
   --  @enum Socket_Datagram Message-preserving datagram transport
   type Socket_Mode is (Socket_Stream, Socket_Datagram);

   --  Raised when an operating-system socket operation fails.
   Socket_Error : exception;
   --  Raised when a member of an operation's interrupt set becomes readable.
   Operation_Interrupted : exception;

   --  Stable classification of operating-system socket errors.
   --  @enum Success No error
   --  @enum Resource_Temporarily_Unavailable Operation would block
   --  @enum Interrupted_System_Call Operation was interrupted by a signal
   --  @enum Operation_Now_In_Progress Nonblocking connection is in progress
   --  @enum Operation_Already_In_Progress Connection is already in progress
   --  @enum Transport_Endpoint_Already_Connected Socket is already connected
   --  @enum No_Buffer_Space_Available Kernel socket buffers are exhausted
   --  @enum Other_Error Error has no portable Flyology classification
   type Error_Type is
     (Success,
      Resource_Temporarily_Unavailable,
      Interrupted_System_Call,
      Operation_Now_In_Progress,
      Operation_Already_In_Progress,
      Transport_Endpoint_Already_Connected,
      No_Buffer_Space_Available,
      Other_Error);

   --  Recover the stable error category embedded in Socket_Error.
   --  @param Occurrence Socket_Error occurrence raised by this package
   --  @return Portable error category
   function Resolve_Exception
     (Occurrence : Ada.Exceptions.Exception_Occurrence) return Error_Type;

   --  Create one blocking socket. Task-aware operations configure it as
   --  nonblocking before use.
   --  @param Socket Newly created socket owned by the caller
   --  @param Family Internet address family
   --  @param Mode Stream or datagram semantics
   --  @exception Socket_Error Creation or descriptor configuration fails
   --  @exception Program_Error Socket is already open
   procedure Create_Socket
     (Socket : in out Socket_Type;
      Family : Address_Family := IPv4;
      Mode   : Socket_Mode := Socket_Stream)
     with Pre => not Is_Open (Socket),
          Post => Is_Open (Socket);

   --  Create a connected local socket pair for IPC and testing.
   --  @param Left First socket owned by the caller
   --  @param Right Second socket owned by the caller
   --  @param Mode Stream or datagram semantics
   --  @exception Socket_Error Creation or descriptor configuration fails
   --  @exception Program_Error Either target is open or both targets alias
   procedure Create_Socket_Pair
     (Left  : in out Socket_Type;
      Right : in out Socket_Type;
      Mode  : Socket_Mode := Socket_Stream)
     with Pre => not Is_Open (Left) and then not Is_Open (Right),
          Post => Is_Open (Left) and then Is_Open (Right);

   --  Close Socket. The handle becomes closed even when close reports an error
   --  because descriptor state is no longer safely reusable.
   --  @param Socket Sole closing owner
   --  @exception Socket_Error Close fails
   procedure Close_Socket (Socket : in out Socket_Type)
     with Post => not Is_Open (Socket);

   --  Transfer one descriptor into a closed socket handle. Source becomes
   --  Invalid_Descriptor. The caller must ensure Source is the sole closing
   --  owner represented by that descriptor.
   --  @param Source Descriptor whose ownership transfers
   --  @param Target Closed socket handle that receives ownership
   --  @exception Program_Error Source is invalid or Target is open
   procedure Adopt (Source : in out Descriptor; Target : in out Socket_Type)
     with Pre => Source >= 0 and then not Is_Open (Target),
          Post =>
            Source = Invalid_Descriptor
              and then Is_Open (Target)
              and then Native_Descriptor (Target) = Source'Old;

   --  Transfer Socket's descriptor without closing it. Source is closed on
   --  return; Target is Invalid_Descriptor when Source was already closed.
   --  @param Source Socket whose ownership transfers
   --  @param Target Descriptor that receives ownership
   procedure Release (Source : in out Socket_Type; Target : out Descriptor)
     with Post => not Is_Open (Source);

   --  Enable nonblocking and close-on-exec modes.
   --  @param Socket Open socket to configure
   --  @exception Socket_Error Descriptor configuration fails
   procedure Prepare (Socket : Socket_Type);

   --  Enable destination-address and ECN ancillary delivery on an Internet
   --  datagram socket. Create_Socket does this automatically for
   --  Socket_Datagram; this idempotent operation is provided for adopted
   --  datagram descriptors.
   --  @param Socket Open IPv4 or IPv6 datagram socket
   --  @exception Socket_Error Address or traffic-class metadata setup fails
   procedure Enable_Datagram_Metadata (Socket : Socket_Type);

   --  Supported socket option names.
   --  @enum Reuse_Address Permit local address reuse
   --  @enum Receive_Timeout Bound blocking receives in native setup code
   type Option_Name is (Reuse_Address, Receive_Timeout);
   --  Socket options supported by Flyology's portable layer.
   --  @field Name Selected option
   --  @field Enabled Reuse_Address setting
   --  @field Timeout Receive_Timeout interval in seconds
   type Option_Type (Name : Option_Name := Reuse_Address) is record
      case Name is
         when Reuse_Address =>
            Enabled : Boolean := False;
         when Receive_Timeout =>
            Timeout : Duration := 0.0;
      end case;
   end record;

   --  Protocol layer for supported socket options. Only SOL_SOCKET is exposed.
   --  @enum Socket_Level Operating-system socket option level
   type Option_Level is (Socket_Level);

   --  Apply one supported socket option.
   --  @param Socket Open socket
   --  @param Option Option value
   --  @exception Socket_Error setsockopt fails
   procedure Set_Socket_Option
     (Socket : Socket_Type; Option : Option_Type);

   --  Apply one supported option at its explicit protocol level.
   --  @param Socket Open socket
   --  @param Level Socket option level
   --  @param Option Option value
   --  @exception Socket_Error setsockopt fails
   procedure Set_Socket_Option
     (Socket : Socket_Type;
      Level  : Option_Level;
      Option : Option_Type);

   --  Bind Socket to a local endpoint.
   --  @param Socket Open socket
   --  @param Address Local endpoint
   --  @exception Socket_Error bind fails
   procedure Bind_Socket (Socket : Socket_Type; Address : Endpoint);

   --  Mark a stream socket as a listener.
   --  @param Socket Bound stream socket
   --  @param Length Maximum pending connection count
   --  @exception Socket_Error listen fails
   procedure Listen_Socket (Socket : Socket_Type; Length : Positive := 15);

   --  Return Socket's local endpoint.
   --  @param Socket Open Internet socket
   --  @return Local endpoint
   --  @exception Socket_Error getsockname fails or is not an Internet address
   function Get_Socket_Name (Socket : Socket_Type) return Endpoint;

   --  Return Socket's peer endpoint.
   --  @param Socket Connected Internet socket
   --  @return Peer endpoint
   --  @exception Socket_Error getpeername fails or is not an Internet address
   function Get_Peer_Name (Socket : Socket_Type) return Endpoint;

   --  Connect without readiness orchestration or a deadline. Intended for
   --  blocking native setup and datagram peer selection; use Connect for
   --  task-aware streams. A signal that interrupts the attempt does not abort
   --  it: the kernel keeps establishing the connection, so this call then
   --  waits for the socket to resolve and reports the pending socket error.
   --  That wait blocks the calling native pthread, or suspends only the
   --  calling lightweight task, until the handshake succeeds or fails.
   --  @param Socket Open socket
   --  @param Server Destination endpoint
   --  @exception Socket_Error connect fails or the connection is refused
   --  @exception Device_Error Readiness polling fails
   procedure Connect_Socket (Socket : Socket_Type; Server : Endpoint);

   --  Receive one immediate chunk without readiness orchestration.
   --  @param Socket Open socket
   --  @param Item Destination buffer
   --  @param Last Last element received, or Item'First - 1 on closure
   --  @exception Socket_Error recv fails
   procedure Receive_Socket
     (Socket : Socket_Type;
      Item   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset);

   --  Receive one datagram and its source endpoint. From is No_Endpoint when
   --  the socket source has no Internet endpoint, including an AF_UNIX socket
   --  pair.
   --  @param Socket Open datagram socket
   --  @param Item Destination buffer
   --  @param Last Last element received
   --  @param From Source endpoint
   --  @exception Socket_Error recvfrom fails
   procedure Receive_Socket
     (Socket : Socket_Type;
      Item   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      From   : out Endpoint);

   --  Send one immediate chunk without readiness orchestration.
   --  @param Socket Open connected socket
   --  @param Item Source buffer
   --  @param Last Last element sent
   --  @exception Socket_Error send fails
   procedure Send_Socket
     (Socket : Socket_Type;
      Item   : Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset);

   --  Send one datagram to a destination endpoint.
   --  @param Socket Open datagram socket
   --  @param Item Source buffer
   --  @param Last Last element sent
   --  @param To Destination endpoint
   --  @exception Socket_Error sendto fails
   procedure Send_Socket
     (Socket : Socket_Type;
      Item   : Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      To     : Endpoint);

   --  Portable descriptor-control request names.
   --  @enum Non_Blocking_IO Enable or disable nonblocking mode
   --  @enum N_Bytes_To_Read Query the immediately readable byte count
   type Request_Name is (Non_Blocking_IO, N_Bytes_To_Read);
   --  Portable descriptor-control requests.
   --  @field Name Selected request
   --  @field Enabled Non_Blocking_IO setting
   --  @field Size N_Bytes_To_Read query result
   type Request_Type (Name : Request_Name) is record
      case Name is
         when Non_Blocking_IO =>
            Enabled : Boolean := False;
         when N_Bytes_To_Read =>
            Size : Natural := 0;
      end case;
   end record;

   --  Apply or query a descriptor-control request.
   --  @param Socket Open socket
   --  @param Request Request and returned query value
   --  @exception Socket_Error Configuration or query fails
   procedure Control_Socket
     (Socket : Socket_Type; Request : in out Request_Type);

   --  Compatibility status for bounded native accepts.
   --  @enum Completed A connection was accepted
   --  @enum Expired The accept deadline expired
   type Selector_Status is (Completed, Expired);

   --  Accept with a bounded task-aware wait and return rather than raise on
   --  timeout.
   --  @param Server Open listener
   --  @param Socket Accepted socket when Status is Completed
   --  @param Address Accepted peer endpoint
   --  @param Timeout Maximum wait in seconds
   --  @param Status Completion status
   --  @exception Program_Error Socket is already open
   procedure Accept_Socket
     (Server  : Socket_Type;
      Socket  : in out Socket_Type;
      Address : out Endpoint;
      Timeout : Duration;
      Status  : out Selector_Status)
     with Pre => not Is_Open (Socket),
          Post => Is_Open (Socket) = (Status = Completed);

   --  Receive one available chunk with task-aware readiness and one deadline.
   --  @param Socket Open connected socket
   --  @param Item Destination buffer
   --  @param Last Last element received, or Item'First - 1 on orderly closure
   --  @param Timeout Deadline interval in seconds
   --  @param Interrupts Independent readable lifecycle wake descriptors
   --  @exception Timeout_Error The deadline expires before readiness
   --  @exception Operation_Interrupted An interrupt descriptor is readable
   --  @exception Device_Error Readiness polling fails
   --  @exception Socket_Error Socket receive or setup fails
   procedure Receive
     (Socket     : Socket_Type;
      Item       : out Ada.Streams.Stream_Element_Array;
      Last       : out Ada.Streams.Stream_Element_Offset;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
     with Pre => Interrupts'Length < Max_Wait_Requests;

   --  Receive one UDP datagram with task-aware readiness and one deadline.
   --  Source and local destination endpoints are returned atomically with the
   --  payload. Last denotes bytes copied into Item; Metadata retains the whole
   --  datagram length and states whether the payload was truncated. A
   --  zero-length datagram is consumed and returns Last = Item'First - 1.
   --  Lightweight callers suspend only their task; native callers may block
   --  only their pthread. Created datagram sockets already have the required
   --  ancillary options; call Enable_Datagram_Metadata after Adopt.
   --  @param Socket Open IPv4 or IPv6 datagram socket
   --  @param Item Destination buffer, which may be empty
   --  @param Last Last copied element, or Item'First - 1 when none was copied
   --  @param Metadata Peer, local destination, length, truncation, and ECN
   --  @param Timeout Deadline interval in seconds
   --  @param Interrupts Independent readable lifecycle wake descriptors
   --  @exception Timeout_Error The deadline expires before a datagram arrives
   --  @exception Operation_Interrupted An interrupt descriptor is readable
   --  @exception Device_Error Readiness polling fails
   --  @exception Socket_Error Metadata setup or recvmsg fails
   procedure Receive_Datagram
     (Socket     : Socket_Type;
      Item       : out Ada.Streams.Stream_Element_Array;
      Last       : out Ada.Streams.Stream_Element_Offset;
      Metadata   : out Datagram_Metadata;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
     with Pre => Interrupts'Length < Max_Wait_Requests;

   --  Receive directly into an acquired unique buffer and replace its readable
   --  length. The buffer remains solely owned by the caller while the kernel
   --  borrows its storage.
   --  @param Socket Open connected socket
   --  @param Item Acquired destination buffer
   --  @param Received Number of bytes received; zero on orderly closure
   --  @param Timeout Deadline interval in seconds
   --  @param Interrupts Independent readable lifecycle wake descriptors
   --  @exception Timeout_Error The deadline expires before readiness
   --  @exception Operation_Interrupted An interrupt descriptor is readable
   --  @exception Device_Error Readiness polling fails
   --  @exception Socket_Error Socket receive or setup fails
   procedure Receive
     (Socket     : Socket_Type;
      Item       : in out Flyology.Buffers.Unique_Buffer;
      Received   : out Natural;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
     with Pre => Flyology.Buffers.Has_Buffer (Item)
       and then Interrupts'Length < Max_Wait_Requests,
          Post => Flyology.Buffers.Length (Item) = Received;

   --  Fill Item or raise. One Timeout deadline spans every partial receive.
   --  @param Socket Open connected socket
   --  @param Item Destination buffer to fill
   --  @param Timeout Deadline interval in seconds
   --  @param Interrupts Independent readable lifecycle wake descriptors
   --  @exception Timeout_Error The shared deadline expires
   --  @exception Operation_Interrupted An interrupt descriptor is readable
   --  @exception Device_Error Polling fails or peer closes before completion
   --  @exception Socket_Error Socket receive or setup fails
   procedure Receive_Exactly
     (Socket     : Socket_Type;
      Item       : out Ada.Streams.Stream_Element_Array;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
     with Pre => Interrupts'Length < Max_Wait_Requests;

   --  Send one available chunk with task-aware readiness and one deadline.
   --  @param Socket Open connected socket
   --  @param Item Source buffer
   --  @param Last Last element sent, or Item'First - 1 if none
   --  @param Timeout Deadline interval in seconds
   --  @param Interrupts Independent readable lifecycle wake descriptors
   --  @exception Timeout_Error The deadline expires before readiness
   --  @exception Operation_Interrupted An interrupt descriptor is readable
   --  @exception Device_Error Readiness polling fails
   --  @exception Socket_Error Socket send or setup fails
   procedure Send
     (Socket     : Socket_Type;
      Item       : Ada.Streams.Stream_Element_Array;
      Last       : out Ada.Streams.Stream_Element_Offset;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
     with Pre => Interrupts'Length < Max_Wait_Requests;

   --  Send one UDP datagram to Destination with task-aware readiness and one
   --  deadline. The kernel selects the local source address. Empty Item sends
   --  a zero-length datagram. A successful call sends the complete datagram.
   --  @param Socket Open IPv4 or IPv6 datagram socket
   --  @param Item Datagram payload, which may be empty
   --  @param Last Last element sent, or Item'First - 1 for an empty datagram
   --  @param Destination Remote destination endpoint
   --  @param Timeout Deadline interval in seconds
   --  @param Interrupts Independent readable lifecycle wake descriptors
   --  @exception Timeout_Error The deadline expires before readiness
   --  @exception Operation_Interrupted An interrupt descriptor is readable
   --  @exception Device_Error Readiness polling fails or a partial send occurs
   --  @exception Socket_Error Socket setup or sendmsg fails
   procedure Send_Datagram
     (Socket      : Socket_Type;
      Item        : Ada.Streams.Stream_Element_Array;
      Last        : out Ada.Streams.Stream_Element_Offset;
      Destination : Endpoint;
      Timeout     : Duration := Infinite;
      Interrupts  : Interrupt_Set := No_Interrupts)
     with Pre => Interrupts'Length < Max_Wait_Requests;

   --  Send one UDP datagram while selecting its local source endpoint. Source
   --  normally comes from received Metadata.Destination. Its address and IPv6
   --  scope select sendmsg packet information; its port must equal Socket's
   --  bound local port because a per-datagram port cannot be selected.
   --  Empty Item sends a zero-length datagram. A successful call sends the
   --  complete datagram.
   --  @param Socket Open IPv4 or IPv6 datagram socket
   --  @param Item Datagram payload, which may be empty
   --  @param Last Last element sent, or Item'First - 1 for an empty datagram
   --  @param Destination Remote destination endpoint
   --  @param Source Local source endpoint and interface selection
   --  @param Timeout Deadline interval in seconds
   --  @param Interrupts Independent readable lifecycle wake descriptors
   --  @exception Timeout_Error The deadline expires before readiness
   --  @exception Operation_Interrupted An interrupt descriptor is readable
   --  @exception Device_Error Readiness polling fails or a partial send occurs
   --  @exception Socket_Error Source validation, setup, or sendmsg fails
   procedure Send_Datagram
     (Socket      : Socket_Type;
      Item        : Ada.Streams.Stream_Element_Array;
      Last        : out Ada.Streams.Stream_Element_Offset;
      Destination : Endpoint;
      Source      : Endpoint;
      Timeout     : Duration := Infinite;
      Interrupts  : Interrupt_Set := No_Interrupts)
     with Pre =>
       Source.Family = Destination.Family
         and then Interrupts'Length < Max_Wait_Requests;

   --  Send one available chunk directly from a unique buffer. No Flyology
   --  payload copy is made and Item remains owned by the caller.
   --  @param Socket Open connected socket
   --  @param Item Acquired source buffer
   --  @param Sent Number of bytes sent
   --  @param Timeout Deadline interval in seconds
   --  @param Interrupts Independent readable lifecycle wake descriptors
   --  @exception Timeout_Error The deadline expires before readiness
   --  @exception Operation_Interrupted An interrupt descriptor is readable
   --  @exception Device_Error Readiness polling fails
   --  @exception Socket_Error Socket send or setup fails
   procedure Send
     (Socket     : Socket_Type;
      Item       : Flyology.Buffers.Unique_Buffer;
      Sent       : out Natural;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
     with Pre => Flyology.Buffers.Has_Buffer (Item)
       and then Interrupts'Length < Max_Wait_Requests;

   --  Send all of Item or raise. One Timeout deadline spans every partial
   --  send.
   --  @param Socket Open connected socket
   --  @param Item Source buffer to send completely
   --  @param Timeout Deadline interval in seconds
   --  @param Interrupts Independent readable lifecycle wake descriptors
   --  @exception Timeout_Error The shared deadline expires
   --  @exception Operation_Interrupted An interrupt descriptor is readable
   --  @exception Device_Error Polling fails or no forward progress is made
   --  @exception Socket_Error Socket send or setup fails
   procedure Send_All
     (Socket     : Socket_Type;
      Item       : Ada.Streams.Stream_Element_Array;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
     with Pre => Interrupts'Length < Max_Wait_Requests;

   --  Send a unique buffer's complete readable payload without a Flyology
   --  payload copy. Item remains owned until the synchronous call returns.
   --  @param Socket Open connected socket
   --  @param Item Acquired source buffer
   --  @param Timeout Deadline interval in seconds
   --  @param Interrupts Independent readable lifecycle wake descriptors
   --  @exception Timeout_Error The shared deadline expires
   --  @exception Operation_Interrupted An interrupt descriptor is readable
   --  @exception Device_Error Polling fails or no forward progress is made
   --  @exception Socket_Error Socket send or setup fails
   procedure Send_All
     (Socket     : Socket_Type;
      Item       : Flyology.Buffers.Unique_Buffer;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
     with Pre => Flyology.Buffers.Has_Buffer (Item)
       and then Interrupts'Length < Max_Wait_Requests;

   --  Accept one connection and configure it for Flyology I/O. Transient
   --  admission errors are retried and descriptor pressure uses bounded
   --  interruptible backoff.
   --  @param Server Open listener; ownership is retained
   --  @param Socket Newly accepted socket owned by the caller
   --  @param Address Accepted peer endpoint
   --  @param Timeout Deadline interval in seconds
   --  @param Interrupts Independent readable lifecycle wake descriptors
   --  @exception Timeout_Error The deadline expires before an accept
   --  @exception Operation_Interrupted An interrupt descriptor is readable
   --  @exception Device_Error Readiness polling fails
   --  @exception Socket_Error Accept or setup fails
   --  @exception Program_Error Socket is already open
   procedure Accept_Connection
     (Server     : Socket_Type;
      Socket     : in out Socket_Type;
      Address    : out Endpoint;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
     with Pre =>
       not Is_Open (Socket) and then
       Interrupts'Length < Max_Wait_Requests,
       Post => Is_Open (Socket);

   --  Connect Socket to Server with task-aware readiness and one deadline. An
   --  attempt that the kernel is still establishing, including one reported as
   --  interrupted by a signal, resolves through the same deadline.
   --  @param Socket Open unconnected socket; ownership is retained
   --  @param Server Destination endpoint
   --  @param Timeout Deadline interval in seconds
   --  @param Interrupts Independent readable lifecycle wake descriptors
   --  @exception Timeout_Error The deadline expires before connection
   --  @exception Operation_Interrupted An interrupt descriptor is readable
   --  @exception Device_Error Readiness polling fails
   --  @exception Socket_Error Connect or setup fails
   procedure Connect
     (Socket     : Socket_Type;
      Server     : Endpoint;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
     with Pre => Interrupts'Length < Max_Wait_Requests;

private
   type Socket_Type is limited record
      Value : Interfaces.C.int := -1;
   end record;
end Flyology.IO.Sockets;
