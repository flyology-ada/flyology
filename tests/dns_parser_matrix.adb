with Ada.Exceptions;
with Ada.Streams;
with Ada.Text_IO;
with Flyology.IO.DNS;
with Flyology.IO.DNS.Testing;
with Interfaces;

procedure DNS_Parser_Matrix is
   package DNS renames Flyology.IO.DNS;
   package Testing renames Flyology.IO.DNS.Testing;
   package Streams renames Ada.Streams;
   use type Interfaces.Unsigned_32;
   use type Streams.Stream_Element_Offset;

   subtype Packet is Streams.Stream_Element_Array;
   subtype Byte is Streams.Stream_Element;
   subtype Offset is Streams.Stream_Element_Offset;
   type Offset_Array is array (Positive range <>) of Offset;

   Base : constant Packet (1 .. 43) :=
     [16#12#,
      16#34#,
      16#81#,
      16#80#,
      0,
      1,
      0,
      1,
      0,
      0,
      0,
      0,
      4,
      Character'Pos ('f'),
      Character'Pos ('u'),
      Character'Pos ('z'),
      Character'Pos ('z'),
      4,
      Character'Pos ('t'),
      Character'Pos ('e'),
      Character'Pos ('s'),
      Character'Pos ('t'),
      0,
      0,
      1,
      0,
      1,
      16#C0#,
      12,
      0,
      1,
      0,
      1,
      0,
      0,
      0,
      60,
      0,
      4,
      192,
      0,
      2,
      1];

   type Expected_Result is (Accepted, Malformed);
   Accepted_Cases  : Natural := 0;
   Malformed_Cases : Natural := 0;
   Safety_Cases    : Natural := 0;

   Seed  : constant Interfaces.Unsigned_32 := 16#F1A0_1091#;
   State : Interfaces.Unsigned_32 := Seed;

   function Next_Random return Interfaces.Unsigned_32 is
   begin
      State := State xor Interfaces.Shift_Left (State, 13);
      State := State xor Interfaces.Shift_Right (State, 17);
      State := State xor Interfaces.Shift_Left (State, 5);
      return State;
   end Next_Random;

   function Observe
     (Value         : Packet;
      Context       : String;
      Expected_ID   : Natural := 16#1234#;
      Expected_Name : String := "fuzz.test";
      For_IPv6      : Boolean := False) return Expected_Result is
   begin
      Testing.Validate_Response (Value, Expected_ID, Expected_Name, For_IPv6);
      return Accepted;
   exception
      when DNS.Malformed_Response =>
         return Malformed;
      when Error : others =>
         raise Program_Error
           with
             "DNS parser leaked an exception for "
             & Context
             & ": "
             & Ada.Exceptions.Exception_Information (Error);
   end Observe;

   procedure Assert_Sentinel (Context : String) is
   begin
      if Observe (Base, Context & " sentinel") /= Accepted then
         raise Program_Error with "DNS parser retained state after " & Context;
      end if;
   end Assert_Sentinel;

   procedure Check
     (Value         : Packet;
      Expected      : Expected_Result;
      Context       : String;
      Expected_ID   : Natural := 16#1234#;
      Expected_Name : String := "fuzz.test";
      For_IPv6      : Boolean := False)
   is
      Actual : constant Expected_Result := Observe (Value, Context, Expected_ID, Expected_Name, For_IPv6);
   begin
      if Actual /= Expected then
         raise Program_Error
           with
             "DNS parser category mismatch for "
             & Context
             & ": expected "
             & Expected'Image
             & ", got "
             & Actual'Image;
      end if;
      case Expected is
         when Accepted  =>
            Accepted_Cases := Accepted_Cases + 1;

         when Malformed =>
            Malformed_Cases := Malformed_Cases + 1;
      end case;
      Assert_Sentinel (Context);
   end Check;

   procedure Check_Safe (Value : Packet; Case_Number : Positive) is
      Context : constant String := "seed" & Interfaces.Unsigned_32'Image (Seed) & " case" & Case_Number'Image;
      Result  : constant Expected_Result := Observe (Value, Context);
      pragma Unreferenced (Result);
   begin
      Safety_Cases := Safety_Cases + 1;
      Assert_Sentinel (Context);
   end Check_Safe;

   type Wire_Buffer is array (Positive range 1 .. 4_096) of Byte;

   procedure Put (Buffer : in out Wire_Buffer; Last : in out Natural; Value : Natural) is
   begin
      Last := Last + 1;
      Buffer (Last) := Byte (Value);
   end Put;

   procedure Put_U16 (Buffer : in out Wire_Buffer; Last : in out Natural; Value : Natural) is
   begin
      Put (Buffer, Last, (Value / 256) mod 256);
      Put (Buffer, Last, Value mod 256);
   end Put_U16;

   procedure Put_U32 (Buffer : in out Wire_Buffer; Last : in out Natural; Value : Interfaces.Unsigned_32) is
   begin
      Put (Buffer, Last, Natural (Interfaces.Shift_Right (Value, 24) and 16#FF#));
      Put (Buffer, Last, Natural (Interfaces.Shift_Right (Value, 16) and 16#FF#));
      Put (Buffer, Last, Natural (Interfaces.Shift_Right (Value, 8) and 16#FF#));
      Put (Buffer, Last, Natural (Value and 16#FF#));
   end Put_U32;

   procedure Put_Name (Buffer : in out Wire_Buffer; Last : in out Natural; Name : String) is
      First : Positive := Name'First;
      Stop  : Natural;
   begin
      while First <= Name'Last loop
         Stop := First;
         while Stop <= Name'Last and then Name (Stop) /= '.' loop
            Stop := Stop + 1;
         end loop;
         Put (Buffer, Last, Stop - First);
         for Index in First .. Stop - 1 loop
            Put (Buffer, Last, Character'Pos (Name (Index)));
         end loop;
         First := Stop + 1;
      end loop;
      Put (Buffer, Last, 0);
   end Put_Name;

   procedure Put_Pointer (Buffer : in out Wire_Buffer; Last : in out Natural; Target : Natural) is
   begin
      Put (Buffer, Last, 16#C0# + (Target / 256) mod 64);
      Put (Buffer, Last, Target mod 256);
   end Put_Pointer;

   procedure Start_Response
     (Buffer      : in out Wire_Buffer;
      Last        : out Natural;
      Flags       : Natural := 16#8180#;
      Questions   : Natural := 1;
      Answers     : Natural := 0;
      Authorities : Natural := 0;
      Additionals : Natural := 0;
      Name        : String := "fuzz.test";
      Kind        : Natural := 1;
      Class       : Natural := 1) is
   begin
      Last := 0;
      Put_U16 (Buffer, Last, 16#1234#);
      Put_U16 (Buffer, Last, Flags);
      Put_U16 (Buffer, Last, Questions);
      Put_U16 (Buffer, Last, Answers);
      Put_U16 (Buffer, Last, Authorities);
      Put_U16 (Buffer, Last, Additionals);
      if Questions > 0 then
         Put_Name (Buffer, Last, Name);
         Put_U16 (Buffer, Last, Kind);
         Put_U16 (Buffer, Last, Class);
      end if;
   end Start_Response;

   procedure Put_Record_Header
     (Buffer      : in out Wire_Buffer;
      Last        : in out Natural;
      Kind        : Natural;
      Data_Length : Natural;
      Class       : Natural := 1;
      TTL         : Interfaces.Unsigned_32 := 60) is
   begin
      Put_Pointer (Buffer, Last, 12);
      Put_U16 (Buffer, Last, Kind);
      Put_U16 (Buffer, Last, Class);
      Put_U32 (Buffer, Last, TTL);
      Put_U16 (Buffer, Last, Data_Length);
   end Put_Record_Header;

   function Value_Of (Buffer : Wire_Buffer; Last : Natural) return Packet is
      Result : Packet (1 .. Offset (Last));
   begin
      for Index in 1 .. Last loop
         Result (Offset (Index)) := Buffer (Index);
      end loop;
      return Result;
   end Value_Of;

   procedure Check_Header_And_Question_Boundaries is
      Mutant  : Packet (Base'Range);
      Empty   : Packet (1 .. 0);
      Shifted : Packet (-20 .. 22);
   begin
      Check (Empty, Malformed, "empty packet");
      for Last in Base'First .. 12 loop
         Check (Base (Base'First .. Last), Malformed, "header truncation" & Last'Image);
      end loop;
      for Last in 13 .. Base'Last - 1 loop
         Check (Base (Base'First .. Last), Malformed, "body truncation" & Last'Image);
      end loop;

      for Index in Base'Range loop
         Shifted (Shifted'First + Index - Base'First) := Base (Index);
      end loop;
      Check (Shifted, Accepted, "negative lower bound");

      Mutant := Base;
      Mutant (1) := 0;
      Check (Mutant, Malformed, "transaction ID mismatch");
      Check (Base, Malformed, "expected transaction ID zero", Expected_ID => 0);
      Check (Base, Malformed, "expected transaction ID maximum", Expected_ID => Natural'Last);

      Mutant := Base;
      Mutant (3) := 16#01#;
      Check (Mutant, Malformed, "query QR flag");
      Mutant := Base;
      Mutant (3) := 16#89#;
      Check (Mutant, Malformed, "nonzero opcode");

      Mutant := Base;
      Mutant (3) := 16#83#;
      Check (Mutant (1 .. 12), Accepted, "truncated response header");

      Mutant := Base;
      Mutant (4) := 16#83#;
      Check (Mutant, Accepted, "NXDOMAIN response");
      Mutant := Base;
      Mutant (4) := 16#82#;
      Check (Mutant, Accepted, "server failure response");

      for Count of Packet'[0, 2, 255] loop
         Mutant := Base;
         Mutant (5) := 0;
         Mutant (6) := Count;
         Check (Mutant, Malformed, "question count" & Natural'Image (Natural (Count)));
      end loop;

      Mutant := Base;
      Mutant (14) := Character'Pos ('x');
      Check (Mutant, Malformed, "question name mismatch");
      Mutant := Base;
      Mutant (25) := 28;
      Check (Mutant, Malformed, "question type mismatch");
      Mutant := Base;
      Mutant (27) := 2;
      Check (Mutant, Malformed, "question class mismatch");
      Check (Base, Accepted, "case-insensitive expected question", Expected_Name => "FUZZ.TEST.");

      for Field_First of Offset_Array'[7, 9, 11] loop
         Mutant := Base;
         Mutant (Field_First) := 0;
         Mutant (Field_First + 1) := 33;
         Check (Mutant, Malformed, "record count field" & Offset'Image (Field_First));
      end loop;
   end Check_Header_And_Question_Boundaries;

   procedure Check_Record_Boundaries is
      Mutant     : Packet (Base'Range);
      Buffer     : Wire_Buffer := (others => 0);
      Last       : Natural;
      Data_Start : Natural;
   begin
      Mutant := Base;
      Mutant (38) := 0;
      Mutant (39) := 0;
      Check (Mutant, Accepted, "zero A RDLENGTH");
      Mutant := Base;
      Mutant (39) := 3;
      Check (Mutant, Accepted, "short ignored A RDLENGTH");
      Mutant := Base;
      Mutant (39) := 5;
      Check (Mutant, Malformed, "RDLENGTH exceeds packet");
      Mutant := Base;
      Mutant (38) := 16#FF#;
      Mutant (39) := 16#FF#;
      Check (Mutant, Malformed, "maximum RDLENGTH");

      Mutant := Base;
      Mutant (31) := 99;
      Check (Mutant, Accepted, "unsupported record type");
      Mutant := Base;
      Mutant (33) := 2;
      Check (Mutant, Accepted, "unsupported record class");
      Mutant := Base;
      Mutant (34 .. 37) := (others => 16#FF#);
      Check (Mutant, Accepted, "maximum TTL");

      Start_Response (Buffer, Last, Answers => 1, Kind => 28);
      Put_Record_Header (Buffer, Last, Kind => 28, Data_Length => 16);
      for Index in 0 .. 15 loop
         Put (Buffer, Last, Index);
      end loop;
      Check (Value_Of (Buffer, Last), Accepted, "valid AAAA response", For_IPv6 => True);
      Check (Value_Of (Buffer, Last), Malformed, "AAAA question in A mode");

      Start_Response (Buffer, Last, Answers => 1);
      Put_Record_Header (Buffer, Last, Kind => 5, Data_Length => 13);
      Data_Start := Last + 1;
      Put_Name (Buffer, Last, "target.test");
      Check (Value_Of (Buffer, Last), Accepted, "bounded CNAME without data");

      Buffer (Data_Start - 2) := 0;
      Buffer (Data_Start - 1) := 2;
      Check (Value_Of (Buffer, Last), Malformed, "CNAME decoding exceeds RDLENGTH");

      Start_Response (Buffer, Last, Answers => 1);
      Put_Record_Header (Buffer, Last, Kind => 5, Data_Length => 2);
      Data_Start := Last + 1;
      Put_Pointer (Buffer, Last, Data_Start - 1);
      Check (Value_Of (Buffer, Last), Malformed, "CNAME RDATA compression self-cycle");

      --  A wire label may legally carry a dot byte, but the decoded dotted
      --  name would then re-encode as a different wire name and compare equal
      --  to wire-distinct owners. Such an alias target is unusable.
      Start_Response (Buffer, Last, Answers => 1);
      Put_Record_Header (Buffer, Last, Kind => 5, Data_Length => 11);
      Put (Buffer, Last, 4);
      Put (Buffer, Last, Character'Pos ('a'));
      Put (Buffer, Last, Character'Pos ('.'));
      Put (Buffer, Last, Character'Pos ('b'));
      Put (Buffer, Last, Character'Pos ('c'));
      Put_Name (Buffer, Last, "test");
      Check (Value_Of (Buffer, Last), Malformed, "CNAME target label contains a name separator");

      Start_Response (Buffer, Last, Answers => 1);
      Put_Record_Header (Buffer, Last, Kind => 5, Data_Length => 8);
      Put (Buffer, Last, 1);
      Put (Buffer, Last, Character'Pos ('.'));
      Put_Name (Buffer, Last, "test");
      Check (Value_Of (Buffer, Last), Malformed, "CNAME target label is a bare name separator");
   end Check_Record_Boundaries;

   procedure Check_Compression_And_Name_Boundaries is
      Buffer   : Wire_Buffer := (others => 0);
      Last     : Natural;
      Mutant   : Packet (1 .. 47) := (others => 0);
      Long_253 : constant String :=
        String'(1 .. 63 => 'a')
        & "."
        & String'(1 .. 63 => 'b')
        & "."
        & String'(1 .. 63 => 'c')
        & "."
        & String'(1 .. 61 => 'd');
      Long_254 : constant String := Long_253 & "e";
   begin
      Mutant (1 .. Base'Last) := Base;
      Mutant (29) := 43;
      Mutant (44) := 16#C0#;
      Mutant (45) := 12;
      Check (Mutant (1 .. 45), Accepted, "two-hop compression chain");

      Mutant (44) := 16#C0#;
      Mutant (45) := 45;
      Mutant (46) := 16#C0#;
      Mutant (47) := 43;
      Check (Mutant, Malformed, "two-node compression cycle");

      declare
         Short : Packet (Base'Range) := Base;
      begin
         Short (28) := 16#FF#;
         Short (29) := 16#FF#;
         Check (Short, Malformed, "compression pointer outside packet");
         Check (Short (1 .. 28), Malformed, "truncated compression pointer");
         Short := Base;
         Short (29) := 27;
         Check (Short, Malformed, "compression self-cycle");
         Short := Base;
         Short (28) := 16#40#;
         Check (Short, Malformed, "reserved label length");
         Short := Base;
         Short (28) := 63;
         Check (Short, Malformed, "label exceeds packet");
      end;

      Start_Response (Buffer, Last, Answers => 0, Name => Long_253);
      Check (Value_Of (Buffer, Last), Accepted, "maximum decoded name", Expected_Name => Long_253);
      Start_Response (Buffer, Last, Answers => 0, Name => Long_254);
      Check (Value_Of (Buffer, Last), Malformed, "decoded name over maximum");
   end Check_Compression_And_Name_Boundaries;

   procedure Check_CNAME_Depth is
      Buffer : Wire_Buffer := (others => 0);
      Last   : Natural;

      function Alias_Name (Index : Natural) return String is
         Image : constant String := Natural'Image (Index);
      begin
         return "a" & Image (Image'First + 1 .. Image'Last) & ".test";
      end Alias_Name;

      procedure Put_CNAME_Record (Owner, Target : String) is
         Data_Length : constant Natural := Target'Length + 2;
      begin
         Put_Name (Buffer, Last, Owner);
         Put_U16 (Buffer, Last, 5);
         Put_U16 (Buffer, Last, 1);
         Put_U32 (Buffer, Last, 60);
         Put_U16 (Buffer, Last, Data_Length);
         Put_Name (Buffer, Last, Target);
      end Put_CNAME_Record;
   begin
      Start_Response (Buffer, Last, Answers => 17, Name => "fuzz.test");
      Put_CNAME_Record ("fuzz.test", Alias_Name (0));
      for Index in 0 .. 15 loop
         Put_CNAME_Record (Alias_Name (Index), Alias_Name (Index + 1));
      end loop;
      Check (Value_Of (Buffer, Last), Malformed, "CNAME chain exceeds depth limit");

      Start_Response (Buffer, Last, Answers => 2, Name => "fuzz.test");
      Put_CNAME_Record ("fuzz.test", "loop.test");
      Put_CNAME_Record ("loop.test", "fuzz.test");
      Check (Value_Of (Buffer, Last), Malformed, "CNAME alias cycle");
   end Check_CNAME_Depth;

   procedure Check_Deterministic_Perturbations is
      Replacements : constant Packet := [0, 1, 16#3F#, 16#40#, 16#BF#, 16#C0#, 16#FF#];
      Mutant       : Packet (Base'Range);
      Case_Number  : Positive := 1;
   begin
      for Index in Base'Range loop
         for Replacement of Replacements loop
            Mutant := Base;
            Mutant (Index) := Replacement;
            Check_Safe (Mutant, Case_Number);
            Case_Number := Case_Number + 1;
         end loop;
      end loop;

      for Iteration in 1 .. 4_096 loop
         declare
            Random_Last    : constant Interfaces.Unsigned_32 := Next_Random;
            Last           : constant Offset := Offset (Natural (Random_Last mod 65));
            Value          : Packet (1 .. Last);
            Mutation_Count : constant Positive := Positive (Natural (Next_Random mod 8) + 1);
         begin
            for Index in Value'Range loop
               if Index <= Base'Last then
                  Value (Index) := Base (Index);
               else
                  Value (Index) := Byte (Next_Random mod 256);
               end if;
            end loop;
            if Value'Length > 0 then
               for Mutation in 1 .. Mutation_Count loop
                  declare
                     Position : constant Offset :=
                       Value'First + Offset (Natural (Next_Random mod Interfaces.Unsigned_32 (Value'Length)));
                  begin
                     Value (Position) := Byte (Next_Random mod 256);
                  end;
               end loop;
            end if;
            Check_Safe (Value, Case_Number);
            Case_Number := Case_Number + 1;
         end;
      end loop;
   end Check_Deterministic_Perturbations;

begin
   Check (Base, Accepted, "base A response");
   Check_Header_And_Question_Boundaries;
   Check_Record_Boundaries;
   Check_Compression_And_Name_Boundaries;
   Check_CNAME_Depth;
   Check_Deterministic_Perturbations;

   Ada.Text_IO.Put_Line
     ("DNS parser matrix: accepted="
      & Accepted_Cases'Image
      & " malformed="
      & Malformed_Cases'Image
      & " safety="
      & Safety_Cases'Image
      & " seed="
      & Interfaces.Unsigned_32'Image (Seed));
end DNS_Parser_Matrix;
