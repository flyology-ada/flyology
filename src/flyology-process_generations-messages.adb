package body Flyology.Process_Generations.Messages
  with SPARK_Mode
is
   use type Interfaces.Unsigned_64;
   use type Protocol.Octet;

   procedure Write_U64
     (Payload : in out Protocol.Payload_Buffer; Base : Protocol.Payload_Index; Value : Interfaces.Unsigned_64)
   with Pre => Base + 8 <= Protocol.Maximum_Payload;

   procedure Write_U64
     (Payload : in out Protocol.Payload_Buffer; Base : Protocol.Payload_Index; Value : Interfaces.Unsigned_64)
   is
   begin
      for Step in 0 .. 7 loop
         Payload (Base + Step) := Protocol.Octet (Interfaces.Shift_Right (Value, (7 - Step) * 8) and 16#FF#);
      end loop;
   end Write_U64;

   function Read_U64
     (Payload : Protocol.Payload_Buffer; Base : Protocol.Payload_Index) return Interfaces.Unsigned_64
   with Pre => Base + 8 <= Protocol.Maximum_Payload;

   function Read_U64
     (Payload : Protocol.Payload_Buffer; Base : Protocol.Payload_Index) return Interfaces.Unsigned_64
   is
      Value : Interfaces.Unsigned_64 := 0;
   begin
      for Step in 0 .. 7 loop
         Value := Interfaces.Shift_Left (Value, 8) or Interfaces.Unsigned_64 (Payload (Base + Step));
      end loop;
      return Value;
   end Read_U64;

   function Role_Code (Role : Candidate_Role) return Protocol.Octet
   is (Protocol.Octet (Candidate_Role'Pos (Role) + 1));

   function Valid_Role (Code : Protocol.Octet) return Boolean
   is (Code >= 1 and then Natural (Code) <= Candidate_Role'Pos (Candidate_Role'Last) + 1);

   function Decode_Role (Code : Protocol.Octet) return Candidate_Role
   with Pre => Valid_Role (Code);

   function Decode_Role (Code : Protocol.Octet) return Candidate_Role
   is (Candidate_Role'Val (Natural (Code) - 1));

   procedure Reset (Item : out Provisioning_Data) is
   begin
      Item :=
        (Application_Signature => 1,
         Topology_Schema       => 1,
         Topology_Epoch        => 1,
         Digest                => (others => 0),
         Role                  => Canary_Safe);
   end Reset;

   procedure Encode_Provision (Item : Provisioning_Data; Payload : out Protocol.Payload_Buffer) is
   begin
      Payload := (others => 0);
      Write_U64 (Payload, 0, Item.Application_Signature);
      Write_U64 (Payload, 8, Item.Topology_Schema);
      Write_U64 (Payload, 16, Item.Topology_Epoch);
      for Index in Item.Digest'Range loop
         Payload (24 + Index) := Item.Digest (Index);
      end loop;
      Payload (56) := Role_Code (Item.Role);
   end Encode_Provision;

   procedure Decode_Provision
     (Payload : Protocol.Payload_Buffer;
      Length  : Protocol.Payload_Length;
      Item    : out Provisioning_Data;
      Result  : out Decode_Result)
   is
      Application : Interfaces.Unsigned_64;
      Schema      : Interfaces.Unsigned_64;
      Epoch       : Interfaces.Unsigned_64;
   begin
      Reset (Item);
      if Length /= Provision_Length then
         Result := Wrong_Length;
         return;
      end if;
      for Index in 57 .. 63 loop
         if Payload (Index) /= 0 then
            Result := Nonzero_Reserved;
            return;
         end if;
      end loop;
      Application := Read_U64 (Payload, 0);
      Schema := Read_U64 (Payload, 8);
      Epoch := Read_U64 (Payload, 16);
      if Application = 0 or else Schema = 0 or else Epoch = 0 or else not Valid_Role (Payload (56)) then
         Result := Invalid_Value;
         return;
      end if;
      Item.Application_Signature := Nonzero_U64 (Application);
      Item.Topology_Schema := Nonzero_U64 (Schema);
      Item.Topology_Epoch := Nonzero_U64 (Epoch);
      for Index in Item.Digest'Range loop
         Item.Digest (Index) := Payload (24 + Index);
      end loop;
      Item.Role := Decode_Role (Payload (56));
      Result := Decoded;
   end Decode_Provision;

   procedure Encode_Topology_Proof (Item : Topology_Proof; Payload : out Protocol.Payload_Buffer) is
   begin
      Payload := (others => 0);
      Write_U64 (Payload, 0, Item.Epoch);
      for Index in Item.Digest'Range loop
         Payload (8 + Index) := Item.Digest (Index);
      end loop;
   end Encode_Topology_Proof;

   procedure Decode_Topology_Proof
     (Payload : Protocol.Payload_Buffer;
      Length  : Protocol.Payload_Length;
      Item    : out Topology_Proof;
      Result  : out Decode_Result)
   is
      Epoch : Interfaces.Unsigned_64;
   begin
      Item := (Epoch => 1, Digest => (others => 0));
      if Length /= Topology_Proof_Length then
         Result := Wrong_Length;
         return;
      end if;
      Epoch := Read_U64 (Payload, 0);
      if Epoch = 0 then
         Result := Invalid_Value;
         return;
      end if;
      Item.Epoch := Nonzero_U64 (Epoch);
      for Index in Item.Digest'Range loop
         Item.Digest (Index) := Payload (8 + Index);
      end loop;
      Result := Decoded;
   end Decode_Topology_Proof;

   function Compensation_Code (Item : Compensation_Result) return Protocol.Octet
   is (Protocol.Octet (Compensation_Result'Pos (Item) + 1));

   function Valid_Compensation (Code : Protocol.Octet) return Boolean
   is (Code >= 1 and then Natural (Code) <= Compensation_Result'Pos (Compensation_Result'Last) + 1);

   procedure Encode_Compensation (Item : Compensation_Result; Payload : out Protocol.Payload_Buffer) is
   begin
      Payload := (others => 0);
      Payload (0) := Compensation_Code (Item);
   end Encode_Compensation;

   procedure Decode_Compensation
     (Payload : Protocol.Payload_Buffer;
      Length  : Protocol.Payload_Length;
      Item    : out Compensation_Result;
      Result  : out Decode_Result) is
   begin
      Item := Not_Required;
      if Length /= Compensation_Length then
         Result := Wrong_Length;
      elsif not Valid_Compensation (Payload (0)) then
         Result := Invalid_Value;
      else
         Item := Compensation_Result'Val (Natural (Payload (0)) - 1);
         Result := Decoded;
      end if;
   end Decode_Compensation;
end Flyology.Process_Generations.Messages;
