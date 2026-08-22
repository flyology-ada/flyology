with Interfaces;

--  Bounded compiler-independent wire representation for process-generation
--  control messages. The package performs no I/O and raises no exception for
--  malformed input; callers decide transport and failure policy.

package Flyology.Process_Generations.Protocol
  with Preelaborate, SPARK_Mode
is
   use type Interfaces.Unsigned_64;

   --  One wire byte.
   subtype Octet is Interfaces.Unsigned_8;
   --  Current control-frame protocol version.
   Protocol_Version : constant Interfaces.Unsigned_16 := 1;
   --  Fixed wire-header size in bytes.
   Header_Length    : constant Positive := 48;
   --  Largest permitted control payload in bytes.
   Maximum_Payload  : constant Natural := 2_048;
   --  Largest complete frame in bytes.
   Maximum_Frame    : constant Positive := Header_Length + Maximum_Payload;
   --  Index range for one complete frame buffer.
   subtype Wire_Index is Natural range 0 .. Maximum_Frame - 1;
   --  Count range for one complete frame buffer.
   subtype Wire_Count is Natural range 0 .. Maximum_Frame;
   --  Contiguous wire bytes with caller-selected bounds.
   type Octet_Array is array (Wire_Index range <>) of Octet;

   --  Control-plane message kind. Capability descriptors travel on the
   --  separate ancillary-data lane only after the matching expectation.
   --  @enum Hello Candidate authentication greeting
   --  @enum Provision Desired topology and role
   --  @enum Expect_Capability Permission to receive the next capability
   --  @enum Capability_Ready Sender-side capability readiness
   --  @enum Capability_Adopted Receiver-side capability adoption
   --  @enum Prepared_Message Candidate preparation completed
   --  @enum Activate Start the candidate server
   --  @enum Ready_Message Candidate readiness and topology proof
   --  @enum Start_Canary_Message Grant canary admission
   --  @enum Cancel_Message Begin candidate cancellation
   --  @enum Admission_Revoked_Message New admission is disabled
   --  @enum Drained_Message Managed work is quiescent
   --  @enum Compensation_Message Application compensation outcome
   --  @enum Promote_Message Promote the candidate
   --  @enum Drain_Message Drain a previous or retiring image
   --  @enum Commit_Message Commit promotion bookkeeping
   --  @enum Failure_Message Bounded peer failure description
   --  @enum Shutdown_Message Stop and drain the image
   --  @enum Acknowledgment Successful completion of the requested boundary
   type Message_Kind is
     (Hello,
      Provision,
      Expect_Capability,
      Capability_Ready,
      Capability_Adopted,
      Prepared_Message,
      Activate,
      Ready_Message,
      Start_Canary_Message,
      Cancel_Message,
      Admission_Revoked_Message,
      Drained_Message,
      Compensation_Message,
      Promote_Message,
      Drain_Message,
      Commit_Message,
      Failure_Message,
      Shutdown_Message,
      Acknowledgment);

   --  Significant control-payload length.
   subtype Payload_Length is Natural range 0 .. Maximum_Payload;
   --  Index range of fixed payload storage.
   subtype Payload_Index is Natural range 0 .. Maximum_Payload - 1;
   --  Fixed storage for one bounded control payload.
   type Payload_Buffer is array (Payload_Index) of Octet;

   --  One decoded control message. Only Payload (0 .. Length - 1) is
   --  significant. Decode zeroes the unused suffix.
   --  @field Kind Message operation
   --  @field Authority Exact upgrade transaction
   --  @field Sequence Nonzero monotonically increasing direction sequence
   --  @field Length Significant payload bytes
   --  @field Payload Fixed bounded payload storage
   type Frame is record
      Kind      : Message_Kind;
      Authority : Upgrade_Handle;
      Sequence  : Interfaces.Unsigned_64;
      Length    : Payload_Length;
      Payload   : Payload_Buffer;
   end record;

   --  Fail-closed decode classification.
   --  @enum Decoded Frame or header is structurally valid
   --  @enum Need_More_Data Input ends before the declared frame extent
   --  @enum Wrong_Length Input contains bytes beyond one complete frame
   --  @enum Bad_Magic Header does not carry the Flyology protocol marker
   --  @enum Unsupported_Version Header protocol version is unsupported
   --  @enum Unknown_Message Message kind code is unknown
   --  @enum Invalid_Identity An authority component is zero
   --  @enum Invalid_Sequence Direction sequence is zero
   --  @enum Oversized_Payload Declared payload exceeds the bounded maximum
   --  @enum Nonzero_Reserved Reserved header bytes are not zero
   type Decode_Status is
     (Decoded,
      Need_More_Data,
      Wrong_Length,
      Bad_Magic,
      Unsupported_Version,
      Unknown_Message,
      Invalid_Identity,
      Invalid_Sequence,
      Oversized_Payload,
      Nonzero_Reserved);

   --  Return the exact wire extent for Item.
   --  @param Item Decoded frame
   --  @return Header and significant payload size in bytes
   function Encoded_Length (Item : Frame) return Positive
   is (Header_Length + Item.Length);

   --  Encode one frame into an exact-sized caller buffer.
   --  @param Item Frame to encode
   --  @param Output Exact-sized destination bytes
   procedure Encode (Item : Frame; Output : out Octet_Array)
   with Global => null, Pre => Output'Length = Encoded_Length (Item);

   --  Validate one exact header and return its declared payload size. Decoded
   --  means the header is structurally valid even when a payload must still be
   --  read. Wrong_Length means Input is not exactly Header_Length bytes.
   --  @param Input Candidate header bytes
   --  @param Length Declared payload length, or zero on failure
   --  @param Status Header classification
   procedure Inspect_Header (Input : Octet_Array; Length : out Payload_Length; Status : out Decode_Status)
   with Global => null, Post => (if Status /= Decoded then Length = 0);

   --  Decode one complete frame. Need_More_Data reports an incomplete header
   --  or payload; Wrong_Length reports bytes after one complete frame. Item is
   --  initialized to a harmless value on every non-Decoded outcome.
   --  @param Input Candidate complete-frame bytes
   --  @param Item Decoded frame, or a harmless initialized value on failure
   --  @param Status Decode classification
   procedure Decode (Input : Octet_Array; Item : out Frame; Status : out Decode_Status)
   with
     Global => null,
     Post   => (if Status = Decoded then Input'Length = Encoded_Length (Item) and then Item.Sequence > 0);

end Flyology.Process_Generations.Protocol;
