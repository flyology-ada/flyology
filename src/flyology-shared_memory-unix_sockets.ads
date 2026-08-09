with Ada.Finalization;
with Interfaces.C;

--  Transfers one shared-memory capability over an already connected Unix-
--  domain socket using SCM_RIGHTS. Send and Receive use synchronous sendmsg
--  and recvmsg calls and may block. Call them from a native task unless the
--  application has independently established nonblocking readiness; this
--  package does not hide socket work on an event-loop pthread.
package Flyology.Shared_Memory.Unix_Sockets is

   --  Raised when the carrier byte, ancillary layout, descriptor count, or
   --  socket kind violates the one-descriptor handoff protocol. A raw socket
   --  must be retired after this exception. An owned Handoff_Channel poisons
   --  and closes itself before propagating it.
   Protocol_Error : exception;

   --  Raised when another native task is already operating on the same owned
   --  handoff channel. Operations never wait for the channel guard.
   Channel_Busy : exception;

   --  Connected Unix-domain socket descriptor supplied by the application.
   type Socket_Descriptor is new Interfaces.C.int;

   --  Trust assigned to the peer that supplied a handoff socket.
   --  @enum Trusted_Peer The application authenticates and trusts the peer
   --     not to exploit platform ancillary-data, shared open-file-description,
   --     or backing-resize behavior; this setting does not authenticate it
   --  @enum Untrusted_Peer Require the platform to provide bounded ancillary
   --     descriptor cleanup; currently available only on Linux
   type Peer_Trust is (Trusted_Peer, Untrusted_Peer);

   --  Limited owner of a dedicated connected AF_UNIX SOCK_STREAM endpoint.
   --  The endpoint admits only Flyology's one-byte, one-descriptor protocol,
   --  serializes each Send or Receive attempt without waiting, and becomes
   --  permanently poisoned and closed after a protocol, validation, security,
   --  or transport failure. No other read, recv, recvmsg, send, or sendmsg may
   --  use the endpoint or any duplicate while it is owned by this object.
   type Handoff_Channel is limited private;

   --  Transfer a connected AF_UNIX SOCK_STREAM descriptor into Item. The
   --  descriptor receives FD_CLOEXEC and Darwin SO_NOSIGPIPE before adoption.
   --  Socket becomes invalid after success. Untrusted_Peer is rejected on
   --  Darwin because truncated SCM_RIGHTS delivery can leak descriptors that
   --  XNU installed but did not expose in the returned control buffer.
   --  Linux can request close-on-exec atomically during receive. Darwin must
   --  set it immediately afterward, so applications must also obey Flyology's
   --  rule forbidding a non-exec fork child after Ada tasking has started.
   --  @param Item Closed channel that receives sole endpoint ownership
   --  @param Socket Connected socket descriptor transferred on success
   --  @param Trust Peer trust policy for descriptor and truncation behavior
   --  @exception Validation_Error Item is already open or Socket is invalid
   --  @exception Security_Error Untrusted ancillary receipt is not supported
   --  @exception Protocol_Error Socket is not connected AF_UNIX SOCK_STREAM
   --  @exception Operating_System_Error Descriptor inspection or setup fails
   procedure Adopt
     (Item   : in out Handoff_Channel;
      Socket : in out Socket_Descriptor;
      Trust  : Peer_Trust := Trusted_Peer);

   --  Explicitly close Item. This operation is idempotent and a non-raising
   --  finalization fallback also closes an owned endpoint.
   --  @param Item Channel owner to close
   --  @exception Channel_Busy Another native task is using Item
   --  @exception Operating_System_Error close reports an error
   procedure Close (Item : in out Handoff_Channel);

   --  Report whether Item owns a usable or currently busy endpoint.
   --  @param Item Channel to inspect
   --  @return True before explicit close or poisoning
   function Is_Open (Item : Handoff_Channel) return Boolean;

   --  Report whether a failed operation permanently retired Item.
   --  @param Item Channel to inspect
   --  @return True only after fail-closed channel poisoning
   function Is_Poisoned (Item : Handoff_Channel) return Boolean;

   --  Local ownership behavior after a successful send.
   --  @enum Borrow Keep the sending Backing_Object open
   --  @enum Transfer Close the sending Backing_Object after sendmsg accepts
   --     the capability; any existing mappings remain live
   type Send_Ownership is (Borrow, Transfer);

   --  Send exactly one backing descriptor over a caller-owned raw socket. The
   --  receiver obtains a new descriptor referring to the same open file
   --  description. Socket must be a dedicated connected AF_UNIX SOCK_STREAM
   --  lane used by no other reader or writer; serialize calls externally and
   --  retire the socket after any exception. The one nonzero carrier byte is
   --  what binds the SCM_RIGHTS control message to the stream. Send success
   --  means local kernel acceptance, not receiver validation or attachment.
   --  @param Socket Connected Unix-domain socket
   --  @param Item Open backing object to borrow or transfer
   --  @param Ownership Whether the sender retains descriptor ownership
   --  @exception Validation_Error Item is closed or Socket is invalid
   --  @exception Protocol_Error Socket is not connected AF_UNIX SOCK_STREAM
   --  @exception Operating_System_Error sendmsg or transfer close fails
   procedure Send
     (Socket    : Socket_Descriptor;
      Item      : in out Backing_Object;
      Ownership : Send_Ownership := Borrow);

   --  Send exactly one backing descriptor through an owned dedicated channel.
   --  The operation fails immediately on concurrent channel use. A transport
   --  failure after channel acquisition poisons and closes the channel;
   --  Transfer consumes Item only after sendmsg accepts the carrier and
   --  descriptor locally. A later failure while closing a transferred backing
   --  object does not invalidate the accepted stream record.
   --  @param Channel Dedicated channel owner
   --  @param Item Open backing object to borrow or transfer
   --  @param Ownership Whether the sender retains descriptor ownership
   --  @exception Channel_Busy Another native task is using Channel
   --  @exception Validation_Error Channel or Item is closed
   --  @exception Protocol_Error Channel protocol validation fails
   --  @exception Operating_System_Error sendmsg or close fails
   procedure Send
     (Channel   : in out Handoff_Channel;
      Item      : in out Backing_Object;
      Ownership : Send_Ownership := Borrow);

   --  Receive exactly one descriptor from a caller-owned raw socket, establish
   --  FD_CLOEXEC immediately, validate regular-file type and exact length, and
   --  optionally require immutable Linux size seals before adopting it into
   --  Item. Linux requests
   --  MSG_CMSG_CLOEXEC; Darwin applies FD_CLOEXEC before return. Malformed,
   --  missing, extra, or truncated ancillary data closes every descriptor
   --  exposed by the kernel and raises. Socket must be a dedicated externally
   --  serialized AF_UNIX SOCK_STREAM lane, and must be retired after every
   --  exception.
   --  Linux closes descriptors omitted by ancillary truncation; Darwin has a
   --  known XNU leak for omitted descriptors, so this raw operation must not
   --  accept an untrusted Darwin peer. A short read does not mean the stream
   --  is drained and no ordinary read may consume the carrier byte.
   --  @param Socket Connected Unix-domain socket
   --  @param Expected_Length Required exact positive backing length
   --  @param Item Closed owner that receives exactly one validated descriptor
   --  @param Require_Immutable_Size Reject descriptors without Linux size
   --     seals; use False for Darwin anonymous, named, and file-backed objects
   --  @exception Constraint_Error Expected_Length is zero or not native
   --  @exception Validation_Error Item is open, Socket is invalid, or the
   --     received type or size does not match
   --  @exception Security_Error CLOEXEC or a required size seal is absent
   --  @exception Protocol_Error Carrier, ancillary data, or socket kind is
   --     invalid
   --  @exception Operating_System_Error recvmsg or descriptor inspection fails
   procedure Receive
     (Socket                 : Socket_Descriptor;
      Expected_Length        : Byte_Length;
      Item                   : in out Backing_Object;
      Require_Immutable_Size : Boolean := False);

   --  Receive exactly one descriptor through an owned dedicated channel.
   --  Trusted channels apply the caller's immutable-size choice. Untrusted
   --  channels always require Linux immutable size seals, preventing a peer
   --  that retains a duplicate from shrinking the mapped object and causing
   --  SIGBUS. Only writable exact-size regular or POSIX-shm backing objects
   --  are accepted, so pipe, socket, and mutable-status-flag hazards do not
   --  enter the mapping API. Any failure after channel input begins poisons
   --  and closes Channel after closing every descriptor visible to user space.
   --  @param Channel Dedicated channel owner
   --  @param Expected_Length Exact positive backing length selected locally
   --  @param Item Closed owner that receives one validated descriptor
   --  @param Require_Immutable_Size Require Linux size seals for a trusted
   --     peer
   --  @exception Channel_Busy Another native task is using Channel
   --  @exception Constraint_Error Expected_Length is zero or not native
   --  @exception Validation_Error Channel is closed, Item is open, or the
   --     received descriptor has the wrong type, access mode, or size
   --  @exception Security_Error Required seals or CLOEXEC are unavailable
   --  @exception Protocol_Error Carrier or ancillary data is invalid
   --  @exception Operating_System_Error recvmsg or inspection fails
   procedure Receive
     (Channel                : in out Handoff_Channel;
      Expected_Length        : Byte_Length;
      Item                   : in out Backing_Object;
      Require_Immutable_Size : Boolean := False);

private
   package C renames Interfaces.C;

   type Channel_State is (Closed, Ready, Busy, Poisoned);
   type Begin_Result is (Acquired, Was_Closed, Was_Busy, Was_Poisoned);

   protected type Channel_Controller is
      procedure Adopt
        (Descriptor : C.int;
         Trust      : Peer_Trust;
         Accepted   : out Boolean);
      procedure Try_Begin
        (Descriptor : out C.int;
         Trust      : out Peer_Trust;
         Result     : out Begin_Result);
      procedure Finish;
      procedure Poison (Descriptor : out C.int);
      procedure Take_For_Close
        (Descriptor : out C.int;
         Busy_Now   : out Boolean);
      function Open return Boolean;
      function Failed return Boolean;
   private
      Descriptor_Value : C.int := -1;
      Trust_Value      : Peer_Trust := Trusted_Peer;
      State            : Channel_State := Closed;
   end Channel_Controller;

   type Channel_Owner is new Ada.Finalization.Limited_Controlled with record
      Controller : Channel_Controller;
   end record;

   --  @exclude Controlled finalization hook
   --  @param Item Channel owner finalized without raising
   overriding procedure Finalize (Item : in out Channel_Owner);

   type Handoff_Channel is limited record
      Owner : Channel_Owner;
   end record;

end Flyology.Shared_Memory.Unix_Sockets;
