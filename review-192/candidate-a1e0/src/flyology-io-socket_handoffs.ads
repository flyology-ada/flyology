with Ada.Finalization;
with Flyology.IO.Sockets;
private with Flyology.Descriptor_Handoffs;

--  Transfers typed listening-socket capabilities over one dedicated connected
--  AF_UNIX stream channel. Calls are synchronous and may block; use a native
--  task unless readiness has been established independently.

package Flyology.IO.Socket_Handoffs is
   --  Ancillary data violates the one-byte, one-descriptor protocol.
   Protocol_Error         : exception;
   --  A second operation attempted to use the serialized channel.
   Channel_Busy           : exception;
   --  A received descriptor is not a listening stream socket.
   Validation_Error       : exception;
   --  The carrier or received capability fails the requested trust policy.
   Security_Error         : exception;
   --  A carrier, descriptor, or socket system call failed.
   Operating_System_Error : exception;

   --  Trust applied while validating a carrier and received descriptor.
   --  @enum Trusted_Peer The peer belongs to the trusted coordinator protocol
   --  @enum Untrusted_Peer Apply supported hostile-peer descriptor checks
   type Peer_Trust is (Trusted_Peer, Untrusted_Peer);
   --  Sender ownership after local kernel acceptance.
   --  @enum Borrow Retain the local listener
   --  @enum Transfer Close the local listener after successful send
   type Send_Ownership is (Borrow, Transfer);

   --  Sole owner of one dedicated one-byte, one-descriptor protocol endpoint.
   --  No ordinary I/O or duplicate endpoint may share the stream. A transport,
   --  protocol, or received-capability failure poisons and closes the channel.
   type Handoff_Channel is limited private;

   --  Transfer a connected AF_UNIX stream socket into a closed channel.
   --  @param Item Closed destination channel
   --  @param Socket Connected stream socket whose ownership is transferred
   --  @param Trust Peer trust used for carrier and capability validation
   procedure Adopt
     (Item   : in out Handoff_Channel;
      Socket : in out Flyology.IO.Sockets.Socket_Type;
      Trust  : Peer_Trust := Trusted_Peer)
   with Post => not Flyology.IO.Sockets.Is_Open (Socket);

   --  Close the carrier and consume channel ownership.
   --  @param Item Channel to close
   procedure Close (Item : in out Handoff_Channel);
   --  Report whether the channel currently owns an open carrier.
   --  @param Item Channel to inspect
   --  @return True when the carrier is open
   function Is_Open (Item : Handoff_Channel) return Boolean;
   --  Report whether an earlier operation poisoned the channel.
   --  @param Item Channel to inspect
   --  @return True when failure made the carrier unusable
   function Is_Poisoned (Item : Handoff_Channel) return Boolean;

   --  Send one open listening socket. Borrow retains Item; Transfer closes it
   --  only after the kernel accepts the descriptor record locally.
   --  @param Channel Dedicated capability channel
   --  @param Item Listening socket capability
   --  @param Ownership Sender ownership after successful local acceptance
   procedure Send_Listener
     (Channel   : in out Handoff_Channel;
      Item      : in out Flyology.IO.Sockets.Socket_Type;
      Ownership : Send_Ownership := Borrow);

   --  Receive, validate, prepare, and adopt exactly one stream listener.
   --  Item remains closed on failure.
   --  @param Channel Dedicated capability channel
   --  @param Item Closed destination socket
   procedure Receive_Listener
     (Channel : in out Handoff_Channel; Item : in out Flyology.IO.Sockets.Socket_Type)
   with Pre => not Flyology.IO.Sockets.Is_Open (Item), Post => Flyology.IO.Sockets.Is_Open (Item);

private
   package Descriptor_Handoffs renames Flyology.Descriptor_Handoffs;

   type Channel_Owner is new Ada.Finalization.Limited_Controlled with record
      Value : Descriptor_Handoffs.Handoff_Channel;
   end record;

   type Handoff_Channel is limited record
      Owner : Channel_Owner;
   end record;
end Flyology.IO.Socket_Handoffs;
