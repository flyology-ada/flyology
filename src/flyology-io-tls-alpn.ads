with Ada.Containers.Indefinite_Vectors;
with Flyology.IO.Sockets;

--  Adds optional Application-Layer Protocol Negotiation to the TLS SPI.
--
--  Providers and sessions opt into these interfaces independently of the core
--  TLS interfaces, so an existing provider remains source-compatible. ALPN
--  identifiers are opaque byte strings; protocol policy belongs to callers.
package Flyology.IO.TLS.ALPN is

   --  Ordered protocol identifiers offered to a peer. Each identifier is one
   --  to 255 bytes and the complete encoded list is at most 65,535 bytes.
   type Protocol_List is private;

   --  An empty protocol list. Passing it creates an ALPN-capable session that
   --  sends no ALPN offer.
   Empty_Protocol_List : constant Protocol_List;

   --  Create a one-element ordered protocol list.
   --  @param Identifier Opaque nonempty protocol identifier
   --  @return List containing Identifier
   --  @exception Constraint_Error Identifier is empty or longer than 255 bytes
   function Offer (Identifier : String) return Protocol_List;

   --  Append an identifier while preserving offer order.
   --  @param Item Protocol list to extend
   --  @param Identifier Opaque nonempty protocol identifier
   --  @exception Constraint_Error Identifier or total encoded length is
   --     invalid
   procedure Append (Item : in out Protocol_List; Identifier : String);

   --  Return a copy of Left with Right appended.
   --  @param Left Existing ordered protocol list
   --  @param Right Opaque nonempty protocol identifier
   --  @return Extended ordered protocol list
   --  @exception Constraint_Error Right or total encoded length is invalid
   function "&"
     (Left : Protocol_List; Right : String) return Protocol_List;

   --  Return the number of offered identifiers.
   --  @param Item Protocol list to inspect
   --  @return Identifier count
   function Count (Item : Protocol_List) return Natural;

   --  Return one identifier by its one-based offer position.
   --  @param Item Protocol list to inspect
   --  @param Index One-based offer position
   --  @return Opaque protocol identifier
   --  @exception Constraint_Error Index is outside the list
   function Identifier
     (Item : Protocol_List; Index : Positive) return String;

   --  Optional provider capability for per-session ALPN offers. Implementing
   --  this interface does not change the core provider primitives. Factories
   --  must preserve Protocols order when sending a client offer.
   type Provider is limited interface and Flyology.IO.TLS.Provider;

   --  Create a nonblocking TLS session with an ordered ALPN offer. The core
   --  Create_Session contract also applies. A client sends Protocols in order;
   --  an empty list sends no ALPN extension. Server behavior is provider
   --  specific unless separately configured by that provider.
   --  @param Item Initialized ALPN-capable provider
   --  @param FD Borrowed connected descriptor
   --  @param Side Client or server role
   --  @param Server_Name Verified DNS name for clients; empty for servers
   --  @param Protocols Ordered client offer or an empty list
   --  @return Newly allocated ALPN-capable provider session
   --  @exception TLS_Error Provider setup fails
   function Create_Session
     (Item        : in out Provider;
      FD          : Descriptor;
      Side        : Role;
      Server_Name : String;
      Protocols   : Protocol_List) return Session_Access is abstract;

   --  Optional session capability for reading the ALPN result.
   type Session is limited interface;

   --  Copy the identifier selected by the peer after a successful handshake.
   --  An empty String means that the peer made no ALPN selection.
   --  @param Item Handshaken ALPN-capable session
   --  @return Selected opaque identifier or an empty String
   function Selected_Protocol (Item : Session) return String is abstract;

   --  Create an ALPN-capable session and transfer Socket ownership to Item.
   --  Core Take validation and ownership behavior apply. Protocols are used
   --  only during session creation and need not outlive this call.
   --  @param Backend Initialized ALPN-capable provider
   --  @param Socket Connected socket transferred on success
   --  @param Side Client or server handshake role
   --  @param Server_Name DNS name verified by a client; empty for a server
   --  @param Protocols Ordered client offer or an empty list
   --  @param Item Closed connection that receives the socket and session
   --  @exception TLS_Error Provider setup fails or returns a non-ALPN session
   --  @exception Socket_Error Flyology.IO.Sockets.Socket_Error is raised when
   --     preparing socket mode fails
   --  @exception Program_Error Core Take arguments are invalid
   procedure Take
     (Backend     : in out Provider'Class;
      Socket      : in out Flyology.IO.Sockets.Socket_Type;
      Side        : Role;
      Server_Name : String;
      Protocols   : Protocol_List;
      Item        : in out Connection);

   --  Read the ALPN result under the connection's operation serialization.
   --  Call this after Handshake succeeds. It waits for an active operation to
   --  drain and is interrupted by concurrent Close.
   --  @param Item Open handshaken ALPN connection
   --  @return Selected opaque identifier or an empty String
   --  @exception Operation_Cancelled Concurrent Close interrupts the query
   --  @exception TLS_Error The installed session lacks the ALPN capability
   --  @exception Program_Error Item is closed
   function Selected_Protocol (Item : in out Connection) return String;

private
   package Protocol_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

   type Protocol_List is record
      Values         : Protocol_Vectors.Vector;
      Encoded_Length : Natural := 0;
   end record;

   Empty_Protocol_List : constant Protocol_List :=
     (Values         => Protocol_Vectors.Empty_Vector,
      Encoded_Length => 0);

end Flyology.IO.TLS.ALPN;
