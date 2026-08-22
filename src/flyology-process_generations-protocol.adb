package body Flyology.Process_Generations.Protocol
  with SPARK_Mode
is
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;

   Magic : constant Interfaces.Unsigned_32 := 16#464C_5955#;

   function Byte_At
     (Input : Octet_Array;
      Base  : Wire_Index;
      Step  : Wire_Index) return Octet
   is
     (Input (Input'First + Base + Step))
   with Pre => Base + Step < Input'Length;

   function Read_U16
     (Input : Octet_Array;
      Base  : Wire_Index) return Interfaces.Unsigned_16
   with Pre => Base + 2 <= Input'Length;

   function Read_U16
     (Input : Octet_Array;
      Base  : Wire_Index) return Interfaces.Unsigned_16
   is
     (Interfaces.Shift_Left
        (Interfaces.Unsigned_16 (Byte_At (Input, Base, 0)), 8)
      or Interfaces.Unsigned_16 (Byte_At (Input, Base, 1)));

   function Read_U32
     (Input : Octet_Array;
      Base  : Wire_Index) return Interfaces.Unsigned_32
   with Pre => Base + 4 <= Input'Length;

   function Read_U32
     (Input : Octet_Array;
      Base  : Wire_Index) return Interfaces.Unsigned_32
   is
      Result : Interfaces.Unsigned_32 := 0;
   begin
      for Step in 0 .. 3 loop
         Result := Interfaces.Shift_Left (Result, 8) or
           Interfaces.Unsigned_32 (Byte_At (Input, Base, Step));
      end loop;
      return Result;
   end Read_U32;

   function Read_U64
     (Input : Octet_Array;
      Base  : Wire_Index) return Interfaces.Unsigned_64
   with Pre => Base + 8 <= Input'Length;

   function Read_U64
     (Input : Octet_Array;
      Base  : Wire_Index) return Interfaces.Unsigned_64
   is
      Result : Interfaces.Unsigned_64 := 0;
   begin
      for Step in 0 .. 7 loop
         Result := Interfaces.Shift_Left (Result, 8) or
           Interfaces.Unsigned_64 (Byte_At (Input, Base, Step));
      end loop;
      return Result;
   end Read_U64;

   procedure Write_U16
     (Output : in out Octet_Array;
      Base   : Wire_Index;
      Value  : Interfaces.Unsigned_16)
   with Pre => Base + 2 <= Output'Length;

   procedure Write_U16
     (Output : in out Octet_Array;
      Base   : Wire_Index;
      Value  : Interfaces.Unsigned_16)
   is
   begin
      Output (Output'First + Base) :=
        Octet (Interfaces.Shift_Right (Value, 8) and 16#FF#);
      Output (Output'First + Base + 1) := Octet (Value and 16#FF#);
   end Write_U16;

   procedure Write_U32
     (Output : in out Octet_Array;
      Base   : Wire_Index;
      Value  : Interfaces.Unsigned_32)
   with Pre => Base + 4 <= Output'Length;

   procedure Write_U32
     (Output : in out Octet_Array;
      Base   : Wire_Index;
      Value  : Interfaces.Unsigned_32)
   is
   begin
      for Step in 0 .. 3 loop
         Output (Output'First + Base + Step) := Octet
           (Interfaces.Shift_Right (Value, (3 - Step) * 8) and 16#FF#);
      end loop;
   end Write_U32;

   procedure Write_U64
     (Output : in out Octet_Array;
      Base   : Wire_Index;
      Value  : Interfaces.Unsigned_64)
   with Pre => Base + 8 <= Output'Length;

   procedure Write_U64
     (Output : in out Octet_Array;
      Base   : Wire_Index;
      Value  : Interfaces.Unsigned_64)
   is
   begin
      for Step in 0 .. 7 loop
         Output (Output'First + Base + Step) := Octet
           (Interfaces.Shift_Right (Value, (7 - Step) * 8) and 16#FF#);
      end loop;
   end Write_U64;

   function Kind_Code (Kind : Message_Kind) return Octet is
     (Octet (Message_Kind'Pos (Kind) + 1));

   function Valid_Kind_Code (Value : Octet) return Boolean is
     (Value >= 1 and then
        Natural (Value) <= Message_Kind'Pos (Message_Kind'Last) + 1);

   function Decode_Kind (Value : Octet) return Message_Kind
   with Pre => Valid_Kind_Code (Value);

   function Decode_Kind (Value : Octet) return Message_Kind is
     (Message_Kind'Val (Natural (Value) - 1));

   procedure Reset (Item : out Frame) is
   begin
      Item :=
        (Kind      => Hello,
         Authority => (Coordinator => 1, Upgrade => 1, Candidate => 1),
         Sequence  => 1,
         Length    => 0,
         Payload   => (others => 0));
   end Reset;

   procedure Encode (Item : Frame; Output : out Octet_Array) is
   begin
      Output := (others => 0);
      Write_U32 (Output, 0, Magic);
      Write_U16 (Output, 4, Protocol_Version);
      Output (Output'First + 6) := Kind_Code (Item.Kind);
      Write_U64
        (Output, 8, Interfaces.Unsigned_64 (Item.Authority.Coordinator));
      Write_U64
        (Output, 16, Interfaces.Unsigned_64 (Item.Authority.Upgrade));
      Write_U64
        (Output, 24, Interfaces.Unsigned_64 (Item.Authority.Candidate));
      Write_U64 (Output, 32, Item.Sequence);
      Write_U16 (Output, 40, Interfaces.Unsigned_16 (Item.Length));
      if Item.Length > 0 then
         for Step in 0 .. Item.Length - 1 loop
            Output (Output'First + Header_Length + Step) :=
              Item.Payload (Step);
         end loop;
      end if;
   end Encode;

   procedure Inspect_Header
     (Input  : Octet_Array;
      Length : out Payload_Length;
      Status : out Decode_Status)
   is
      Raw_Coordinator : Interfaces.Unsigned_64;
      Raw_Upgrade     : Interfaces.Unsigned_64;
      Raw_Candidate   : Interfaces.Unsigned_64;
      Raw_Sequence    : Interfaces.Unsigned_64;
      Raw_Length      : Interfaces.Unsigned_16;
   begin
      Length := 0;
      if Input'Length /= Header_Length then
         Status := Wrong_Length;
         return;
      elsif Read_U32 (Input, 0) /= Magic then
         Status := Bad_Magic;
         return;
      elsif Read_U16 (Input, 4) /= Protocol_Version then
         Status := Unsupported_Version;
         return;
      elsif not Valid_Kind_Code (Byte_At (Input, 6, 0)) then
         Status := Unknown_Message;
         return;
      elsif Byte_At (Input, 7, 0) /= 0 then
         Status := Nonzero_Reserved;
         return;
      end if;

      for Offset in 42 .. 47 loop
         if Byte_At (Input, Offset, 0) /= 0 then
            Status := Nonzero_Reserved;
            return;
         end if;
      end loop;

      Raw_Coordinator := Read_U64 (Input, 8);
      Raw_Upgrade := Read_U64 (Input, 16);
      Raw_Candidate := Read_U64 (Input, 24);
      Raw_Sequence := Read_U64 (Input, 32);
      Raw_Length := Read_U16 (Input, 40);
      if Raw_Coordinator = 0 or else Raw_Upgrade = 0 or else
        Raw_Candidate = 0
      then
         Status := Invalid_Identity;
      elsif Raw_Sequence = 0 then
         Status := Invalid_Sequence;
      elsif Raw_Length > Interfaces.Unsigned_16 (Maximum_Payload) then
         Status := Oversized_Payload;
      else
         Length := Payload_Length (Raw_Length);
         Status := Decoded;
      end if;
   end Inspect_Header;

   procedure Decode
     (Input  : Octet_Array;
      Item   : out Frame;
      Status : out Decode_Status)
   is
      Raw_Coordinator : Interfaces.Unsigned_64;
      Raw_Upgrade     : Interfaces.Unsigned_64;
      Raw_Candidate   : Interfaces.Unsigned_64;
      Raw_Sequence    : Interfaces.Unsigned_64;
      Raw_Length      : Interfaces.Unsigned_16;
      Expected        : Wire_Count;
   begin
      Reset (Item);
      if Input'Length < Header_Length then
         Status := Need_More_Data;
         return;
      end if;

      Inspect_Header
        (Input (Input'First .. Input'First + Header_Length - 1),
         Item.Length, Status);
      if Status /= Decoded then
         return;
      end if;

      Raw_Coordinator := Read_U64 (Input, 8);
      Raw_Upgrade := Read_U64 (Input, 16);
      Raw_Candidate := Read_U64 (Input, 24);
      Raw_Sequence := Read_U64 (Input, 32);
      Raw_Length := Interfaces.Unsigned_16 (Item.Length);

      --  Retain the proof-relevant guards at the conversion site. Header
      --  inspection already rejects these values at runtime; repeating the
      --  bounded scalar tests here keeps Decode's range argument local and
      --  independently proved.
      if not Valid_Kind_Code (Byte_At (Input, 6, 0)) then
         Status := Unknown_Message;
         return;
      elsif Raw_Coordinator = 0 or else Raw_Upgrade = 0 or else
        Raw_Candidate = 0
      then
         Status := Invalid_Identity;
         return;
      elsif Raw_Sequence = 0 then
         Status := Invalid_Sequence;
         return;
      end if;

      Expected := Header_Length + Natural (Raw_Length);
      if Input'Length < Expected then
         Status := Need_More_Data;
         return;
      elsif Input'Length > Expected then
         Status := Wrong_Length;
         return;
      end if;

      Item.Kind := Decode_Kind (Byte_At (Input, 6, 0));
      Item.Authority :=
        (Coordinator => Coordinator_Id (Raw_Coordinator),
         Upgrade     => Upgrade_Id (Raw_Upgrade),
         Candidate   => Image_Generation (Raw_Candidate));
      Item.Sequence := Raw_Sequence;
      Item.Length := Payload_Length (Raw_Length);
      if Item.Length > 0 then
         for Step in 0 .. Item.Length - 1 loop
            Item.Payload (Step) :=
              Input (Input'First + Header_Length + Step);
         end loop;
      end if;
      Status := Decoded;
   end Decode;

end Flyology.Process_Generations.Protocol;
