with Interfaces.C;

--  Transfers one shared-memory capability over an already connected Unix-
--  domain socket using SCM_RIGHTS. Send and Receive use synchronous sendmsg
--  and recvmsg calls and may block. Call them from a native task unless the
--  application has independently established nonblocking readiness; this
--  package does not hide socket work on an event-loop pthread.
package Flyology.Shared_Memory.Unix_Sockets is

   --  Connected Unix-domain socket descriptor supplied by the application.
   type Socket_Descriptor is new Interfaces.C.int;

   --  Local ownership behavior after a successful send.
   --  @enum Borrow Keep the sending Backing_Object open
   --  @enum Transfer Close the sending Backing_Object after sendmsg accepts
   --     the capability; any existing mappings remain live
   type Send_Ownership is (Borrow, Transfer);

   --  Send exactly one backing descriptor. The receiver obtains a new
   --  descriptor referring to the same open file description.
   --  @param Socket Connected Unix-domain socket
   --  @param Item Open backing object to borrow or transfer
   --  @param Ownership Whether the sender retains descriptor ownership
   --  @exception Validation_Error Item is closed or Socket is invalid
   --  @exception Operating_System_Error sendmsg or transfer close fails
   procedure Send
     (Socket    : Socket_Descriptor;
      Item      : in out Backing_Object;
      Ownership : Send_Ownership := Borrow);

   --  Receive exactly one descriptor, establish FD_CLOEXEC immediately,
   --  validate regular-file type and exact length, and optionally require
   --  immutable Linux size seals before adopting it into Item. Linux requests
   --  MSG_CMSG_CLOEXEC; Darwin applies FD_CLOEXEC before return. Malformed,
   --  missing, extra, or truncated ancillary data closes every received
   --  descriptor and raises.
   --  @param Socket Connected Unix-domain socket
   --  @param Expected_Length Required exact positive backing length
   --  @param Item Closed owner that receives exactly one validated descriptor
   --  @param Require_Immutable_Size Reject descriptors without Linux size
   --     seals; use False for Darwin anonymous, named, and file-backed objects
   --  @exception Constraint_Error Expected_Length is zero or not native
   --  @exception Validation_Error Item is open, Socket is invalid, or the
   --     received type or size does not match
   --  @exception Security_Error CLOEXEC or a required size seal is absent
   --  @exception Operating_System_Error recvmsg or descriptor inspection fails
   procedure Receive
     (Socket                 : Socket_Descriptor;
      Expected_Length        : Byte_Length;
      Item                   : in out Backing_Object;
      Require_Immutable_Size : Boolean := False);

end Flyology.Shared_Memory.Unix_Sockets;
