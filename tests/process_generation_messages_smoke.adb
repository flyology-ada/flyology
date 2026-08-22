with Flyology.Process_Generations;
with Flyology.Process_Generations.Messages;
with Flyology.Process_Generations.Protocol;

procedure Process_Generation_Messages_Smoke is
   package Generations renames Flyology.Process_Generations;
   package Messages renames Flyology.Process_Generations.Messages;
   package Protocol renames Flyology.Process_Generations.Protocol;

   use type Generations.Candidate_Role;
   use type Generations.Compensation_Result;
   use type Messages.Decode_Result;
   use type Messages.Nonzero_U64;
   use type Messages.Topology_Digest;

   Original     : constant Messages.Provisioning_Data :=
     (Application_Signature => 16#0102_0304_0506_0708#,
      Topology_Schema       => 9,
      Topology_Epoch        => 11,
      Digest                => (0 => 16#AA#, 1 => 16#BB#, 31 => 16#CC#, others => 0),
      Role                  => Generations.Fenced);
   Payload      : Protocol.Payload_Buffer;
   Copy         : Messages.Provisioning_Data;
   Proof        : Messages.Topology_Proof;
   Result       : Messages.Decode_Result;
   Compensation : Generations.Compensation_Result;
begin
   Messages.Encode_Provision (Original, Payload);
   Messages.Decode_Provision (Payload, Messages.Provision_Length, Copy, Result);
   pragma Assert (Result = Messages.Decoded);
   pragma
     Assert
       (Copy.Application_Signature = Original.Application_Signature
          and then Copy.Topology_Schema = Original.Topology_Schema
          and then Copy.Topology_Epoch = Original.Topology_Epoch
          and then Copy.Digest = Original.Digest
          and then Copy.Role = Original.Role);

   Messages.Decode_Provision (Payload, Messages.Provision_Length - 1, Copy, Result);
   pragma Assert (Result = Messages.Wrong_Length);
   Payload (57) := 1;
   Messages.Decode_Provision (Payload, Messages.Provision_Length, Copy, Result);
   pragma Assert (Result = Messages.Nonzero_Reserved);

   Messages.Encode_Provision (Original, Payload);
   for Index in 0 .. 7 loop
      Payload (Index) := 0;
   end loop;
   Messages.Decode_Provision (Payload, Messages.Provision_Length, Copy, Result);
   pragma Assert (Result = Messages.Invalid_Value);

   Messages.Encode_Topology_Proof ((Epoch => Original.Topology_Epoch, Digest => Original.Digest), Payload);
   Messages.Decode_Topology_Proof (Payload, Messages.Topology_Proof_Length, Proof, Result);
   pragma
     Assert
       (Result = Messages.Decoded
          and then Proof.Epoch = Original.Topology_Epoch
          and then Proof.Digest = Original.Digest);

   Messages.Encode_Compensation (Generations.Irreversible_Effects, Payload);
   Messages.Decode_Compensation (Payload, Messages.Compensation_Length, Compensation, Result);
   pragma Assert (Result = Messages.Decoded and then Compensation = Generations.Irreversible_Effects);
   Payload (0) := 0;
   Messages.Decode_Compensation (Payload, Messages.Compensation_Length, Compensation, Result);
   pragma Assert (Result = Messages.Invalid_Value);
end Process_Generation_Messages_Smoke;
