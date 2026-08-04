with Flyology.IO.TLS;

--  Adds ownership-preserving TLS to an admitted connection.
package Flyology.IO.Connections.TLS is

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
   --  @exception Flyology.IO.Timeout_Error The shared deadline expires
   --  @exception Flyology.IO.Device_Error Readiness polling fails
   --  @exception Flyology.IO.TLS.TLS_Error Provider setup or handshake fails
   --  @exception Flyology.IO.Sockets.Socket_Error Socket preparation or close
   --     fails
   --  @exception Program_Error Item is closed, already uses TLS, or arguments
   --     do not match Side
   procedure Upgrade
     (Item        : in out Connection;
      Backend     : in out Flyology.IO.TLS.Provider'Class;
      Side        : Flyology.IO.TLS.Role;
      Server_Name : String;
      Timeout     : Duration := Infinite;
      Token       : access Cancellation_Token := null);

   --  Complete a bidirectional close_notify exchange without closing Item or
   --  releasing its admission permit. Repeating Shutdown after success is
   --  harmless. Close remains the terminal ownership operation.
   --  @param Item Open connection whose transport uses TLS
   --  @param Timeout Shared shutdown deadline in seconds
   --  @param Token Optional one-shot token that must outlive the call
   --  @exception Operation_Cancelled Shutdown, Token, or concurrent Close
   --     interrupts the operation
   --  @exception Flyology.IO.Timeout_Error The shared deadline expires
   --  @exception Flyology.IO.Device_Error Readiness polling fails
   --  @exception Flyology.IO.TLS.TLS_Error Provider or peer fails shutdown
   --  @exception Program_Error Item is closed or still plaintext
   procedure Shutdown
     (Item    : in out Connection;
      Timeout : Duration := Infinite;
      Token   : access Cancellation_Token := null);

end Flyology.IO.Connections.TLS;
