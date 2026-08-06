with Ada.Streams;
with Flyology.IO.Sockets;

--  Resolves host names with nonblocking DNS transports and a bounded cache.
--
--  Example:
--
--     Addresses := Flyology.IO.DNS.Resolve ("example.net", Timeout => 2.0);
package Flyology.IO.DNS is

   --  Address families returned by the resolver.
   --  @enum Any_Family Return available IPv6 and IPv4 addresses
   --  @enum IPv4_Only Query or accept only IPv4 addresses
   --  @enum IPv6_Only Query or accept only IPv6 addresses
   type Family_Preference is (Any_Family, IPv4_Only, IPv6_Only);

   --  Nonempty or null array of resolved internet addresses.
   type Address_Array is
     array (Positive range <>) of Flyology.IO.Sockets.IP_Address;

   --  Caller-supplied numeric DNS endpoints for Resolve_Using.
   type Name_Server_Array is
     array (Positive range <>) of Flyology.IO.Sockets.Endpoint;

   --  Raised for a valid negative DNS answer or family mismatch.
   Name_Not_Found     : exception;
   --  Raised for invalid resolver input or unusable resolver configuration.
   Resolution_Failed  : exception;
   --  Raised when no valid result can be obtained from malformed responses.
   Malformed_Response : exception;
   --  Raised when a member of the resolver's interrupt set becomes readable.
   Operation_Cancelled : exception;

   --  Resolve through numeric servers in Configuration_Path. Search domains,
   --  ndots, retries, rotation, and bounded positive/negative caching are
   --  supported without libc name services. Numeric and localhost names bypass
   --  the file. Negative Timeout means no limit and zero is immediate; one
   --  deadline spans search candidates, family queries, retries, and transport
   --  fallback. Lightweight tasks suspend on socket readiness; native tasks
   --  block their threads. Reading Configuration_Path is a direct metadata
   --  operation and can block the underlying thread.
   --  @param Name Host name, numeric address, or localhost
   --  @param Family Requested result family
   --  @param Timeout Overall deadline interval in seconds
   --  @param Interrupts Readable cancellation sources owned by the caller
   --  @param Configuration_Path Resolver configuration file
   --  @return Resolved addresses in resolver response order
   --  @exception Name_Not_Found No address exists for Name and Family
   --  @exception Resolution_Failed Input or resolver configuration is unusable
   --  @exception Malformed_Response Responses are malformed or inconsistent
   --  @exception Operation_Cancelled An interrupt descriptor is readable
   --  @exception Timeout_Error The overall deadline expires
   --  @exception Device_Error Descriptor polling or transport setup fails
   --  @exception Socket_Error Flyology.IO.Sockets.Socket_Error is raised when
   --     a socket operation fails
   function Resolve
     (Name        : String;
      Family      : Family_Preference := Any_Family;
      Timeout     : Duration := 5.0;
      Interrupts  : Interrupt_Set := No_Interrupts;
      Configuration_Path : String := "/etc/resolv.conf")
      return Address_Array
     with Pre => Interrupts'Length < Max_Wait_Requests;

   --  Resolve through explicit numeric DNS endpoints without search-domain
   --  expansion. Timeout is one deadline across family queries, Attempts, and
   --  transports. Retry_Interval is the per-attempt interval. Lane and
   --  interrupt behavior match Resolve.
   --  @param Name Host name, numeric address, or localhost
   --  @param Name_Servers Numeric UDP/TCP DNS endpoints
   --  @param Family Requested result family
   --  @param Timeout Overall deadline interval in seconds
   --  @param Attempts Attempts made for each query kind
   --  @param Retry_Interval Maximum seconds allocated per attempt
   --  @param Interrupts Readable cancellation sources owned by the caller
   --  @return Resolved addresses in resolver response order
   --  @exception Name_Not_Found No address exists for Name and Family
   --  @exception Resolution_Failed Servers or retry interval are unusable
   --  @exception Malformed_Response Responses are malformed or inconsistent
   --  @exception Operation_Cancelled An interrupt descriptor is readable
   --  @exception Timeout_Error The overall deadline expires
   --  @exception Device_Error Descriptor polling or transport setup fails
   --  @exception Socket_Error Flyology.IO.Sockets.Socket_Error is raised when
   --     a socket operation fails
   function Resolve_Using
     (Name         : String;
      Name_Servers : Name_Server_Array;
      Family       : Family_Preference := Any_Family;
      Timeout      : Duration := 5.0;
      Attempts     : Positive := 2;
      Retry_Interval : Duration := 1.0;
      Interrupts     : Interrupt_Set := No_Interrupts)
      return Address_Array
     with Pre => Interrupts'Length < Max_Wait_Requests;

   --  Atomically remove all process-local positive and negative cache entries.
   --  The cache owns no descriptors or background tasks and is safe to use
   --  concurrently with resolution calls.
   procedure Clear_Cache;

private
   --  Select deterministic transaction identifiers for protocol tests.
   --  @param First First identifier in the deterministic sequence
   procedure Use_Deterministic_Transaction_IDs (First : Natural);
   --  Restore operating-system entropy for transaction identifiers.
   procedure Use_OS_Transaction_IDs;
   --  Parse one response using the production validation path.
   --  @param Packet Wire-format DNS response
   --  @param Expected_ID Expected transaction identifier
   --  @param Expected_Name Expected canonical question name
   --  @param For_IPv6 Parse an AAAA response when True, otherwise A
   --  @exception Malformed_Response Packet validation fails
   procedure Validate_Response_For_Testing
     (Packet       : Ada.Streams.Stream_Element_Array;
      Expected_ID  : Natural;
      Expected_Name : String;
      For_IPv6     : Boolean := False);

end Flyology.IO.DNS;
