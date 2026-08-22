with Ada.Finalization;
with Interfaces.C;

--  Internal owner for the dedicated one-byte, one-SCM_RIGHTS protocol shared
--  by typed capability packages. It validates only the carrier channel and
--  descriptor count; each public wrapper validates the received capability's
--  type and semantics before adoption.

private package Flyology.Descriptor_Handoffs is
   --  @exclude Internal capability-carrier implementation, not part of the
   --  public API.

   package C renames Interfaces.C;

   --  @exclude
   Protocol_Error         : exception;
   --  @exclude
   Channel_Busy           : exception;
   --  @exclude
   Validation_Error       : exception;
   --  @exclude
   Security_Error         : exception;
   --  @exclude
   Operating_System_Error : exception;

   --  Internal peer trust classification.
   --  @enum Trusted_Peer Trust the coordinator protocol peer
   --  @enum Untrusted_Peer Apply supported hostile-peer checks
   --  @exclude
   type Peer_Trust is (Trusted_Peer, Untrusted_Peer);
   --  @exclude
   type Socket_Descriptor is new C.int;
   --  @exclude
   type Handoff_Channel is limited private;

   --  Validate one candidate carrier descriptor.
   --  @param Socket Candidate AF_UNIX stream descriptor
   --  @param Trust Validation trust policy
   --  @exclude
   procedure Validate_Carrier (Socket : Socket_Descriptor; Trust : Peer_Trust := Trusted_Peer);

   --  Transfer one validated carrier into its internal owner.
   --  @param Item Closed destination channel
   --  @param Socket Carrier descriptor whose ownership is transferred
   --  @param Trust Validation trust policy
   --  @exclude
   procedure Adopt
     (Item : in out Handoff_Channel; Socket : in out Socket_Descriptor; Trust : Peer_Trust := Trusted_Peer);

   --  Close an internal carrier channel.
   --  @param Item Channel to close
   --  @exclude
   procedure Close (Item : in out Handoff_Channel);
   --  Poison and close an internal carrier channel.
   --  @param Item Channel to poison and close
   --  @exclude
   procedure Poison (Item : in out Handoff_Channel);
   --  Report internal carrier ownership.
   --  @param Item Channel to inspect
   --  @return True when the carrier is open
   --  @exclude
   function Is_Open (Item : Handoff_Channel) return Boolean;
   --  Report whether an internal channel is poisoned.
   --  @param Item Channel to inspect
   --  @return True when failure made the channel unusable
   --  @exclude
   function Is_Poisoned (Item : Handoff_Channel) return Boolean;

   --  Send one descriptor over the internal carrier.
   --  @param Channel Dedicated carrier channel
   --  @param Descriptor Capability descriptor to send
   --  @exclude
   procedure Send (Channel : in out Handoff_Channel; Descriptor : C.int);

   --  Receive one descriptor over the internal carrier.
   --  @param Channel Dedicated carrier channel
   --  @param Descriptor Sole received capability descriptor
   --  @exclude
   procedure Receive (Channel : in out Handoff_Channel; Descriptor : out C.int);

private
   use type C.int;

   type Channel_State is (Closed, Ready, Busy, Poisoned);
   type Begin_Result is (Acquired, Was_Closed, Was_Busy, Was_Poisoned);

   protected type Channel_Controller is
      procedure Adopt (Descriptor : C.int; Accepted : out Boolean);
      procedure Try_Begin (Descriptor : out C.int; Result : out Begin_Result);
      procedure Finish;
      procedure Poison (Descriptor : out C.int);
      procedure Take_For_Close (Descriptor : out C.int; Busy_Now : out Boolean);
      function Open return Boolean;
      function Failed return Boolean;
   private
      Descriptor_Value : C.int := -1;
      State            : Channel_State := Closed;
   end Channel_Controller;

   type Channel_Owner is new Ada.Finalization.Limited_Controlled with record
      Controller : Channel_Controller;
   end record;

   --  Release an internal carrier owner without propagating failures.
   --  @param Item Internal owner being finalized
   --  @exclude
   overriding
   procedure Finalize (Item : in out Channel_Owner);

   type Handoff_Channel is limited record
      Owner : Channel_Owner;
   end record;
end Flyology.Descriptor_Handoffs;
