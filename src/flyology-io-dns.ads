with Ada.Streams;
with Ada.Real_Time;
with Flyology.Cancellation;
with Flyology.IO.Sockets;
with Flyology.Operations;
with Interfaces;

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
   type Address_Array is array (Positive range <>) of Flyology.IO.Sockets.IP_Address;

   --  Caller-supplied numeric DNS endpoints for Resolve_Using.
   type Name_Server_Array is array (Positive range <>) of Flyology.IO.Sockets.Endpoint;

   --  Raised for a valid negative DNS answer or family mismatch.
   Name_Not_Found      : exception;
   --  Raised for invalid resolver input or unusable resolver configuration.
   Resolution_Failed   : exception;
   --  Raised when no valid result can be obtained from malformed responses.
   Malformed_Response  : exception;
   --  Raised when every name server answers with a failure response code.
   --  Unlike Timeout_Error this outcome leaves the caller's deadline unspent.
   Name_Server_Failure : exception;
   --  Raised when a member of the resolver's interrupt set becomes readable.
   Operation_Cancelled : exception;

   --  Resolve through numeric servers in Configuration_Path. Search domains,
   --  ndots, retries, rotation, and bounded positive/negative caching are
   --  supported without libc name services. Numeric and localhost names bypass
   --  the file. Negative Timeout means no limit and zero is immediate; one
   --  deadline spans search candidates, family queries, retries, and transport
   --  fallback. A negative answer or a server-failure response code moves on
   --  to the next search candidate. Lightweight tasks suspend on socket
   --  readiness; native tasks block their threads. Reading Configuration_Path
   --  is a direct metadata operation and can block the underlying thread.
   --  @param Name Host name, numeric address, or localhost
   --  @param Family Requested result family
   --  @param Timeout Overall deadline interval in seconds
   --  @param Interrupts Readable cancellation sources owned by the caller
   --  @param Configuration_Path Resolver configuration file
   --  @return Resolved addresses in resolver response order
   --  @exception Name_Not_Found No address exists for Name and Family
   --  @exception Resolution_Failed Input or resolver configuration is unusable
   --  @exception Malformed_Response Responses are malformed or inconsistent
   --  @exception Name_Server_Failure Every candidate ends in a server failure
   --  @exception Operation_Cancelled An interrupt descriptor is readable
   --  @exception Timeout_Error The overall deadline expires or every transport
   --     fails without an answer
   --  @exception Device_Error Descriptor polling or transport setup fails
   --  @exception Socket_Error Flyology.IO.Sockets.Socket_Error is raised when
   --     a socket operation fails
   function Resolve
     (Name               : String;
      Family             : Family_Preference := Any_Family;
      Timeout            : Duration := 5.0;
      Interrupts         : Interrupt_Set := No_Interrupts;
      Configuration_Path : String := "/etc/resolv.conf") return Address_Array
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
   --  @exception Name_Server_Failure Every name server reports a failure
   --  @exception Operation_Cancelled An interrupt descriptor is readable
   --  @exception Timeout_Error The overall deadline expires or every transport
   --     fails without an answer
   --  @exception Device_Error Descriptor polling or transport setup fails
   --  @exception Socket_Error Flyology.IO.Sockets.Socket_Error is raised when
   --     a socket operation fails
   function Resolve_Using
     (Name           : String;
      Name_Servers   : Name_Server_Array;
      Family         : Family_Preference := Any_Family;
      Timeout        : Duration := 5.0;
      Attempts       : Positive := 2;
      Retry_Interval : Duration := 1.0;
      Interrupts     : Interrupt_Set := No_Interrupts) return Address_Array
   with Pre => Interrupts'Length < Max_Wait_Requests;

   --  Immutable bounded resolver configuration loaded before scoped DNS work
   --  starts. Loading may perform synchronous filesystem metadata and data
   --  operations; resolving from a snapshot performs no configuration I/O.
   type Resolver_Configuration is limited private;

   --  Load numeric servers, search domains, ndots, attempts, retry interval,
   --  and rotation from one resolver configuration file. The returned value
   --  owns no descriptor, task, or heap allocation and may be shared by
   --  concurrent operations after initialization.
   --  @param Configuration_Path Resolver configuration file
   --  @return Immutable bounded resolver configuration snapshot
   --  @exception Resolution_Failed The configuration is too large or has no
   --     usable numeric name server
   --  @exception File_Error Flyology.IO.Files reports a file operation error
   function Load_Configuration
     (Configuration_Path : String := "/etc/resolv.conf") return Resolver_Configuration;

   --  Opaque build-in-place storage for a scoped resolver and its socket child.
   --  @exclude
   --  @field Owner Completion set shared with the child operation
   type Resolve_Operation_State (Owner : not null access Flyology.Operations.Completion_Set'Class) is
     limited private;

   --  Scoped DNS resolution result. The operation copies its host name and
   --  selected configuration into bounded storage. Internal socket children
   --  consume hidden completion-set slots while Continue_After keeps their
   --  identities out of user batches and gates.
   --  @field Owner Completion set that owns the root and hidden child slots
   --  @field State Opaque build-in-place resolver and child storage
   type Resolve_Operation (Owner : not null access Flyology.Operations.Completion_Set'Class) is
     new Flyology.Operations.Operation (Owner)
   with record
      State : Resolve_Operation_State (Owner);
   end record;

   --  Start scoped resolution using a preloaded configuration snapshot.
   --  Deadline is one absolute monotonic deadline across search expansion,
   --  family queries, retries, and UDP-to-TCP fallback. Time_Last is
   --  unlimited. Token is borrowed until terminal publication; its readable
   --  wake source is passed through every pending socket child. Configuration
   --  is copied synchronously and need not outlive the returned operation. An
   --  already-requested Token or expired Deadline completes without a socket.
   --  Starting a network query needs one additional hidden set slot; failure
   --  to reserve it transactionally rolls back the root operation.
   --  @param Set Completion set that owns the root and hidden child slots
   --  @param Name Host name, numeric address, or localhost copied at start
   --  @param Configuration Preloaded resolver configuration copied at start
   --  @param Family Requested result family
   --  @param Deadline Absolute monotonic deadline
   --  @param Token Optional cancellation source that outlives the operation
   --  @return Started limited resolve operation
   --  @exception Capacity_Error The root or first hidden child cannot reserve
   --     a completion-set slot
   function Resolve
     (Set           : not null access Flyology.Operations.Completion_Set'Class;
      Name          : String;
      Configuration : not null access constant Resolver_Configuration;
      Family        : Family_Preference := Any_Family;
      Deadline      : Ada.Real_Time.Time := Ada.Real_Time.Time_Last;
      Token         : access Flyology.Cancellation.Token := null) return Resolve_Operation;

   --  Start or restart scoped resolution in an established operation object.
   --  This form lets a parent provider compose DNS through Continue_After.
   --  A first-child Capacity_Error leaves Operation fresh and releases every
   --  token borrow and socket resource.
   --  @param Name Host name, numeric address, or localhost copied at start
   --  @param Configuration Preloaded resolver configuration copied at start
   --  @param Family Requested result family
   --  @param Deadline Absolute monotonic deadline
   --  @param Token Optional cancellation source that outlives the operation
   --  @param Operation Fresh, released, or consumed resolve operation
   --  @exception Capacity_Error The root or first hidden child cannot reserve
   --     a completion-set slot
   procedure Resolve
     (Name          : String;
      Configuration : not null access constant Resolver_Configuration;
      Family        : Family_Preference := Any_Family;
      Deadline      : Ada.Real_Time.Time := Ada.Real_Time.Time_Last;
      Token         : access Flyology.Cancellation.Token := null;
      Operation     : in out Resolve_Operation)
   with
     Pre =>
       not Flyology.Operations.Is_Active (Operation) and then not Flyology.Operations.Is_Terminal (Operation);

   --  Start scoped resolution through explicit numeric DNS endpoints without
   --  search-domain expansion. Endpoints and retry policy are copied at start.
   --  An already-requested Token or expired Deadline completes without a
   --  socket. A network query requires one hidden completion-set slot.
   --  @param Set Completion set that owns the root and hidden child slots
   --  @param Name Host name, numeric address, or localhost copied at start
   --  @param Name_Servers Numeric UDP/TCP DNS endpoints copied at start
   --  @param Family Requested result family
   --  @param Deadline Absolute monotonic deadline
   --  @param Attempts Attempts made for each query kind
   --  @param Retry_Interval Maximum seconds allocated per attempt
   --  @param Token Optional cancellation source that outlives the operation
   --  @return Started limited resolve operation
   --  @exception Capacity_Error The root or first hidden child cannot reserve
   --     a completion-set slot
   function Resolve_Using
     (Set            : not null access Flyology.Operations.Completion_Set'Class;
      Name           : String;
      Name_Servers   : Name_Server_Array;
      Family         : Family_Preference := Any_Family;
      Deadline       : Ada.Real_Time.Time := Ada.Real_Time.Time_Last;
      Attempts       : Positive := 2;
      Retry_Interval : Duration := 1.0;
      Token          : access Flyology.Cancellation.Token := null) return Resolve_Operation;

   --  Start or restart explicit-server scoped resolution in an established
   --  operation object. A first-child Capacity_Error rolls back every resource
   --  and leaves Operation fresh.
   --  @param Name Host name, numeric address, or localhost copied at start
   --  @param Name_Servers Numeric UDP/TCP DNS endpoints copied at start
   --  @param Family Requested result family
   --  @param Deadline Absolute monotonic deadline
   --  @param Attempts Attempts made for each query kind
   --  @param Retry_Interval Maximum seconds allocated per attempt
   --  @param Token Optional cancellation source that outlives the operation
   --  @param Operation Fresh, released, or consumed resolve operation
   --  @exception Capacity_Error The root or first hidden child cannot reserve
   --     a completion-set slot
   procedure Resolve_Using
     (Name           : String;
      Name_Servers   : Name_Server_Array;
      Family         : Family_Preference := Any_Family;
      Deadline       : Ada.Real_Time.Time := Ada.Real_Time.Time_Last;
      Attempts       : Positive := 2;
      Retry_Interval : Duration := 1.0;
      Token          : access Flyology.Cancellation.Token := null;
      Operation      : in out Resolve_Operation)
   with
     Pre =>
       not Flyology.Operations.Is_Active (Operation) and then not Flyology.Operations.Is_Terminal (Operation);

   --  Consume one terminal scoped DNS result. Provider failures are retained
   --  until this call and use the same exception classes as synchronous DNS.
   --  @param Operation Terminal resolve operation
   --  @return Resolved addresses in resolver response order
   --  @exception Name_Not_Found No address exists for the selected family
   --  @exception Resolution_Failed Input or resolver policy is unusable
   --  @exception Malformed_Response No valid response can be obtained
   --  @exception Name_Server_Failure Every candidate ends in server failure
   --  @exception Operation_Cancelled Token or explicit cancellation wins
   --  @exception Timeout_Error The absolute deadline expires
   --  @exception Device_Error Readiness polling fails
   --  @exception Socket_Error Flyology.IO.Sockets.Socket_Error is retained
   function Finish (Operation : in out Resolve_Operation) return Address_Array
   with Pre => Flyology.Operations.Is_Terminal (Operation);

   --  Atomically remove all process-local positive and negative cache entries.
   --  The cache owns no descriptors or background tasks and is safe to use
   --  concurrently with resolution calls.
   procedure Clear_Cache;

private
   Max_Name_Length       : constant := 253;
   Max_TCP_Packet_Length : constant := 16_384;
   Max_Name_Servers      : constant := 4;
   Max_Search_Domains    : constant := 6;
   Max_Addresses         : constant := 16;

   type Name_Buffer is record
      Length : Natural range 0 .. Max_Name_Length := 0;
      Data   : String (1 .. Max_Name_Length) := (others => ' ');
   end record;
   type Name_Buffer_Array is array (Positive range <>) of Name_Buffer;

   type Resolver_Config is record
      Servers      : Name_Server_Array (1 .. Max_Name_Servers);
      Server_Count : Natural range 0 .. Max_Name_Servers := 0;
      Search       : Name_Buffer_Array (1 .. Max_Search_Domains);
      Search_Count : Natural range 0 .. Max_Search_Domains := 0;
      NDots        : Natural range 0 .. 15 := 1;
      Attempts     : Positive := 2;
      Per_Attempt  : Duration := 2.0;
      Rotate       : Boolean := False;
   end record;

   type Resolver_Configuration is limited record
      Value : Resolver_Config;
   end record;

   type Raw_Address_Bytes is array (Positive range <>) of Interfaces.Unsigned_8;
   type Raw_Address is record
      Family : Flyology.IO.Sockets.Address_Family := Flyology.IO.Sockets.IPv4;
      Bytes  : Raw_Address_Bytes (1 .. 16) := (others => 0);
   end record;
   type Raw_Address_Array is array (Positive range <>) of Raw_Address;
   type TTL_Array is array (Positive range <>) of Natural;

   type Resolve_Phase is
     (Idle,
      Begin_Candidate,
      Begin_Family,
      Begin_Attempt,
      UDP_Sending,
      UDP_Receiving,
      TCP_Connecting,
      TCP_Sending,
      TCP_Receiving_Length,
      TCP_Receiving_Message,
      Cancelling);
   type Resolve_Failure is
     (No_Failure,
      Not_Found_Failure,
      Resolution_Failure,
      Malformed_Failure,
      Server_Failure,
      Cancelled_Failure,
      Timeout_Failure,
      Device_Failure,
      Socket_Failure);
   type Child_Kind is
     (No_Child, Send_Child, Receive_Child, Connect_Child, Send_All_Child, Receive_Exactly_Child);

   type Resolve_Operation_State (Owner : not null access Flyology.Operations.Completion_Set'Class) is
   limited record
      Configuration             : Resolver_Config;
      Candidates                : Name_Buffer_Array (1 .. Max_Search_Domains + 2);
      Candidate_Count           : Natural range 0 .. Max_Search_Domains + 2 := 0;
      Candidate_Index           : Natural range 0 .. Max_Search_Domains + 2 := 0;
      Query_Name                : Name_Buffer;
      Original_Name             : Name_Buffer;
      Family                    : Family_Preference := Any_Family;
      Query_Kind                : Natural := 0;
      Family_Index              : Natural range 0 .. 2 := 0;
      Deadline                  : Ada.Real_Time.Time := Ada.Real_Time.Time_Last;
      Family_Deadline           : Ada.Real_Time.Time := Ada.Real_Time.Time_Last;
      Attempt_Deadline          : Ada.Real_Time.Time := Ada.Real_Time.Time_Last;
      Rotation                  : Natural := 0;
      Attempt_Index             : Natural := 0;
      Transaction_ID            : Natural range 0 .. 65_535 := 0;
      CNAME_Depth               : Natural range 0 .. 16 := 0;
      Alias_Names               : Name_Buffer_Array (1 .. 16);
      Alias_TTLs                : TTL_Array (1 .. 16) := (others => 0);
      Values                    : Raw_Address_Array (1 .. Max_Addresses);
      Value_Count               : Natural range 0 .. Max_Addresses := 0;
      Query_Data                :
        aliased Ada.Streams.Stream_Element_Array
                 (1 .. Ada.Streams.Stream_Element_Offset (Max_Name_Length + 18)) := (others => 0);
      Query_Length              : Natural := 0;
      TCP_Data                  :
        aliased Ada.Streams.Stream_Element_Array
                 (1 .. Ada.Streams.Stream_Element_Offset (Max_TCP_Packet_Length + 2)) := (others => 0);
      TCP_Length                : Natural := 0;
      UDP_Socket                : aliased Flyology.IO.Sockets.Socket_Type;
      TCP_Socket                : aliased Flyology.IO.Sockets.Socket_Type;
      Send_Operation            : Flyology.IO.Sockets.Send_Operation (Owner);
      Receive_Operation         : Flyology.IO.Sockets.Receive_Operation (Owner);
      Connect_Operation         : Flyology.IO.Sockets.Connect_Operation (Owner);
      Send_All_Operation        : Flyology.IO.Sockets.Send_All_Operation (Owner);
      Receive_Exactly_Operation : Flyology.IO.Sockets.Receive_Exactly_Operation (Owner);
      Child                     : Child_Kind := No_Child;
      Token                     : access Flyology.Cancellation.Token := null;
      Token_Source              : Descriptor := Invalid_Descriptor;
      Phase                     : Resolve_Phase := Idle;
      Failure                   : Resolve_Failure := No_Failure;
      Kind_Transport_Failed     : Boolean := False;
      Kind_Malformed_Failed     : Boolean := False;
      Kind_Server_Failed        : Boolean := False;
      Transport_Failed          : Boolean := False;
      Malformed_Failed          : Boolean := False;
      Server_Failed             : Boolean := False;
   end record;

   --  @exclude
   --  @param Item Resolve operation to advance
   --  @param Event Driver event to process
   overriding
   procedure Drive (Item : in out Resolve_Operation; Event : Flyology.Operations.Driver_Event);

   --  @exclude
   --  @param Item Resolve operation to cancel
   overriding
   procedure Request_Cancellation (Item : in out Resolve_Operation);

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
     (Packet        : Ada.Streams.Stream_Element_Array;
      Expected_ID   : Natural;
      Expected_Name : String;
      For_IPv6      : Boolean := False);

end Flyology.IO.DNS;
