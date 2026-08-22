with Flyology.Process_Generations.Protocol;
with Interfaces;

--  Fixed application-independent payloads carried inside control frames.
--  Enumeration positions and Ada record layouts never cross the wire.
package Flyology.Process_Generations.Messages
  with Preelaborate,
       SPARK_Mode
is
   package Protocol renames Flyology.Process_Generations.Protocol;

   --  Nonzero identifier represented in fixed-width payloads.
   subtype Nonzero_U64 is Interfaces.Unsigned_64 range
     1 .. Interfaces.Unsigned_64'Last;
   --  Stable digest of the desired application topology.
   type Topology_Digest is array (Natural range 0 .. 31) of Protocol.Octet;

   --  Wire size of a provisioning payload.
   Provision_Length : constant Protocol.Payload_Length := 64;
   --  Wire size of a topology-proof payload.
   Topology_Proof_Length : constant Protocol.Payload_Length := 40;
   --  Wire size of a compensation-result payload.
   Compensation_Length : constant Protocol.Payload_Length := 1;

   --  Desired topology and candidate role supplied before activation.
   --  @field Application_Signature Application protocol identity
   --  @field Topology_Schema Application topology schema identity
   --  @field Topology_Epoch Desired deployment topology epoch
   --  @field Digest Digest of the desired topology
   --  @field Role Candidate effect and admission role
   type Provisioning_Data is record
      Application_Signature : Nonzero_U64;
      Topology_Schema       : Nonzero_U64;
      Topology_Epoch        : Nonzero_U64;
      Digest                : Topology_Digest;
      Role                  : Candidate_Role;
   end record;

   --  Candidate evidence that its reconstructed topology matches provision.
   --  @field Epoch Reconstructed topology epoch
   --  @field Digest Reconstructed topology digest
   type Topology_Proof is record
      Epoch  : Nonzero_U64;
      Digest : Topology_Digest;
   end record;

   --  Fail-closed payload decode classification.
   --  @enum Decoded Payload is valid
   --  @enum Wrong_Length Payload length does not match its message kind
   --  @enum Invalid_Value A field has no valid application representation
   --  @enum Nonzero_Reserved Reserved payload bytes are not zero
   type Decode_Result is
     (Decoded,
      Wrong_Length,
      Invalid_Value,
      Nonzero_Reserved);

   --  Encode provisioning data and zero the unused payload suffix.
   --  @param Item Provisioning data to encode
   --  @param Payload Destination payload buffer
   procedure Encode_Provision
     (Item    : Provisioning_Data;
      Payload : out Protocol.Payload_Buffer)
   with Global => null;

   --  Decode one provisioning payload without raising for malformed bytes.
   --  @param Payload Source payload buffer
   --  @param Length Significant source bytes
   --  @param Item Decoded data, or a harmless initialized value on failure
   --  @param Result Decode classification
   procedure Decode_Provision
     (Payload : Protocol.Payload_Buffer;
      Length  : Protocol.Payload_Length;
      Item    : out Provisioning_Data;
      Result  : out Decode_Result)
   with Global => null;

   --  Encode topology evidence and zero the unused payload suffix.
   --  @param Item Topology evidence to encode
   --  @param Payload Destination payload buffer
   procedure Encode_Topology_Proof
     (Item    : Topology_Proof;
      Payload : out Protocol.Payload_Buffer)
   with Global => null;

   --  Decode topology evidence without raising for malformed bytes.
   --  @param Payload Source payload buffer
   --  @param Length Significant source bytes
   --  @param Item Decoded proof, or a harmless initialized value on failure
   --  @param Result Decode classification
   procedure Decode_Topology_Proof
     (Payload : Protocol.Payload_Buffer;
      Length  : Protocol.Payload_Length;
      Item    : out Topology_Proof;
      Result  : out Decode_Result)
   with Global => null;

   --  Encode one compensation outcome.
   --  @param Item Compensation outcome to encode
   --  @param Payload Destination payload buffer
   procedure Encode_Compensation
     (Item    : Compensation_Result;
      Payload : out Protocol.Payload_Buffer)
   with Global => null;

   --  Decode one compensation outcome without raising for malformed bytes.
   --  @param Payload Source payload buffer
   --  @param Length Significant source bytes
   --  @param Item Decoded outcome, or a harmless initialized value on failure
   --  @param Result Decode classification
   procedure Decode_Compensation
     (Payload : Protocol.Payload_Buffer;
      Length  : Protocol.Payload_Length;
      Item    : out Compensation_Result;
      Result  : out Decode_Result)
   with Global => null;
end Flyology.Process_Generations.Messages;
