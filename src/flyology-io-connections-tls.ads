with Flyology.IO.TLS;
with Flyology.IO.TLS.ALPN;
with Flyology.Operations;

--  Adds ownership-preserving TLS to an admitted connection.
package Flyology.IO.Connections.TLS is

   --  First-class ownership-preserving TLS upgrade. Provider setup is an
   --  eager bounded initiation step; lease acquisition and every handshake
   --  WANT_READ/WANT_WRITE step compose through the owning completion set.
   type Upgrade_Operation is new Connection_Operation with private;

   --  Start a core TLS upgrade without suspending the owner task. Item and
   --  Backend are borrowed through provider setup; Item remains borrowed until
   --  typed Finish or finalization. Any failure after the transport transition
   --  closes Item, matching the synchronous Upgrade contract.
   --  @param Set Completion set that owns the operation slot
   --  @param Item Open plaintext admitted connection
   --  @param Backend Initialized TLS provider
   --  @param Side Client or server handshake role
   --  @param Server_Name Verified client DNS name or empty server name
   --  @param Timeout Shared lease, setup, and handshake deadline
   --  @param Token Optional cancellation source that outlives the operation
   --  @return Started limited TLS upgrade operation
   function Upgrade
     (Set         : not null access Flyology.Operations.Completion_Set'Class;
      Item        : not null access Connection'Class;
      Backend     : not null access Flyology.IO.TLS.Provider'Class;
      Side        : Flyology.IO.TLS.Role;
      Server_Name : String;
      Timeout     : Duration := Infinite;
      Token       : access Cancellation_Token := null)
      return Upgrade_Operation;

   --  Start or restart a core TLS upgrade in an established operation object.
   --  @param Item Open plaintext admitted connection
   --  @param Backend Initialized TLS provider
   --  @param Side Client or server handshake role
   --  @param Server_Name Verified client DNS name or empty server name
   --  @param Timeout Shared lease, setup, and handshake deadline
   --  @param Token Optional cancellation source that outlives the operation
   --  @param Operation Fresh, released, or consumed upgrade operation
   procedure Upgrade
     (Item        : not null access Connection'Class;
      Backend     : not null access Flyology.IO.TLS.Provider'Class;
      Side        : Flyology.IO.TLS.Role;
      Server_Name : String;
      Timeout     : Duration := Infinite;
      Token       : access Cancellation_Token := null;
      Operation   : in out Upgrade_Operation)
     with Pre =>
       not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation);

   --  Start an ALPN-capable TLS upgrade. Protocols is consumed during eager
   --  provider setup and need not outlive initiation; all other behavior
   --  matches the core scoped Upgrade.
   --  @param Set Completion set that owns the operation slot
   --  @param Item Open plaintext admitted connection
   --  @param Backend Initialized ALPN-capable provider
   --  @param Side Client or server handshake role
   --  @param Server_Name Verified client DNS name or empty server name
   --  @param Protocols Ordered client offer or an empty list
   --  @param Timeout Shared lease, setup, and handshake deadline
   --  @param Token Optional cancellation source that outlives the operation
   --  @return Started limited TLS upgrade operation
   function Upgrade
     (Set         : not null access Flyology.Operations.Completion_Set'Class;
      Item        : not null access Connection'Class;
      Backend     : not null access Flyology.IO.TLS.ALPN.Provider'Class;
      Side        : Flyology.IO.TLS.Role;
      Server_Name : String;
      Protocols   : Flyology.IO.TLS.ALPN.Protocol_List;
      Timeout     : Duration := Infinite;
      Token       : access Cancellation_Token := null)
      return Upgrade_Operation;

   --  Start or restart an ALPN-capable TLS upgrade.
   --  @param Item Open plaintext admitted connection
   --  @param Backend Initialized ALPN-capable provider
   --  @param Side Client or server handshake role
   --  @param Server_Name Verified client DNS name or empty server name
   --  @param Protocols Ordered client offer or an empty list
   --  @param Timeout Shared lease, setup, and handshake deadline
   --  @param Token Optional cancellation source that outlives the operation
   --  @param Operation Fresh, released, or consumed upgrade operation
   procedure Upgrade
     (Item        : not null access Connection'Class;
      Backend     : not null access Flyology.IO.TLS.ALPN.Provider'Class;
      Side        : Flyology.IO.TLS.Role;
      Server_Name : String;
      Protocols   : Flyology.IO.TLS.ALPN.Protocol_List;
      Timeout     : Duration := Infinite;
      Token       : access Cancellation_Token := null;
      Operation   : in out Upgrade_Operation)
     with Pre =>
       not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation);

   --  Consume a terminal TLS upgrade, raising its retained familiar error.
   --  @param Operation Terminal TLS upgrade operation
   procedure Finish (Operation : in out Upgrade_Operation);

   --  Replace Item's plaintext transport with a provider session and complete
   --  its TLS handshake over the same socket. Item retains its admission
   --  permit and remains the sole closing owner. One deadline covers waiting
   --  for Item's operation lease, provider setup, and all handshake retries.
   --  Provider setup calls are synchronous and are not preempted; expiration
   --  during setup is observed as soon as the provider returns. A zero timeout
   --  still permits setup and immediately available handshake progress, but
   --  never waits for readiness.
   --  Once the transport enters the upgrade state, any failure closes Item;
   --  plaintext fallback must be selected before calling Upgrade. Plaintext
   --  operations queued before the transition are cancelled rather than run
   --  against the TLS transport. Lightweight callers suspend on readiness;
   --  native callers block only their pthread.
   --  @param Item Open plaintext admitted connection
   --  @param Backend Initialized TLS provider
   --  @param Side Client or server handshake role
   --  @param Server_Name Verified DNS name for clients; empty for servers
   --  @param Timeout Shared upgrade deadline in seconds
   --  @param Token Optional one-shot token that must outlive the call
   --  @exception Operation_Cancelled Shutdown, Token, or concurrent Close
   --     interrupts the upgrade
   --  @exception Timeout_Error Flyology.IO.Timeout_Error is raised when the
   --     shared deadline expires
   --  @exception Device_Error Flyology.IO.Device_Error is raised when
   --     readiness polling fails
   --  @exception TLS_Error Flyology.IO.TLS.TLS_Error is raised when provider
   --     setup or the handshake fails
   --  @exception Socket_Error Flyology.IO.Sockets.Socket_Error is raised when
   --     socket preparation or close fails
   --  @exception Program_Error Item is closed, already uses TLS, or arguments
   --     do not match Side
   procedure Upgrade
     (Item        : in out Connection;
      Backend     : in out Flyology.IO.TLS.Provider'Class;
      Side        : Flyology.IO.TLS.Role;
      Server_Name : String;
      Timeout     : Duration := Infinite;
      Token       : access Cancellation_Token := null);

   --  Replace Item's plaintext transport with an ALPN-capable TLS session and
   --  complete its handshake. Ownership, deadline, cancellation, and failure
   --  behavior match the core Upgrade overload. Protocol identifiers are
   --  offered in list order; an empty list sends no ALPN extension.
   --  @param Item Open plaintext admitted connection
   --  @param Backend Initialized ALPN-capable TLS provider
   --  @param Side Client or server handshake role
   --  @param Server_Name Verified DNS name for clients; empty for servers
   --  @param Protocols Ordered client offer or an empty list
   --  @param Timeout Shared upgrade deadline in seconds
   --  @param Token Optional one-shot token that must outlive the call
   --  @exception Operation_Cancelled Shutdown, Token, or concurrent Close
   --     interrupts the upgrade
   --  @exception Timeout_Error Flyology.IO.Timeout_Error is raised when the
   --     shared deadline expires
   --  @exception Device_Error Flyology.IO.Device_Error is raised when
   --     readiness polling fails
   --  @exception TLS_Error Flyology.IO.TLS.TLS_Error is raised when provider
   --     setup or the handshake fails
   --  @exception Socket_Error Flyology.IO.Sockets.Socket_Error is raised when
   --     socket preparation or close fails
   --  @exception Program_Error Item is closed, already uses TLS, or arguments
   --     do not match Side
   procedure Upgrade
     (Item        : in out Connection;
      Backend     : in out Flyology.IO.TLS.ALPN.Provider'Class;
      Side        : Flyology.IO.TLS.Role;
      Server_Name : String;
      Protocols   : Flyology.IO.TLS.ALPN.Protocol_List;
      Timeout     : Duration := Infinite;
      Token       : access Cancellation_Token := null);

   --  Read the peer's ALPN selection under Item's operation lease. Call this
   --  after the ALPN Upgrade overload succeeds. An empty String means that the
   --  peer made no selection.
   --  @param Item Open ALPN-upgraded connection
   --  @return Selected opaque protocol identifier or an empty String
   --  @exception Operation_Cancelled Concurrent Close interrupts the query
   --  @exception TLS_Error Flyology.IO.TLS.TLS_Error is raised when the
   --     session lacks the ALPN capability
   --  @exception Program_Error Item is closed or still plaintext
   function Selected_Protocol (Item : in out Connection) return String;

   --  Complete a bidirectional close_notify exchange without closing Item or
   --  releasing its admission permit. Repeating Shutdown after success is
   --  harmless. Close remains the terminal ownership operation.
   --  @param Item Open connection whose transport uses TLS
   --  @param Timeout Shared shutdown deadline in seconds
   --  @param Token Optional one-shot token that must outlive the call
   --  @exception Operation_Cancelled Shutdown, Token, or concurrent Close
   --     interrupts the operation
   --  @exception Timeout_Error Flyology.IO.Timeout_Error is raised when the
   --     shared deadline expires
   --  @exception Device_Error Flyology.IO.Device_Error is raised when
   --     readiness polling fails
   --  @exception TLS_Error Flyology.IO.TLS.TLS_Error is raised when the
   --     provider or peer fails shutdown
   --  @exception Program_Error Item is closed or still plaintext
   procedure Shutdown
     (Item    : in out Connection;
      Timeout : Duration := Infinite;
      Token   : access Cancellation_Token := null);

private
   type Upgrade_Operation is new Connection_Operation with null record;

end Flyology.IO.Connections.TLS;
