with Ada.Characters.Handling;
with Ada.Real_Time;
with Ada.Strings.Fixed;
#if FLYOLOGY_DNS_TEST_HOOKS then
with Flyology.DNS_Test_Observations;
#end if;
with Flyology.IO.Files;
with Interfaces;
with Interfaces.C;
with System;

package body Flyology.IO.DNS is
   package Sockets renames Flyology.IO.Sockets;
   package Streams renames Ada.Streams;
   package U8 renames Interfaces;
   package C renames Interfaces.C;

   use type Ada.Real_Time.Time;
   use type Descriptor;
   use type U8.Unsigned_32;
   use type Streams.Stream_Element_Offset;
   use type Streams.Stream_Element;
   use type Sockets.Address_Family;
   use type Flyology.IO.Files.File_Descriptor;

   Max_Name_Length      : constant := 253;
   Max_Packet_Length    : constant := 4_096;
   Max_TCP_Packet_Length : constant := 16_384;
   Max_Config_Length     : constant := 16_384;
   Max_Name_Servers     : constant := 4;
   Max_Search_Domains   : constant := 6;
   Max_Addresses        : constant := 16;
   Max_Records          : constant := 32;
   Max_Cache_Entries    : constant := 64;
   Max_Cache_Key_Length : constant := 512;
   DNS_Port             : constant Sockets.Port := 53;
   Type_A               : constant Natural := 1;
   Type_CNAME           : constant Natural := 5;
   Type_SOA             : constant Natural := 6;
   Type_AAAA            : constant Natural := 28;
   Class_IN             : constant Natural := 1;

   subtype Byte is U8.Unsigned_8;
   type Byte_Array is array (Natural range <>) of Byte;
   type Name_Buffer is record
      Length : Natural range 0 .. Max_Name_Length := 0;
      Data   : String (1 .. Max_Name_Length) := (others => ' ');
   end record;

   type Raw_Address is record
      Family : Sockets.Address_Family := Sockets.IPv4;
      Bytes  : Byte_Array (1 .. 16) := (others => 0);
   end record;
   type Raw_Address_Array is array (Positive range <>) of Raw_Address;

   type Parsed_Record is record
      Owner  : Name_Buffer;
      Kind   : Natural := 0;
      TTL    : Natural := 0;
      Target : Name_Buffer;
      Address : Raw_Address;
   end record;
   type Parsed_Record_Array is array (Positive range <>) of Parsed_Record;
   type Name_Buffer_Array is array (Positive range <>) of Name_Buffer;

   type Parse_Outcome is
     (Answer, No_Data, Not_Found, Truncated, Server_Failure);
   type Parse_Result is record
      Outcome      : Parse_Outcome := No_Data;
      Addresses    : Raw_Address_Array (1 .. Max_Addresses);
      Address_Count : Natural range 0 .. Max_Addresses := 0;
      Canonical    : Name_Buffer;
      TTL          : Natural := 0;
      Negative_TTL : Natural := 30;
   end record;

   type Resolver_Config is record
      Servers      : Name_Server_Array (1 .. Max_Name_Servers);
      Server_Count : Natural range 0 .. Max_Name_Servers := 0;
      Search       : Name_Buffer_Array (1 .. Max_Search_Domains);
      Search_Count : Natural range 0 .. Max_Search_Domains := 0;
      NDots        : Natural range 0 .. 15 := 1;
      Attempts     : Positive range 1 .. 5 := 2;
      Per_Attempt  : Duration := 2.0;
      Rotate       : Boolean := False;
   end record;

   type Cache_Entry is record
      Used       : Boolean := False;
      Key_Length : Natural range 0 .. Max_Cache_Key_Length := 0;
      Key        : String (1 .. Max_Cache_Key_Length) := (others => ' ');
      Expires    : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Negative   : Boolean := False;
      Values     : Raw_Address_Array (1 .. Max_Addresses);
      Count      : Natural range 0 .. Max_Addresses := 0;
      Stamp      : Natural := 0;
   end record;
   type Cache_Entry_Array is array (Positive range <>) of Cache_Entry;

   protected Cache is
      procedure Lookup
        (Key      : String;
         Found    : out Boolean;
         Negative : out Boolean;
         Values   : out Raw_Address_Array;
         Count    : out Natural;
         TTL      : out Natural);
      procedure Store
        (Key      : String;
         Negative : Boolean;
         Values   : Raw_Address_Array;
         Count    : Natural;
         TTL      : Natural);
      procedure Clear;
   private
      Entries : Cache_Entry_Array (1 .. Max_Cache_Entries);
      Clock   : Natural := 0;
   end Cache;

   protected body Cache is
      procedure Lookup
        (Key      : String;
         Found    : out Boolean;
         Negative : out Boolean;
         Values   : out Raw_Address_Array;
         Count    : out Natural;
         TTL      : out Natural)
      is
         Now : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      begin
         Found := False;
         Negative := False;
         Count := 0;
         TTL := 0;
         for Item of Entries loop
            if Item.Used
              and then Item.Key_Length = Key'Length
              and then Item.Key (1 .. Item.Key_Length) = Key
            then
               if Item.Expires <= Now then
                  Item.Used := False;
                  return;
               end if;
               Found := True;
               Negative := Item.Negative;
               Count := Item.Count;
               TTL := Natural'Max
                 (1, Natural
                    (Ada.Real_Time.To_Duration (Item.Expires - Now)));
               for Index in 1 .. Count loop
                  Values (Values'First + Index - 1) := Item.Values (Index);
               end loop;
               if Clock = Natural'Last then
                  Clock := 0;
               else
                  Clock := Clock + 1;
               end if;
               Item.Stamp := Clock;
               return;
            end if;
         end loop;
      end Lookup;

      procedure Store
        (Key      : String;
         Negative : Boolean;
         Values   : Raw_Address_Array;
         Count    : Natural;
         TTL      : Natural)
      is
         Slot : Positive := Entries'First;
         Oldest : Natural := Natural'Last;
         Effective_TTL : constant Natural := Natural'Min (TTL, 86_400);
      begin
         if Key'Length > Max_Cache_Key_Length or else Effective_TTL = 0 then
            return;
         end if;
         --  Prefer an exact replacement before considering unused/LRU slots;
         --  otherwise a hole before a matching entry could create duplicates.
         for Index in Entries'Range loop
            if Entries (Index).Used
              and then Entries (Index).Key_Length = Key'Length
              and then Entries (Index).Key (1 .. Key'Length) = Key
            then
               Slot := Index;
               exit;
            end if;
         end loop;
         if not (Entries (Slot).Used
           and then Entries (Slot).Key_Length = Key'Length
           and then Entries (Slot).Key (1 .. Key'Length) = Key)
         then
            for Index in Entries'Range loop
               if not Entries (Index).Used then
                  Slot := Index;
                  exit;
               elsif Entries (Index).Stamp < Oldest then
                  Oldest := Entries (Index).Stamp;
                  Slot := Index;
               end if;
            end loop;
         end if;
         if Clock = Natural'Last then
            Clock := 0;
         else
            Clock := Clock + 1;
         end if;
         Entries (Slot).Used := True;
         Entries (Slot).Key_Length := Key'Length;
         Entries (Slot).Key (1 .. Key'Length) := Key;
         Entries (Slot).Expires :=
           Ada.Real_Time.Clock + Ada.Real_Time.Seconds (Effective_TTL);
         Entries (Slot).Negative := Negative;
         Entries (Slot).Count := Natural'Min (Count, Max_Addresses);
         Entries (Slot).Stamp := Clock;
         for Index in 1 .. Entries (Slot).Count loop
            Entries (Slot).Values (Index) :=
              Values (Values'First + Index - 1);
         end loop;
      end Store;

      procedure Clear is
      begin
         for Item of Entries loop
            Item.Used := False;
         end loop;
      end Clear;
   end Cache;

   protected Transaction_IDs is
      procedure Next_Test (Used : out Boolean; Value : out Natural);
      procedure Use_Deterministic (First : Natural);
      procedure Use_OS;
   private
      Deterministic : Boolean := False;
      Current       : Natural range 0 .. 65_535 := 0;
   end Transaction_IDs;

   protected body Transaction_IDs is
      procedure Next_Test (Used : out Boolean; Value : out Natural) is
      begin
         Used := Deterministic;
         if Deterministic then
            Value := Current;
            Current := (Current + 1) mod 65_536;
         else
            Value := 0;
         end if;
      end Next_Test;

      procedure Use_Deterministic (First : Natural) is
      begin
         Deterministic := True;
         Current := First mod 65_536;
      end Use_Deterministic;

      procedure Use_OS is
      begin
         Deterministic := False;
         Current := 0;
      end Use_OS;
   end Transaction_IDs;

   function Getentropy
     (Buffer : System.Address; Length : C.size_t) return C.int;
   pragma Import (C, Getentropy, "getentropy");

   function Next_Transaction_ID return Natural is
      Value : aliased Interfaces.Unsigned_16 := 0;
      Used  : Boolean;
      Test_Value : Natural;
   begin
      Transaction_IDs.Next_Test (Used, Test_Value);
      if Used then
         return Test_Value;
      end if;
      --  There is deliberately no cached PRNG state: getentropy is called for
      --  every query, so forked children cannot repeat a parent-side stream.
      if Getentropy
        (Value'Address, C.size_t (Value'Size / System.Storage_Unit)) /= 0
      then
         raise Resolution_Failed with
           "operating-system entropy unavailable for DNS transaction ID";
      end if;
      return Natural (Value);
   end Next_Transaction_ID;

   procedure Use_Deterministic_Transaction_IDs (First : Natural) is
   begin
      Transaction_IDs.Use_Deterministic (First);
   end Use_Deterministic_Transaction_IDs;

   procedure Use_OS_Transaction_IDs is
   begin
      Transaction_IDs.Use_OS;
   end Use_OS_Transaction_IDs;

   protected Server_Rotation is
      procedure Next (Count : Positive; Offset : out Natural);
   private
      Current : Natural := 0;
   end Server_Rotation;

   protected body Server_Rotation is
      procedure Next (Count : Positive; Offset : out Natural) is
      begin
         Offset := Current mod Count;
         if Current = Natural'Last then
            Current := 0;
         else
            Current := Current + 1;
         end if;
      end Next;
   end Server_Rotation;

   function Lower (Value : String) return String is
      Result : String (Value'Range);
   begin
      for Index in Value'Range loop
         Result (Index) := Ada.Characters.Handling.To_Lower (Value (Index));
      end loop;
      return Result;
   end Lower;

   function To_Name (Value : String) return Name_Buffer is
      Result : Name_Buffer;
      First  : Positive := Value'First;
      Last   : Natural := Value'Last;
   begin
      while First <= Value'Last and then Value (First) = ' ' loop
         First := First + 1;
      end loop;
      while Last >= First and then Value (Last) = ' ' loop
         Last := Last - 1;
      end loop;
      if Last >= First and then Value (Last) = '.' then
         Last := Last - 1;
      end if;
      if Last < First or else Last - First + 1 > Max_Name_Length then
         raise Resolution_Failed with "invalid DNS name length";
      end if;
      Result.Length := Last - First + 1;
      Result.Data (1 .. Result.Length) := Lower (Value (First .. Last));
      return Result;
   end To_Name;

   function Image (Value : Name_Buffer) return String is
     (Value.Data (1 .. Value.Length));

   function Same_Name (Left, Right : Name_Buffer) return Boolean is
     (Left.Length = Right.Length
      and then Left.Data (1 .. Left.Length) = Right.Data (1 .. Right.Length));

   function U16_At (Packet : Byte_Array; Position : Natural) return Natural is
   begin
      if Position + 1 > Packet'Last then
         raise Malformed_Response with "truncated DNS integer";
      end if;
      return
        Natural (Packet (Position)) * 256
        + Natural (Packet (Position + 1));
   end U16_At;

   function U32_At (Packet : Byte_Array; Position : Natural) return Natural is
      Value : U8.Unsigned_32 := 0;
   begin
      if Position + 3 > Packet'Last then
         raise Malformed_Response with "truncated DNS integer";
      end if;
      for Index in Position .. Position + 3 loop
         Value := Interfaces.Shift_Left (Value, 8)
           or U8.Unsigned_32 (Packet (Index));
      end loop;
      if Value > U8.Unsigned_32 (Natural'Last) then
         return Natural'Last;
      else
         return Natural (Value);
      end if;
   end U32_At;

   procedure Put_U16
     (Packet : in out Byte_Array; Position : in out Natural; Value : Natural)
   is
   begin
      if Position + 1 > Packet'Last then
         raise Resolution_Failed with "DNS query buffer exhausted";
      end if;
      Packet (Position) := Byte ((Value / 256) mod 256);
      Packet (Position + 1) := Byte (Value mod 256);
      Position := Position + 2;
   end Put_U16;

   procedure Encode_Name
     (Name     : Name_Buffer;
      Packet   : in out Byte_Array;
      Position : in out Natural)
   is
      Start : Positive := 1;
      Stop  : Natural;
   begin
      while Start <= Name.Length loop
         Stop := Start;
         while Stop <= Name.Length and then Name.Data (Stop) /= '.' loop
            Stop := Stop + 1;
         end loop;
         if Stop = Start or else Stop - Start > 63 then
            raise Resolution_Failed with "invalid DNS label";
         elsif Position > Packet'Last then
            raise Resolution_Failed with "DNS query buffer exhausted";
         end if;
         Packet (Position) := Byte (Stop - Start);
         Position := Position + 1;
         for Index in Start .. Stop - 1 loop
            if Position > Packet'Last then
               raise Resolution_Failed with "DNS query buffer exhausted";
            end if;
            Packet (Position) := Byte (Character'Pos (Name.Data (Index)));
            Position := Position + 1;
         end loop;
         Start := Stop + 1;
      end loop;
      if Position > Packet'Last then
         raise Resolution_Failed with "DNS query buffer exhausted";
      end if;
      Packet (Position) := 0;
      Position := Position + 1;
   end Encode_Name;

   function Build_Query
     (Name : Name_Buffer; Kind : Natural; ID : Natural) return Byte_Array
   is
      Buffer : Byte_Array (0 .. 511) := (others => 0);
      Position : Natural := 0;
   begin
      Put_U16 (Buffer, Position, ID);
      Put_U16 (Buffer, Position, 16#0100#);
      Put_U16 (Buffer, Position, 1);
      Put_U16 (Buffer, Position, 0);
      Put_U16 (Buffer, Position, 0);
      Put_U16 (Buffer, Position, 0);
      Encode_Name (Name, Buffer, Position);
      Put_U16 (Buffer, Position, Kind);
      Put_U16 (Buffer, Position, Class_IN);
      return Buffer (0 .. Position - 1);
   end Build_Query;

   function Decode_Name
     (Packet : Byte_Array; Start : Natural; Next : out Natural)
      return Name_Buffer
   is
      Position : Natural := Start;
      Result   : Name_Buffer;
      Jumped   : Boolean := False;
      Hops     : Natural := 0;
      Length   : Natural;
      Pointer  : Natural;
   begin
      loop
         if Position > Packet'Last then
            raise Malformed_Response with "DNS name exceeds packet";
         end if;
         Length := Natural (Packet (Position));
         if Length = 0 then
            if not Jumped then
               Next := Position + 1;
            end if;
            return Result;
         elsif Length >= 16#C0# then
            if Position + 1 > Packet'Last then
               raise Malformed_Response with
                 "truncated DNS compression pointer";
            end if;
            Pointer := (Length mod 16#40#) * 256
              + Natural (Packet (Position + 1));
            if Pointer > Packet'Last then
               raise Malformed_Response with
                 "DNS compression pointer outside packet";
            end if;
            if not Jumped then
               Next := Position + 2;
               Jumped := True;
            end if;
            Position := Pointer;
            Hops := Hops + 1;
            if Hops > Packet'Length then
               raise Malformed_Response with "DNS compression loop";
            end if;
         elsif Length >= 16#40# then
            raise Malformed_Response with "invalid DNS label length";
         else
            if Position + Length > Packet'Last then
               raise Malformed_Response with "DNS label exceeds packet";
            end if;
            if Result.Length /= 0 then
               if Result.Length = Max_Name_Length then
                  raise Malformed_Response with "decoded DNS name too long";
               end if;
               Result.Length := Result.Length + 1;
               Result.Data (Result.Length) := '.';
            end if;
            if Result.Length + Length > Max_Name_Length then
               raise Malformed_Response with "decoded DNS name too long";
            end if;
            for Offset in 1 .. Length loop
               Result.Length := Result.Length + 1;
               Result.Data (Result.Length) :=
                 Ada.Characters.Handling.To_Lower
                   (Character'Val (Packet (Position + Offset)));
            end loop;
            Position := Position + Length + 1;
            if not Jumped then
               Next := Position;
            end if;
         end if;
      end loop;
   end Decode_Name;

   function Parse_Response
     (Packet        : Byte_Array;
      Expected_ID   : Natural;
      Expected_Name : Name_Buffer;
      Expected_Kind : Natural) return Parse_Result
   is
      Result      : Parse_Result;
      Position    : Natural := 12;
      Flags       : Natural;
      Question_Count : Natural;
      Answer_Count   : Natural;
      Authority_Count : Natural;
      Additional_Count : Natural;
      Records     : Parsed_Record_Array (1 .. Max_Records);
      Record_Count : Natural := 0;
      Question_Name : Name_Buffer;
      Next        : Natural;
      Owner       : Name_Buffer;
      Kind        : Natural;
      Class       : Natural;
      TTL         : Natural;
      Data_Length : Natural;
      Data_Start  : Natural;
      Total_Records : Natural;
      Current     : Name_Buffer := Expected_Name;
      Minimum_TTL : Natural := Natural'Last;
      Advanced    : Boolean;
   begin
      if Packet'Length < 12 or else Packet'First /= 0 then
         raise Malformed_Response with "short DNS response";
      elsif U16_At (Packet, 0) /= Expected_ID then
         raise Malformed_Response with "unexpected DNS transaction ID";
      end if;
      Flags := U16_At (Packet, 2);
      if Flags < 16#8000# or else (Flags / 16#0800#) mod 16 /= 0 then
         raise Malformed_Response with "packet is not a standard DNS response";
      elsif (Flags / 16#0200#) mod 2 /= 0 then
         Result.Outcome := Truncated;
         return Result;
      end if;
      Question_Count := U16_At (Packet, 4);
      Answer_Count := U16_At (Packet, 6);
      Authority_Count := U16_At (Packet, 8);
      Additional_Count := U16_At (Packet, 10);
      if Question_Count /= 1 then
         raise Malformed_Response with "unexpected DNS question count";
      end if;
      Question_Name := Decode_Name (Packet, Position, Next);
      Position := Next;
      if Position + 3 > Packet'Last
        or else not Same_Name (Question_Name, Expected_Name)
        or else U16_At (Packet, Position) /= Expected_Kind
        or else U16_At (Packet, Position + 2) /= Class_IN
      then
         raise Malformed_Response with "DNS question does not match request";
      end if;
      Position := Position + 4;

      case Flags mod 16 is
         when 0 => null;
         when 3 =>
            Result.Outcome := Not_Found;
         when others =>
            Result.Outcome := Server_Failure;
      end case;

      if Answer_Count > Max_Records
        or else Authority_Count > Max_Records
        or else Additional_Count > Max_Records
        or else Answer_Count + Authority_Count + Additional_Count
          > 3 * Max_Records
      then
         raise Malformed_Response with "DNS response has too many records";
      end if;
      Total_Records := Answer_Count + Authority_Count + Additional_Count;
      for Record_Index in 1 .. Total_Records loop
         Owner := Decode_Name (Packet, Position, Next);
         Position := Next;
         if Position + 9 > Packet'Last then
            raise Malformed_Response with "truncated DNS resource record";
         end if;
         Kind := U16_At (Packet, Position);
         Class := U16_At (Packet, Position + 2);
         TTL := U32_At (Packet, Position + 4);
         Data_Length := U16_At (Packet, Position + 8);
         Data_Start := Position + 10;
         if Data_Length > Packet'Length
           or else Data_Start > Packet'Last + 1
           or else Data_Start + Data_Length > Packet'Last + 1
         then
            raise Malformed_Response with "DNS record data exceeds packet";
         end if;

         if Record_Index <= Answer_Count and then Class = Class_IN then
            if Kind = Type_A and then Data_Length = 4 then
               if Record_Count < Max_Records then
                  Record_Count := Record_Count + 1;
                  Records (Record_Count).Owner := Owner;
                  Records (Record_Count).Kind := Kind;
                  Records (Record_Count).TTL := TTL;
                  Records (Record_Count).Address.Family := Sockets.IPv4;
                  for Index in 1 .. 4 loop
                     Records (Record_Count).Address.Bytes (Index) :=
                       Packet (Data_Start + Index - 1);
                  end loop;
               end if;
            elsif Kind = Type_AAAA and then Data_Length = 16 then
               if Record_Count < Max_Records then
                  Record_Count := Record_Count + 1;
                  Records (Record_Count).Owner := Owner;
                  Records (Record_Count).Kind := Kind;
                  Records (Record_Count).TTL := TTL;
                  Records (Record_Count).Address.Family :=
                    Sockets.IPv6;
                  for Index in 1 .. 16 loop
                     Records (Record_Count).Address.Bytes (Index) :=
                       Packet (Data_Start + Index - 1);
                  end loop;
               end if;
            elsif Kind = Type_CNAME then
               if Record_Count < Max_Records then
                  declare
                     Ignored : Natural;
                     Target : constant Name_Buffer :=
                       Decode_Name (Packet, Data_Start, Ignored);
                  begin
                     if Ignored > Data_Start + Data_Length then
                        raise Malformed_Response with
                          "CNAME data exceeds resource record";
                     end if;
                     Record_Count := Record_Count + 1;
                     Records (Record_Count).Owner := Owner;
                     Records (Record_Count).Kind := Kind;
                     Records (Record_Count).TTL := TTL;
                     Records (Record_Count).Target := Target;
                  end;
               end if;
            end if;
         elsif Record_Index > Answer_Count
           and then Record_Index <= Answer_Count + Authority_Count
           and then Kind = Type_SOA
           and then Class = Class_IN
         then
            --  RFC 2308 negative caching uses the lesser of the SOA RR TTL
            --  and its MINIMUM field. Decode the two leading domain names,
            --  then read the final five 32-bit fields with strict bounds.
            declare
               SOA_Position : Natural := Data_Start;
               Ignore_Name  : Name_Buffer;
               SOA_Next     : Natural;
            begin
               Ignore_Name := Decode_Name (Packet, SOA_Position, SOA_Next);
               SOA_Position := SOA_Next;
               Ignore_Name := Decode_Name (Packet, SOA_Position, SOA_Next);
               SOA_Position := SOA_Next;
               pragma Unreferenced (Ignore_Name);
               if SOA_Position + 20 <= Data_Start + Data_Length then
                  Result.Negative_TTL := Natural'Min
                    (TTL, U32_At (Packet, SOA_Position + 16));
               end if;
            end;
         end if;
         Position := Data_Start + Data_Length;
      end loop;

      if Result.Outcome in Not_Found | Server_Failure then
         return Result;
      end if;

      --  Follow only owner-matching CNAMEs and cap the walk independently of
      --  packet compression hops. This rejects cyclic alias graphs without
      --  allowing unrelated additional records to influence the result.
      for Hop in 0 .. 15 loop
         Advanced := False;
         for Index in 1 .. Record_Count loop
            if Records (Index).Kind = Expected_Kind
              and then Same_Name (Records (Index).Owner, Current)
            then
               if Result.Address_Count < Max_Addresses then
                  Result.Address_Count := Result.Address_Count + 1;
                  Result.Addresses (Result.Address_Count) :=
                    Records (Index).Address;
                  Minimum_TTL := Natural'Min
                    (Minimum_TTL, Records (Index).TTL);
               end if;
            end if;
         end loop;
         if Result.Address_Count > 0 then
            Result.Outcome := Answer;
            Result.Canonical := Current;
            Result.TTL :=
              (if Minimum_TTL = Natural'Last then 0 else Minimum_TTL);
            return Result;
         end if;
         for Index in 1 .. Record_Count loop
            if Records (Index).Kind = Type_CNAME
              and then Same_Name (Records (Index).Owner, Current)
            then
               Current := Records (Index).Target;
               Minimum_TTL := Natural'Min
                 (Minimum_TTL, Records (Index).TTL);
               Advanced := True;
               exit;
            end if;
         end loop;
         exit when not Advanced;
         if Hop = 15 then
            raise Malformed_Response with "DNS CNAME loop or chain too deep";
         end if;
      end loop;
      Result.Canonical := Current;
      Result.TTL := (if Minimum_TTL = Natural'Last then 0 else Minimum_TTL);
      Result.Outcome := No_Data;
      return Result;
   end Parse_Response;

   procedure Validate_Response_For_Testing
     (Packet        : Streams.Stream_Element_Array;
      Expected_ID   : Natural;
      Expected_Name : String;
      For_IPv6      : Boolean := False)
   is
      Parsed : Parse_Result;
      pragma Unreferenced (Parsed);
   begin
      if Packet'Length = 0 then
         raise Malformed_Response with "empty DNS response";
      end if;
      declare
         Bytes : Byte_Array (0 .. Packet'Length - 1);
      begin
         for Index in Bytes'Range loop
            Bytes (Index) := Byte
              (Packet
                 (Packet'First
                  + Streams.Stream_Element_Offset (Index)));
         end loop;
         Parsed := Parse_Response
           (Bytes, Expected_ID, To_Name (Expected_Name),
            (if For_IPv6 then Type_AAAA else Type_A));
      end;
   end Validate_Response_For_Testing;

   function To_Public (Value : Raw_Address) return Sockets.IP_Address is
   begin
      if Value.Family = Sockets.IPv4 then
         return
           (Family => Sockets.IPv4,
            V4 =>
              (1 => Sockets.Octet (Value.Bytes (1)),
               2 => Sockets.Octet (Value.Bytes (2)),
               3 => Sockets.Octet (Value.Bytes (3)),
               4 => Sockets.Octet (Value.Bytes (4))));
      else
         declare
            Result : Sockets.IP_Address (Sockets.IPv6);
         begin
            for Index in 1 .. 16 loop
               Result.V6 (Index) := Sockets.Octet (Value.Bytes (Index));
            end loop;
            return Result;
         end;
      end if;
   end To_Public;

   function To_Public
     (Values : Raw_Address_Array; Count : Natural) return Address_Array
   is
      Result : Address_Array (1 .. Count);
   begin
      for Index in Result'Range loop
         Result (Index) := To_Public (Values (Values'First + Index - 1));
      end loop;
      return Result;
   end To_Public;

   function Raw (Value : Sockets.IP_Address) return Raw_Address is
      Result : Raw_Address;
   begin
      Result.Family := Value.Family;
      if Value.Family = Sockets.IPv4 then
         for Index in 1 .. 4 loop
            Result.Bytes (Index) := Byte (Value.V4 (Index));
         end loop;
      else
         for Index in 1 .. 16 loop
            Result.Bytes (Index) := Byte (Value.V6 (Index));
         end loop;
      end if;
      return Result;
   end Raw;

   function Remaining
     (Deadline : Ada.Real_Time.Time; Infinite : Boolean) return Duration
   is
   begin
      if Infinite then
         return Flyology.IO.Infinite;
      elsif Ada.Real_Time.Clock >= Deadline then
         return 0.0;
      else
         return Ada.Real_Time.To_Duration (Deadline - Ada.Real_Time.Clock);
      end if;
   end Remaining;

   function Cache_Key
     (Name : Name_Buffer; Kind : Natural; Servers : Name_Server_Array)
      return String
   is
      Result : String (1 .. Max_Cache_Key_Length) := (others => ' ');
      Length : Natural := 0;
      procedure Append (Value : String);
      procedure Append (Value : String) is
      begin
         if Length + Value'Length > Result'Length then
            raise Resolution_Failed with "DNS cache key too long";
         end if;
         Result (Length + 1 .. Length + Value'Length) := Value;
         Length := Length + Value'Length;
      end Append;
   begin
      Append (Image (Name));
      Append ("/" & Natural'Image (Kind));
      --  Server order is part of split-DNS policy: an NXDOMAIN or answer from
      --  the first endpoint prevents consulting later endpoints. Preserve the
      --  caller's order rather than sharing entries across reversed lists.
      for Server of Servers loop
         Append ("@" & Sockets.Image (Server));
      end loop;
      return Result (1 .. Length);
   end Cache_Key;

   procedure Read_Config
     (Config : out Resolver_Config; Path : String) is
      File : Flyology.IO.Files.File_Descriptor :=
        Flyology.IO.Files.Invalid_File;
      Data : Streams.Stream_Element_Array (1 .. Max_Config_Length + 1);
      Last : Streams.Stream_Element_Offset;

      procedure Add_Server (Text : String);
      procedure Add_Search (Text : String);
      procedure Parse_Options (Text : String);
      procedure Parse_Line (Line : String);

      function Trim_Config_Line (Line : String) return String is
         First : Positive := Line'First;
         Last  : Natural := Line'Last;
      begin
         while First <= Line'Last
           and then Line (First) in ' ' | ASCII.HT | ASCII.CR
         loop
            First := First + 1;
         end loop;
         if First > Line'Last then
            return "";
         end if;
         while Last >= First
           and then Line (Last) in ' ' | ASCII.HT | ASCII.CR
         loop
            Last := Last - 1;
         end loop;
         return Line (First .. Last);
      end Trim_Config_Line;

      procedure Add_Server (Text : String) is
         Address_First : Positive := Text'First;
         Address_Last  : Natural := Text'Last;
         Port_First    : Natural := 0;
         Port          : Sockets.Port := DNS_Port;
      begin
         --  Bracketed IPv6 and IPv4 address:port are accepted as a Flyology
         --  extension so deterministic tests and isolated deployments need
         --  not bind the privileged DNS port.
         if Text (Text'First) = '[' then
            for Index in Text'First + 1 .. Text'Last loop
               if Text (Index) = ']' then
                  Address_First := Text'First + 1;
                  Address_Last := Index - 1;
                  if Index < Text'Last and then Text (Index + 1) = ':' then
                     Port_First := Index + 2;
                  end if;
                  exit;
               end if;
            end loop;
         elsif Ada.Strings.Fixed.Count (Text, ":") = 1
           and then Ada.Strings.Fixed.Count (Text, ".") > 0
         then
            for Index in reverse Text'Range loop
               if Text (Index) = ':' then
                  Address_Last := Index - 1;
                  Port_First := Index + 1;
                  exit;
               end if;
            end loop;
         end if;
         if Port_First /= 0 then
            Port := Sockets.Port'Value (Text (Port_First .. Text'Last));
         end if;
         declare
            Address : constant Sockets.IP_Address :=
              Sockets.Parse_IP_Address (Text (Address_First .. Address_Last));
         begin
            if Config.Server_Count < Max_Name_Servers then
               Config.Server_Count := Config.Server_Count + 1;
               Config.Servers (Config.Server_Count) :=
                 Sockets.Network_Endpoint (Address, Port);
            end if;
         end;
      exception
         when Sockets.Socket_Error | Constraint_Error => null;
      end Add_Server;

      procedure Add_Search (Text : String) is
      begin
         if Config.Search_Count < Max_Search_Domains then
            Config.Search_Count := Config.Search_Count + 1;
            Config.Search (Config.Search_Count) := To_Name (Text);
         end if;
      exception
         when Resolution_Failed => null;
      end Add_Search;

      procedure Parse_Options (Text : String) is
         Position : Positive := Text'First;
         Stop     : Natural;
      begin
         while Position <= Text'Last loop
            while Position <= Text'Last
              and then Text (Position) in ' ' | ASCII.HT
            loop
               Position := Position + 1;
            end loop;
            exit when Position > Text'Last;
            Stop := Position;
            while Stop <= Text'Last
              and then Text (Stop) not in ' ' | ASCII.HT
            loop
               Stop := Stop + 1;
            end loop;
            declare
               Token : constant String := Lower (Text (Position .. Stop - 1));
            begin
               if Token = "rotate" then
                  Config.Rotate := True;
               elsif Token'Length > 6
                 and then Token (Token'First .. Token'First + 5) = "ndots:"
               then
                  Config.NDots := Natural'Min
                    (15,
                     Natural'Value (Token (Token'First + 6 .. Token'Last)));
               elsif Token'Length > 9
                 and then Token (Token'First .. Token'First + 8) = "attempts:"
               then
                  Config.Attempts := Positive'Min
                    (5,
                     Positive'Value (Token (Token'First + 9 .. Token'Last)));
               elsif Token'Length > 8
                 and then Token (Token'First .. Token'First + 7) = "timeout:"
               then
                  Config.Per_Attempt := Duration'Max
                    (0.1, Duration'Min
                       (30.0, Duration'Value
                          (Token (Token'First + 8 .. Token'Last))));
               end if;
            exception
               when Constraint_Error => null;
            end;
            Position := Stop + 1;
         end loop;
      end Parse_Options;

      procedure Parse_Words (Text : String; Search : Boolean) is
         Position : Positive := Text'First;
         Stop     : Natural;
      begin
         while Position <= Text'Last loop
            while Position <= Text'Last
              and then Text (Position) in ' ' | ASCII.HT
            loop
               Position := Position + 1;
            end loop;
            exit when Position > Text'Last or else Text (Position) = '#';
            Stop := Position;
            while Stop <= Text'Last
              and then Text (Stop) not in ' ' | ASCII.HT | '#'
            loop
               Stop := Stop + 1;
            end loop;
            if Search then
               Add_Search (Text (Position .. Stop - 1));
            else
               Add_Server (Text (Position .. Stop - 1));
            end if;
            Position := Stop + 1;
         end loop;
      end Parse_Words;

      procedure Parse_Line (Line : String) is
         Trimmed : constant String := Trim_Config_Line (Line);
         Separator : Natural := 0;
      begin
         if Trimmed'Length = 0 or else Trimmed (Trimmed'First) = '#' then
            return;
         end if;
         for Index in Trimmed'Range loop
            if Trimmed (Index) in ' ' | ASCII.HT then
               Separator := Index;
               exit;
            end if;
         end loop;
         if Separator = 0 then
            return;
         end if;
         declare
            Directive : constant String := Lower
              (Trimmed (Trimmed'First .. Separator - 1));
            Rest : constant String :=
              Trimmed (Separator + 1 .. Trimmed'Last);
         begin
            if Directive = "nameserver" then
               Parse_Words (Rest, Search => False);
            elsif Directive = "search" then
               Config.Search_Count := 0;
               Parse_Words (Rest, Search => True);
            elsif Directive = "domain" and then Config.Search_Count = 0 then
               Parse_Words (Rest, Search => True);
            elsif Directive = "options" then
               Parse_Options (Rest);
            end if;
         end;
      end Parse_Line;
   begin
      Config.Server_Count := 0;
      Config.Search_Count := 0;
      Config.NDots := 1;
      Config.Attempts := 2;
      Config.Per_Attempt := 2.0;
      Config.Rotate := False;
      File := Flyology.IO.Files.Open (Path);
      Flyology.IO.Files.Read_At (File, 0, Data, Last);
      Flyology.IO.Files.Close (File);
      if Last = Data'Last then
         raise Resolution_Failed with "resolver configuration is too large";
      end if;
      if Last >= Data'First then
         declare
            Line_First : Streams.Stream_Element_Offset := Data'First;
         begin
            for Position in Data'First .. Last + 1 loop
               if Position = Last + 1
                 or else Data (Position) = Character'Pos (ASCII.LF)
               then
                  if Position > Line_First then
                     declare
                        Length : constant Natural :=
                          Natural (Position - Line_First);
                        Line : String (1 .. Length);
                     begin
                        for Index in Line'Range loop
                           Line (Index) := Character'Val
                             (Data
                                (Line_First
                                 + Streams.Stream_Element_Offset (Index - 1)));
                        end loop;
                        Parse_Line (Line);
                     end;
                  end if;
                  Line_First := Position + 1;
               end if;
            end loop;
         end;
      end if;
   exception
      when others =>
         if File /= Flyology.IO.Files.Invalid_File then
            begin
               Flyology.IO.Files.Close (File);
            exception
               when others => null;
            end;
         end if;
         raise;
   end Read_Config;

   function To_Stream
     (Value : Byte_Array) return Streams.Stream_Element_Array
   is
      Result : Streams.Stream_Element_Array
        (1 .. Streams.Stream_Element_Offset (Value'Length));
   begin
      for Index in Value'Range loop
         Result
           (Streams.Stream_Element_Offset (Index - Value'First + 1)) :=
             Streams.Stream_Element (Value (Index));
      end loop;
      return Result;
   end To_Stream;

   function To_Bytes
     (Value : Streams.Stream_Element_Array;
      Last  : Streams.Stream_Element_Offset) return Byte_Array
   is
      Length : constant Natural :=
        (if Last < Value'First then 0 else Natural (Last - Value'First + 1));
   begin
      if Length = 0 then
         return (0 => 0);
      else
         declare
            Result : Byte_Array (0 .. Length - 1);
         begin
            for Index in Result'Range loop
               Result (Index) := Byte
                 (Value
                    (Value'First + Streams.Stream_Element_Offset (Index)));
            end loop;
            return Result;
         end;
      end if;
   end To_Bytes;

   function Query_TCP
     (Server       : Sockets.Endpoint;
      Query        : Byte_Array;
      Expected_ID  : Natural;
      Expected_Name : Name_Buffer;
      Expected_Kind : Natural;
      Deadline     : Ada.Real_Time.Time;
      Infinite     : Boolean;
      Interrupts   : Interrupt_Set) return Parse_Result
   is
      Socket : Sockets.Socket_Type;
      Payload : constant Streams.Stream_Element_Array := To_Stream (Query);
      Prefix  : Streams.Stream_Element_Array (1 .. 2);
      Length  : Natural;
   begin
      Sockets.Create_Socket (Socket, Server.Family, Sockets.Socket_Stream);
      Flyology.IO.Sockets.Connect
        (Socket, Server, Remaining (Deadline, Infinite),
         Interrupts);
      Prefix (1) := Streams.Stream_Element ((Query'Length / 256) mod 256);
      Prefix (2) := Streams.Stream_Element (Query'Length mod 256);
      Flyology.IO.Sockets.Send_All
        (Socket, Prefix, Remaining (Deadline, Infinite),
         Interrupts);
      Flyology.IO.Sockets.Send_All
        (Socket, Payload, Remaining (Deadline, Infinite),
         Interrupts);
      Flyology.IO.Sockets.Receive_Exactly
        (Socket, Prefix, Remaining (Deadline, Infinite),
         Interrupts);
      Length := Natural (Prefix (1)) * 256 + Natural (Prefix (2));
      if Length < 12 or else Length > Max_TCP_Packet_Length then
         raise Malformed_Response with "invalid TCP DNS message length";
      end if;
      declare
         Payload_In : Streams.Stream_Element_Array
           (1 .. Streams.Stream_Element_Offset (Length));
         Result : Parse_Result;
      begin
         Flyology.IO.Sockets.Receive_Exactly
           (Socket, Payload_In, Remaining (Deadline, Infinite),
            Interrupts);
         Result := Parse_Response
           (To_Bytes (Payload_In, Payload_In'Last), Expected_ID,
            Expected_Name, Expected_Kind);
         Sockets.Close_Socket (Socket);
         return Result;
      end;
   exception
      when Flyology.IO.Sockets.Operation_Interrupted =>
         if Sockets.Is_Open (Socket) then
            Sockets.Close_Socket (Socket);
         end if;
         raise Operation_Cancelled;
      when others =>
         if Sockets.Is_Open (Socket) then
            Sockets.Close_Socket (Socket);
         end if;
         raise;
   end Query_TCP;

   function Query_Kind
     (Name          : Name_Buffer;
      Kind          : Natural;
      Name_Servers  : Name_Server_Array;
      Attempts      : Positive;
      Per_Attempt   : Duration;
      Deadline      : Ada.Real_Time.Time;
      Infinite      : Boolean;
      Interrupts    : Interrupt_Set;
      CNAME_Depth   : Natural := 0) return Parse_Result
   is
      type Socket_Array is array (Positive range <>) of Sockets.Socket_Type;
      Key      : constant String := Cache_Key (Name, Kind, Name_Servers);
      Cached   : Raw_Address_Array (1 .. Max_Addresses);
      Cached_Count : Natural;
      Cached_TTL : Natural;
      Found, Negative : Boolean;
      Last_Error_Was_Malformed : Boolean := False;
      Last_Transport_Failed : Boolean := False;
      Last_Server_Failed : Boolean := False;
   begin
      Cache.Lookup
        (Key, Found, Negative, Cached, Cached_Count, Cached_TTL);
      if Found then
         if Negative then
            raise Name_Not_Found with Image (Name);
         end if;
         return
           (Outcome       => Answer,
            Addresses     => Cached,
            Address_Count => Cached_Count,
            Canonical     => Name,
            TTL           => Cached_TTL,
            Negative_TTL  => 30);
      end if;

      if Name_Servers'Length = 0
        or else Name_Servers'Length > Max_Name_Servers
      then
         raise Resolution_Failed with "no usable DNS name servers";
      elsif CNAME_Depth > 15 then
         raise Malformed_Response with "DNS CNAME chain too deep";
      elsif Per_Attempt <= 0.0 then
         raise Resolution_Failed with "DNS retry interval must be positive";
      end if;

      --  Attempts is a round count. Each round visits every configured server
      --  in order, so a silent primary cannot hide a healthy secondary.
      for Attempt in 1 .. Attempts * Name_Servers'Length loop
         exit when not Infinite and then Remaining (Deadline, False) <= 0.0;
         declare
            ID : constant Natural := Next_Transaction_ID;
         begin
            declare
               Query       : constant Byte_Array :=
                 Build_Query (Name, Kind, ID);
               Query_Data  : constant Streams.Stream_Element_Array :=
                 To_Stream (Query);
               Selected_Server : constant Sockets.Endpoint :=
                 Name_Servers
                   (Name_Servers'First
                    + ((Attempt - 1) mod Name_Servers'Length));
               Channels    : Socket_Array (1 .. 1);
               Requests    : Wait_Request_Array
                 (1 .. Interrupts'Length + Channels'Length);
               Request_Count : Natural := 0;
               Socket_Request_First : Positive := 1;
               Attempt_Time : constant Duration :=
                 (if Infinite then Per_Attempt
                  else Duration'Min
                    (Per_Attempt, Remaining (Deadline, False)));
               Attempt_Deadline : constant Ada.Real_Time.Time :=
                 Ada.Real_Time.Clock
                 + Ada.Real_Time.To_Time_Span (Attempt_Time);

               procedure Close_All;
               procedure Add_Request (FD : Descriptor; Condition : Wait_Kind);

               procedure Close_All is
               begin
                  for Channel of Channels loop
                     if Sockets.Is_Open (Channel) then
                        Sockets.Close_Socket (Channel);
                     end if;
                  end loop;
               end Close_All;

               procedure Add_Request
                 (FD : Descriptor; Condition : Wait_Kind)
               is
               begin
                  if FD >= 0 then
                     Request_Count := Request_Count + 1;
                     Requests (Request_Count) := (FD, Condition);
                  end if;
               end Add_Request;
            begin
               --  Interrupt sources share the same kernel wait as resolver
               --  sockets. They are never consumed or closed here.
               for Interrupt of Interrupts loop
                  Add_Request (Interrupt, For_Read);
               end loop;
               Socket_Request_First := Request_Count + 1;

               declare
                  Last : Streams.Stream_Element_Offset;
               begin
                  Sockets.Create_Socket
                    (Channels (1), Selected_Server.Family,
                     Sockets.Socket_Datagram);
                  --  A datagram connect is a local peer filter, not a network
                  --  handshake. The kernel then rejects responses from every
                  --  source except the selected numeric name server.
                  Sockets.Connect_Socket (Channels (1), Selected_Server);
                  Flyology.IO.Sockets.Prepare (Channels (1));
                  Flyology.IO.Sockets.Send
                    (Channels (1), Query_Data, Last,
                     Remaining (Deadline, Infinite),
                     Interrupts);
                  if Last /= Query_Data'Last then
                     raise Resolution_Failed with "partial DNS datagram";
                  end if;
                  Add_Request
                    (Flyology.IO.Sockets.Native_Descriptor (Channels (1)),
                     For_Read);
               end;

               loop
                  --  Discarded datagrams and uncommitted transport errors
                  --  both return here. A hostile peer can keep the socket
                  --  readable forever, so both deadlines are re-checked
                  --  before every wait rather than relying on Wait_Any
                  --  reporting a timeout.
                  exit when Ada.Real_Time.Clock >= Attempt_Deadline
                    or else (not Infinite
                             and then Remaining (Deadline, False) <= 0.0);
#if FLYOLOGY_DNS_TEST_HOOKS then
                  Flyology.DNS_Test_Observations.Record_Receive_Wait
                    (After_Close => not Sockets.Is_Open (Channels (1)));
#end if;
                  declare
                     Wait_For : constant Duration :=
                       (if Infinite
                        then Duration'Max
                          (0.0, Ada.Real_Time.To_Duration
                             (Attempt_Deadline - Ada.Real_Time.Clock))
                        else Duration'Max
                          (0.0, Duration'Min
                             (Remaining (Deadline, False),
                              Ada.Real_Time.To_Duration
                                (Attempt_Deadline - Ada.Real_Time.Clock))));
                     Ready_Index : constant Natural := Wait_Any
                       (Requests (1 .. Request_Count), Wait_For);
                  begin
                     if Ready_Index = 0 then
                        exit;
                     elsif Ready_Index < Socket_Request_First then
                        Close_All;
                        raise Operation_Cancelled;
                     else
                        declare
                           Channel_Index : constant Positive := 1;
                           Data : Streams.Stream_Element_Array
                             (1 .. Max_Packet_Length);
                           Last : Streams.Stream_Element_Offset;
                           Parsed : Parse_Result;
                           Response_Committed : Boolean := False;
                        begin
                           Sockets.Receive_Socket
                             (Channels (Channel_Index), Data, Last);
                           Parsed := Parse_Response
                             (To_Bytes (Data, Last), ID, Name, Kind);
                           --  A validated datagram commits this attempt to its
                           --  result or TCP fallback. Close UDP before either
                           --  path so no later handler can wait on its stale
                           --  descriptor.
                           Response_Committed := True;
                           Close_All;
                           if Parsed.Outcome = Truncated then
                              Parsed := Query_TCP
                                (Selected_Server,
                                 Query, ID, Name, Kind,
                                 Attempt_Deadline, False,
                                 Interrupts);
                           end if;
                           case Parsed.Outcome is
                              when Answer =>
                                 Cache.Store
                                   (Key, False, Parsed.Addresses,
                                    Parsed.Address_Count, Parsed.TTL);
                                 return Parsed;
                              when Not_Found =>
                                 Cache.Store
                                   (Key, True, Parsed.Addresses, 0,
                                    Parsed.Negative_TTL);
                                 raise Name_Not_Found with Image (Name);
                              when No_Data =>
                                 if Parsed.Canonical.Length /= 0
                                   and then not Same_Name
                                     (Parsed.Canonical, Name)
                                 then
                                    declare
                                       Alias_Result : constant Parse_Result :=
                                         Query_Kind
                                           (Parsed.Canonical,
                                            Kind,
                                            Name_Servers,
                                            Attempts,
                                            Per_Attempt,
                                            Deadline,
                                            Infinite,
                                            Interrupts,
                                            CNAME_Depth + 1);
                                       Composed : Parse_Result := Alias_Result;
                                    begin
                                       Composed.TTL := Natural'Min
                                         (Parsed.TTL, Alias_Result.TTL);
                                       Cache.Store
                                         (Key, False, Composed.Addresses,
                                          Composed.Address_Count,
                                          Composed.TTL);
                                       return Composed;
                                    end;
                                 end if;
                                 Cache.Store
                                   (Key, True, Parsed.Addresses, 0,
                                    Parsed.Negative_TTL);
                                 raise Name_Not_Found with Image (Name);
                              when Truncated =>
                                 raise Malformed_Response with
                                   "truncated TCP DNS response";
                              when Server_Failure =>
                                 --  The server answered, so the deadline is
                                 --  still unspent. Record the rejection and
                                 --  let the next server or attempt run.
                                 Last_Server_Failed := True;
                                 exit;
                           end case;
                        exception
                           when Malformed_Response =>
                              --  Validation failures are discarded like
                              --  off-path datagrams; another configured
                              --  server or retry can still supply an answer.
                              Last_Error_Was_Malformed := True;
                              exit when Response_Committed;
                           when Timeout_Error
                              | Device_Error
                              | Sockets.Socket_Error =>
                              --  TCP fallback is still one attempt against
                              --  one server. A silent or broken TCP endpoint
                              --  must not suppress a healthy later server.
                              if Response_Committed then
                                 Last_Transport_Failed := True;
                                 exit;
                              end if;
                        end;
                     end if;
                  end;
               end loop;
               Close_All;
            exception
               when Flyology.IO.Sockets.Operation_Interrupted =>
                  Close_All;
                  raise Operation_Cancelled;
               when Timeout_Error
                  | Device_Error
                  | Sockets.Socket_Error =>
                  Close_All;
                  Last_Transport_Failed := True;
               when others =>
                  Close_All;
                  raise;
            end;
         end;
      end loop;

      if Last_Error_Was_Malformed then
         raise Malformed_Response with "no valid DNS response received";
      elsif Last_Server_Failed then
         raise Name_Server_Failure with Image (Name);
      elsif Last_Transport_Failed then
         raise Timeout_Error with "DNS transport failed";
      end if;
      raise Timeout_Error with "DNS resolution timed out";
   end Query_Kind;

   function Resolve_Core
     (Name          : String;
      Name_Servers  : Name_Server_Array;
      Family        : Family_Preference;
      Timeout       : Duration;
      Attempts      : Positive;
      Per_Attempt   : Duration;
      Started       : Ada.Real_Time.Time;
      Interrupts    : Interrupt_Set) return Address_Array
   is
      Normalized : constant Name_Buffer := To_Name (Name);
      Infinite   : constant Boolean := Timeout < 0.0;
      Deadline   : constant Ada.Real_Time.Time :=
        (if Infinite then Ada.Real_Time.Time_Last
         else Started + Ada.Real_Time.To_Time_Span (Timeout));
      Values     : Raw_Address_Array (1 .. Max_Addresses);
      Count      : Natural := 0;
      Transport_Failed : Boolean := False;
      Malformed_Failed : Boolean := False;
      Server_Failed    : Boolean := False;

      procedure Append (Parsed : Parse_Result);
      procedure Append (Parsed : Parse_Result) is
      begin
         for Index in 1 .. Parsed.Address_Count loop
            exit when Count = Max_Addresses;
            Count := Count + 1;
            Values (Count) := Parsed.Addresses (Index);
         end loop;
      end Append;
   begin
      if Sockets.Is_IP_Address (Image (Normalized), Sockets.IPv4) then
         if Family = IPv6_Only then
            raise Name_Not_Found with Name;
         end if;
         Values (1) := Raw (Sockets.Parse_IP_Address (Image (Normalized)));
         return To_Public (Values, 1);
      elsif Sockets.Is_IP_Address (Image (Normalized), Sockets.IPv6) then
         if Family = IPv4_Only then
            raise Name_Not_Found with Name;
         end if;
         Values (1) := Raw (Sockets.Parse_IP_Address (Image (Normalized)));
         return To_Public (Values, 1);
      elsif Image (Normalized) = "localhost" then
         if Family /= IPv4_Only then
            Count := Count + 1;
            Values (Count) := Raw (Sockets.Loopback_IPv6);
         end if;
         if Family /= IPv6_Only then
            Count := Count + 1;
            Values (Count) := Raw (Sockets.Loopback_IPv4);
         end if;
         return To_Public (Values, Count);
      end if;

      case Family is
         when IPv4_Only =>
            Append (Query_Kind
              (Normalized, Type_A, Name_Servers, Attempts, Per_Attempt,
               Deadline, Infinite, Interrupts));
         when IPv6_Only =>
            Append (Query_Kind
              (Normalized, Type_AAAA, Name_Servers, Attempts, Per_Attempt,
               Deadline, Infinite, Interrupts));
         when Any_Family =>
            declare
               AAAA_Deadline : constant Ada.Real_Time.Time :=
                 (if Infinite then Deadline
                  else Ada.Real_Time.Clock
                    + Ada.Real_Time.To_Time_Span
                      (Duration'Max
                         (0.0, Remaining (Deadline, False) / 2.0)));
            begin
               begin
                  Append (Query_Kind
                    (Normalized, Type_AAAA, Name_Servers, Attempts,
                     Per_Attempt, AAAA_Deadline, Infinite,
                     Interrupts));
               exception
                  when Name_Not_Found => null;
                  when Malformed_Response => Malformed_Failed := True;
                  when Name_Server_Failure => Server_Failed := True;
                  when Timeout_Error
                     | Device_Error
                     | Sockets.Socket_Error =>
                     Transport_Failed := True;
               end;
            end;
            begin
               Append (Query_Kind
                 (Normalized, Type_A, Name_Servers, Attempts, Per_Attempt,
                  Deadline, Infinite, Interrupts));
            exception
               when Name_Not_Found => null;
               when Malformed_Response => Malformed_Failed := True;
               when Name_Server_Failure => Server_Failed := True;
               when Timeout_Error
                  | Device_Error
                  | Sockets.Socket_Error =>
                  Transport_Failed := True;
            end;
      end case;
      if Count = 0 then
         if Malformed_Failed then
            raise Malformed_Response with
              "no usable address after malformed DNS response";
         elsif Server_Failed then
            raise Name_Server_Failure with Name;
         elsif Transport_Failed then
            raise Timeout_Error with "DNS resolution timed out";
         else
            raise Name_Not_Found with Name;
         end if;
      end if;
      return To_Public (Values, Count);
   end Resolve_Core;

   function Resolve_Using
     (Name         : String;
      Name_Servers : Name_Server_Array;
      Family       : Family_Preference := Any_Family;
      Timeout      : Duration := 5.0;
      Attempts     : Positive := 2;
      Retry_Interval : Duration := 1.0;
      Interrupts   : Interrupt_Set := No_Interrupts) return Address_Array
   is
   begin
      return Resolve_Core
        (Name, Name_Servers, Family, Timeout, Attempts, Retry_Interval,
         Ada.Real_Time.Clock, Interrupts);
   end Resolve_Using;

   function Resolve
     (Name        : String;
      Family      : Family_Preference := Any_Family;
      Timeout     : Duration := 5.0;
      Interrupts  : Interrupt_Set := No_Interrupts;
      Configuration_Path : String := "/etc/resolv.conf")
      return Address_Array
   is
      Config : Resolver_Config;
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Absolute : constant Boolean :=
        Name'Length > 0 and then Name (Name'Last) = '.';
      Dots : Natural := 0;

      function Try_Name (Candidate : String) return Address_Array is
      begin
         return Resolve_Core
           (Candidate, Config.Servers (1 .. Config.Server_Count), Family,
            Timeout, Config.Attempts, Config.Per_Attempt, Started,
            Interrupts);
      end Try_Name;
   begin
      --  Numeric and localhost names need neither resolver configuration nor
      --  filesystem access, preserving deterministic startup behavior.
      if Sockets.Is_IP_Address (Name, Sockets.IPv4)
        or else Sockets.Is_IP_Address (Name, Sockets.IPv6)
        or else Lower (Name) in "localhost" | "localhost."
      then
         declare
            Empty : Name_Server_Array (1 .. 0);
         begin
            return Resolve_Core
              (Name, Empty, Family, Timeout, 1, 1.0, Started,
               Interrupts);
         end;
      end if;

      Read_Config (Config, Configuration_Path);
      if Config.Server_Count = 0 then
         raise Resolution_Failed with
           "no numeric name server found in /etc/resolv.conf";
      end if;
      if Config.Rotate and then Config.Server_Count > 1 then
         declare
            Original : constant Name_Server_Array := Config.Servers;
            Offset   : Natural;
         begin
            Server_Rotation.Next (Config.Server_Count, Offset);
            for Index in 1 .. Config.Server_Count loop
               Config.Servers (Index) := Original
                 (1 + ((Index - 1 + Offset) mod Config.Server_Count));
            end loop;
         end;
      end if;
      for Character_Of_Name of Name loop
         if Character_Of_Name = '.' then
            Dots := Dots + 1;
         end if;
      end loop;
      if Absolute or else Dots >= Config.NDots then
         begin
            return Try_Name (Name);
         exception
            --  A negative answer and a server-failure response code are both
            --  answers about this candidate only. Neither may suppress the
            --  remaining search domains of a relative name.
            when Name_Not_Found | Name_Server_Failure =>
               if Absolute then
                  raise;
               end if;
         end;
      end if;
      for Index in 1 .. Config.Search_Count loop
         declare
            Suffix : constant String := Image (Config.Search (Index));
         begin
            --  A valid name and search domain can still exceed the DNS name
            --  limit when combined. Such a candidate is unusable, but it must
            --  not suppress later search domains or the bare-name fallback.
            if Name'Length < Max_Name_Length
              and then Suffix'Length <= Max_Name_Length - Name'Length - 1
            then
               begin
                  return Try_Name (Name & "." & Suffix);
               exception
                  when Name_Not_Found | Name_Server_Failure => null;
               end;
            end if;
         end;
      end loop;
      return Try_Name (Name);
   end Resolve;

   procedure Clear_Cache is
   begin
      Cache.Clear;
   end Clear_Cache;

end Flyology.IO.DNS;
