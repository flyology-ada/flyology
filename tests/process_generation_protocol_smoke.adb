with Interfaces;
with Flyology.Process_Generations;
with Flyology.Process_Generations.Protocol;

procedure Process_Generation_Protocol_Smoke is
   package Generations renames Flyology.Process_Generations;
   package Protocol renames Flyology.Process_Generations.Protocol;

   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_64;
   use type Protocol.Message_Kind;
   use type Protocol.Decode_Status;

   Original : constant Protocol.Frame :=
     (Kind      => Protocol.Provision,
      Authority => (Coordinator => 7, Upgrade => 9, Candidate => 11),
      Sequence  => 13,
      Length    => 3,
      Payload   => (0 => 16#AA#, 1 => 16#BB#, 2 => 16#CC#, others => 0));
   Wire : Protocol.Octet_Array
     (0 .. Protocol.Encoded_Length (Original) - 1);
   Copy   : Protocol.Frame;
   Status : Protocol.Decode_Status;
   Length : Protocol.Payload_Length;
begin
   Protocol.Encode (Original, Wire);
   Protocol.Inspect_Header
     (Wire (Wire'First .. Wire'First + Protocol.Header_Length - 1),
      Length, Status);
   pragma Assert (Status = Protocol.Decoded and then Length = 3);
   Protocol.Decode (Wire, Copy, Status);
   pragma Assert (Status = Protocol.Decoded);
   pragma Assert (Copy.Kind = Original.Kind);
   pragma Assert
     (Generations.Same_Upgrade (Copy.Authority, Original.Authority));
   pragma Assert (Copy.Sequence = Original.Sequence);
   pragma Assert (Copy.Length = 3);
   pragma Assert
     (Copy.Payload (0) = 16#AA# and then
      Copy.Payload (1) = 16#BB# and then
      Copy.Payload (2) = 16#CC# and then
      Copy.Payload (3) = 0);

   declare
      Short : constant Protocol.Octet_Array
        (0 .. Protocol.Header_Length - 2) :=
        (others => 0);
   begin
      Protocol.Inspect_Header (Short, Length, Status);
      pragma Assert (Status = Protocol.Wrong_Length and then Length = 0);
      Protocol.Decode (Short, Copy, Status);
      pragma Assert (Status = Protocol.Need_More_Data);
   end;

   Wire (Wire'First) := 0;
   Protocol.Decode (Wire, Copy, Status);
   pragma Assert (Status = Protocol.Bad_Magic);
   Protocol.Encode (Original, Wire);

   Wire (Wire'First + 4) := 0;
   Wire (Wire'First + 5) := 2;
   Protocol.Decode (Wire, Copy, Status);
   pragma Assert (Status = Protocol.Unsupported_Version);
   Protocol.Encode (Original, Wire);

   Wire (Wire'First + 6) := 255;
   Protocol.Decode (Wire, Copy, Status);
   pragma Assert (Status = Protocol.Unknown_Message);
   Protocol.Encode (Original, Wire);

   Wire (Wire'First + 7) := 1;
   Protocol.Decode (Wire, Copy, Status);
   pragma Assert (Status = Protocol.Nonzero_Reserved);
   Protocol.Encode (Original, Wire);

   for Offset in 8 .. 15 loop
      Wire (Wire'First + Offset) := 0;
   end loop;
   Protocol.Decode (Wire, Copy, Status);
   pragma Assert (Status = Protocol.Invalid_Identity);
   Protocol.Encode (Original, Wire);

   for Offset in 32 .. 39 loop
      Wire (Wire'First + Offset) := 0;
   end loop;
   Protocol.Decode (Wire, Copy, Status);
   pragma Assert (Status = Protocol.Invalid_Sequence);
   Protocol.Encode (Original, Wire);

   Wire (Wire'First + 40) := 16#FF#;
   Wire (Wire'First + 41) := 16#FF#;
   Protocol.Decode (Wire, Copy, Status);
   pragma Assert (Status = Protocol.Oversized_Payload);
   Protocol.Encode (Original, Wire);

   declare
      Long : Protocol.Octet_Array (0 .. Wire'Length) := (others => 0);
   begin
      for Step in 0 .. Wire'Length - 1 loop
         Long (Long'First + Step) := Wire (Wire'First + Step);
      end loop;
      Protocol.Decode (Long, Copy, Status);
      pragma Assert (Status = Protocol.Wrong_Length);
   end;
end Process_Generation_Protocol_Smoke;
