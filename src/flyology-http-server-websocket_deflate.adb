with Ada.Unchecked_Deallocation;
with Interfaces;

package body Flyology.HTTP.Server.WebSocket_Deflate is

   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.Unsigned_32;

   Max_Code_Bits : constant := 15;
   Max_Symbols   : constant := 288;
   Max_Nodes     : constant := 2 * Max_Symbols + 1;

   type Byte_Array_Access is access Ada.Streams.Stream_Element_Array;
   procedure Free is new Ada.Unchecked_Deallocation
     (Ada.Streams.Stream_Element_Array, Byte_Array_Access);

   type Code_Length_Array is array (Natural range <>) of Natural;
   type Huffman_Tree_Class is
     (Code_Length_Codes, Literal_Length_Codes, Distance_Codes);
   type Branch_Array is array (Natural range 0 .. 1) of Natural;
   type Huffman_Node is record
      Branch : Branch_Array := (others => 0);
      Symbol : Integer := -1;
   end record;
   type Huffman_Node_Array is array (Positive range 1 .. Max_Nodes) of
     Huffman_Node;
   type Huffman_Tree is record
      Nodes : Huffman_Node_Array;
      Last  : Positive := 1;
   end record;

   procedure Build_Tree
     (Lengths : Code_Length_Array;
      Class   : Huffman_Tree_Class;
      Tree    : out Huffman_Tree)
   is
      Counts : array (Natural range 0 .. Max_Code_Bits) of Natural :=
        (others => 0);
      Next_Code : array (Positive range 1 .. Max_Code_Bits) of Natural :=
        (others => 0);
      Code : Natural := 0;
      Left : Integer := 1;
      Maximum_Length : Natural := 0;
   begin
      Tree.Nodes := (others => (Branch => (others => 0), Symbol => -1));
      Tree.Last := 1;
      for Length of Lengths loop
         if Length > Max_Code_Bits then
            raise Invalid_Data with "DEFLATE code length exceeds 15 bits";
         end if;
         Counts (Length) := Counts (Length) + 1;
         Maximum_Length := Natural'Max (Maximum_Length, Length);
      end loop;
      if Counts (0) = Lengths'Length then
         raise Invalid_Data with "empty DEFLATE Huffman tree";
      end if;
      for Bits in 1 .. Max_Code_Bits loop
         Left := Left * 2 - Integer (Counts (Bits));
         if Left < 0 then
            raise Invalid_Data with "oversubscribed DEFLATE Huffman tree";
         end if;
         Code := (Code + Counts (Bits - 1)) * 2;
         Next_Code (Bits) := Code;
      end loop;
      --  Code-length trees must be complete.  Data trees retain the RFC 1951
      --  exception for one symbol encoded with one bit.
      if Left > 0
        and then
          (Class = Code_Length_Codes or else Maximum_Length /= 1)
      then
         raise Invalid_Data with "incomplete DEFLATE Huffman tree";
      end if;

      for Symbol in Lengths'Range loop
         declare
            Length : constant Natural := Lengths (Symbol);
            Value  : Natural;
            Node   : Positive := 1;
         begin
            if Length > 0 then
               Value := Next_Code (Length);
               Next_Code (Length) := Value + 1;
               for Position in reverse 0 .. Length - 1 loop
                  declare
                     Bit : constant Natural := Natural
                       (Interfaces.Shift_Right
                          (Interfaces.Unsigned_32 (Value), Position) and 1);
                  begin
                     if Tree.Nodes (Node).Branch (Bit) = 0 then
                        if Tree.Last = Max_Nodes then
                           raise Invalid_Data with
                             "DEFLATE Huffman tree is too large";
                        end if;
                        Tree.Last := Tree.Last + 1;
                        Tree.Nodes (Node).Branch (Bit) := Tree.Last;
                     end if;
                     Node := Tree.Nodes (Node).Branch (Bit);
                  end;
               end loop;
               if Tree.Nodes (Node).Symbol /= -1 then
                  raise Invalid_Data with "duplicate DEFLATE Huffman code";
               end if;
               Tree.Nodes (Node).Symbol := Integer (Symbol);
            end if;
         end;
      end loop;
   end Build_Tree;

   procedure Inflate
     (Input          : Flyology.Bytes.Unbounded_Bytes;
      Output         : out Flyology.Bytes.Unbounded_Bytes;
      Maximum        : Natural;
      Reserve_Output : access procedure (Bytes : Natural) := null)
   is
      Trailer : constant array (Positive range 1 .. 4) of
        Ada.Streams.Stream_Element := (0, 0, 255, 255);
      Input_Length : constant Natural := Flyology.Bytes.Length (Input);
      Total_Length : constant Natural := Input_Length + Trailer'Length;
      Position     : Positive := 1;
      Bits         : Interfaces.Unsigned_32 := 0;
      Bit_Count    : Natural := 0;
      Buffer       : Byte_Array_Access := null;
      Output_Length : Natural := 0;
      Capacity     : Natural := 0;

      function Input_Byte (Index : Positive) return Natural is
        (if Index <= Input_Length
         then Natural (Flyology.Bytes.Element (Input, Index))
         else Natural (Trailer (Index - Input_Length)));

      function Read_Bits (Count : Natural) return Natural is
         Mask : Interfaces.Unsigned_32;
         Value : Natural;
      begin
         while Bit_Count < Count loop
            if Position > Total_Length then
               raise Invalid_Data with "truncated DEFLATE stream";
            end if;
            Bits := Bits or Interfaces.Shift_Left
              (Interfaces.Unsigned_32 (Input_Byte (Position)), Bit_Count);
            Bit_Count := Bit_Count + 8;
            Position := Position + 1;
         end loop;
         if Count = 0 then
            return 0;
         end if;
         Mask := Interfaces.Shift_Left (1, Count) - 1;
         Value := Natural (Bits and Mask);
         Bits := Interfaces.Shift_Right (Bits, Count);
         Bit_Count := Bit_Count - Count;
         return Value;
      end Read_Bits;

      procedure Align_Byte is
         Discard : constant Natural := Bit_Count mod 8;
      begin
         if Discard > 0 then
            declare
               Ignored : constant Natural := Read_Bits (Discard);
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         end if;
      end Align_Byte;

      function At_End return Boolean is
        (Position > Total_Length and then Bit_Count = 0);

      function Decode (Tree : Huffman_Tree) return Natural is
         Node : Natural := 1;
      begin
         loop
            Node := Tree.Nodes (Node).Branch (Read_Bits (1));
            if Node = 0 then
               raise Invalid_Data with "invalid DEFLATE Huffman code";
            elsif Tree.Nodes (Node).Symbol >= 0 then
               return Natural (Tree.Nodes (Node).Symbol);
            end if;
         end loop;
      end Decode;

      procedure Ensure_Output (New_Length : Natural) is
      begin
         if New_Length > Maximum then
            raise Output_Too_Large;
         end if;
         if New_Length > Capacity then
            declare
               Doubled : constant Natural :=
                 (if Capacity > Maximum / 2 then Maximum else Capacity * 2);
               New_Capacity : constant Natural := Natural'Min
                 (Maximum,
                  Natural'Max
                    (New_Length, Natural'Max (16 * 1_024, Doubled)));
               Replacement : Byte_Array_Access := null;
            begin
               if Reserve_Output /= null then
                  Reserve_Output.all (New_Capacity);
               end if;
               Replacement := new Ada.Streams.Stream_Element_Array
                 (1 .. Ada.Streams.Stream_Element_Offset (New_Capacity));
               if Output_Length > 0 then
                  Replacement
                    (1 .. Ada.Streams.Stream_Element_Offset (Output_Length)) :=
                      Buffer
                        (1 .. Ada.Streams.Stream_Element_Offset
                          (Output_Length));
               end if;
               Free (Buffer);
               Buffer := Replacement;
               Capacity := New_Capacity;
            exception
               when others =>
                  Free (Replacement);
                  raise;
            end;
         end if;
      end Ensure_Output;

      procedure Append_Byte (Value : Natural) is
         New_Length : constant Natural := Output_Length + 1;
      begin
         Ensure_Output (New_Length);
         Buffer (Ada.Streams.Stream_Element_Offset (New_Length)) :=
           Ada.Streams.Stream_Element (Value);
         Output_Length := New_Length;
      end Append_Byte;

      procedure Append_Match (Distance : Natural; Count : Natural) is
         Current_Length : constant Natural := Output_Length;
         New_Length     : constant Natural := Current_Length + Count;
      begin
         if Distance = 0 or else Distance > Current_Length then
            raise Invalid_Data with
              "DEFLATE distance exceeds output history";
         end if;
         Ensure_Output (New_Length);
         for Index in 0 .. Count - 1 loop
            Buffer
              (Ada.Streams.Stream_Element_Offset
                 (Current_Length + Index + 1)) :=
              Buffer
                (Ada.Streams.Stream_Element_Offset
                   (Current_Length - Distance + Index + 1));
         end loop;
         Output_Length := New_Length;
      end Append_Match;

      procedure Decode_Compressed_Block
        (Literal_Lengths  : Code_Length_Array;
         Distance_Lengths : Code_Length_Array)
      is
         Literal_Tree : Huffman_Tree;
         Distance_Tree : Huffman_Tree;
         --  RFC 1951 permits this form when the block contains no matches.
         No_Distance_Codes : constant Boolean :=
           Distance_Lengths'Length = 1
           and then Distance_Lengths (Distance_Lengths'First) = 0;
         Length_Base : constant array (Natural range 257 .. 285) of Natural :=
           (3, 4, 5, 6, 7, 8, 9, 10,
            11, 13, 15, 17, 19, 23, 27, 31,
            35, 43, 51, 59, 67, 83, 99, 115,
            131, 163, 195, 227, 258);
         Length_Extra : constant array (Natural range 257 .. 285) of Natural :=
           (0, 0, 0, 0, 0, 0, 0, 0,
            1, 1, 1, 1, 2, 2, 2, 2,
            3, 3, 3, 3, 4, 4, 4, 4,
            5, 5, 5, 5, 0);
         Distance_Base : constant array (Natural range 0 .. 29) of Natural :=
           (1, 2, 3, 4, 5, 7, 9, 13,
            17, 25, 33, 49, 65, 97, 129, 193,
            257, 385, 513, 769, 1_025, 1_537, 2_049, 3_073,
            4_097, 6_145, 8_193, 12_289, 16_385, 24_577);
         Distance_Extra : constant array (Natural range 0 .. 29) of Natural :=
           (0, 0, 0, 0, 1, 1, 2, 2,
            3, 3, 4, 4, 5, 5, 6, 6,
            7, 7, 8, 8, 9, 9, 10, 10,
            11, 11, 12, 12, 13, 13);
      begin
         Build_Tree
           (Literal_Lengths, Literal_Length_Codes, Literal_Tree);
         if not No_Distance_Codes then
            Build_Tree (Distance_Lengths, Distance_Codes, Distance_Tree);
         end if;
         loop
            declare
               Symbol : constant Natural := Decode (Literal_Tree);
            begin
               if Symbol <= 255 then
                  Append_Byte (Symbol);
               elsif Symbol = 256 then
                  exit;
               elsif Symbol in 257 .. 285 then
                  declare
                     Count : constant Natural := Length_Base (Symbol)
                       + Read_Bits (Length_Extra (Symbol));
                     Distance_Symbol : Natural;
                     Distance : Natural;
                  begin
                     if No_Distance_Codes then
                        raise Invalid_Data with
                          "DEFLATE length has no distance code";
                     end if;
                     Distance_Symbol := Decode (Distance_Tree);
                     if Distance_Symbol > 29 then
                        raise Invalid_Data with
                          "reserved DEFLATE distance code";
                     end if;
                     Distance := Distance_Base (Distance_Symbol)
                       + Read_Bits (Distance_Extra (Distance_Symbol));
                     Append_Match (Distance, Count);
                  end;
               else
                  raise Invalid_Data with "reserved DEFLATE length code";
               end if;
            end;
         end loop;
      end Decode_Compressed_Block;

      procedure Decode_Fixed_Block is
         Literal_Lengths : Code_Length_Array (0 .. 287);
         Distance_Lengths : constant Code_Length_Array (0 .. 31) :=
           (others => 5);
      begin
         Literal_Lengths (0 .. 143) := (others => 8);
         Literal_Lengths (144 .. 255) := (others => 9);
         Literal_Lengths (256 .. 279) := (others => 7);
         Literal_Lengths (280 .. 287) := (others => 8);
         Decode_Compressed_Block (Literal_Lengths, Distance_Lengths);
      end Decode_Fixed_Block;

      procedure Decode_Dynamic_Block is
         Literal_Count : constant Natural := Read_Bits (5) + 257;
         Distance_Count : constant Natural := Read_Bits (5) + 1;
         Code_Count : constant Natural := Read_Bits (4) + 4;
         Code_Order : constant array (Natural range 0 .. 18) of Natural :=
           (16, 17, 18, 0, 8, 7, 9, 6, 10, 5,
            11, 4, 12, 3, 13, 2, 14, 1, 15);
         Code_Lengths : Code_Length_Array (0 .. 18) := (others => 0);
         All_Lengths : Code_Length_Array
           (0 .. Literal_Count + Distance_Count - 1) := (others => 0);
         Code_Tree : Huffman_Tree;
         Index : Natural := 0;
      begin
         for Position in 0 .. Code_Count - 1 loop
            Code_Lengths (Code_Order (Position)) := Read_Bits (3);
         end loop;
         Build_Tree (Code_Lengths, Code_Length_Codes, Code_Tree);
         while Index < All_Lengths'Length loop
            declare
               Symbol : constant Natural := Decode (Code_Tree);
               Repeat_Count : Natural;
               Value : Natural;
            begin
               case Symbol is
                  when 0 .. 15 =>
                     All_Lengths (Index) := Symbol;
                     Index := Index + 1;
                  when 16 =>
                     if Index = 0 then
                        raise Invalid_Data with
                          "DEFLATE repeat has no preceding code length";
                     end if;
                     Repeat_Count := Read_Bits (2) + 3;
                     Value := All_Lengths (Index - 1);
                     if Repeat_Count > All_Lengths'Length - Index then
                        raise Invalid_Data with
                          "DEFLATE code-length repeat exceeds table";
                     end if;
                     All_Lengths (Index .. Index + Repeat_Count - 1) :=
                       (others => Value);
                     Index := Index + Repeat_Count;
                  when 17 =>
                     Repeat_Count := Read_Bits (3) + 3;
                     if Repeat_Count > All_Lengths'Length - Index then
                        raise Invalid_Data with
                          "DEFLATE zero repeat exceeds table";
                     end if;
                     Index := Index + Repeat_Count;
                  when 18 =>
                     Repeat_Count := Read_Bits (7) + 11;
                     if Repeat_Count > All_Lengths'Length - Index then
                        raise Invalid_Data with
                          "DEFLATE long zero repeat exceeds table";
                     end if;
                     Index := Index + Repeat_Count;
                  when others =>
                     raise Invalid_Data with
                       "invalid DEFLATE code-length symbol";
               end case;
            end;
         end loop;
         if All_Lengths (256) = 0 then
            raise Invalid_Data with "DEFLATE block has no end code";
         end if;
         declare
            Literal_Lengths : Code_Length_Array (0 .. Literal_Count - 1);
            Distance_Lengths : Code_Length_Array (0 .. Distance_Count - 1);
         begin
            Literal_Lengths := All_Lengths (0 .. Literal_Count - 1);
            Distance_Lengths := All_Lengths
              (Literal_Count .. Literal_Count + Distance_Count - 1);
            Decode_Compressed_Block (Literal_Lengths, Distance_Lengths);
         end;
      end Decode_Dynamic_Block;

      Final : Boolean;
      Block_Type : Natural;
   begin
      Flyology.Bytes.Clear (Output);
      loop
         Final := Read_Bits (1) = 1;
         Block_Type := Read_Bits (2);
         case Block_Type is
            when 0 =>
               Align_Byte;
               declare
                  Count : constant Natural := Read_Bits (16);
                  Complement : constant Natural := Read_Bits (16);
               begin
                  if Complement /= 16#FFFF# - Count then
                     raise Invalid_Data with
                       "invalid DEFLATE stored-block length";
                  end if;
                  for Index in 1 .. Count loop
                     Append_Byte (Read_Bits (8));
                  end loop;
               end;
            when 1 =>
               Decode_Fixed_Block;
            when 2 =>
               Decode_Dynamic_Block;
            when others =>
               raise Invalid_Data with "reserved DEFLATE block type";
         end case;
         exit when Final or else At_End;
      end loop;
      if not Final and then not At_End then
         raise Invalid_Data with "incomplete DEFLATE message";
      end if;
      if Output_Length > 0 then
         Flyology.Bytes.Append
           (Output,
            Buffer (1 .. Ada.Streams.Stream_Element_Offset (Output_Length)));
      end if;
      Free (Buffer);
   exception
      when others =>
         Free (Buffer);
         Flyology.Bytes.Clear (Output);
         raise;
   end Inflate;

   generic
      with function Length return Natural;
      with function Element (Index : Positive)
        return Ada.Streams.Stream_Element;
   procedure Encode_Fixed
     (Output : out Flyology.Bytes.Unbounded_Bytes);

   procedure Encode_Fixed
     (Output : out Flyology.Bytes.Unbounded_Bytes)
   is
      Window_Size : constant := 32 * 1_024;
      Match_Limit : constant := 258;
      Bucket_Count : constant Positive := Natural'Max
        (64, Natural'Min (32 * 1_024, Length * 2));

      type Position_Array is array (Natural range <>) of Natural;
      Head : Position_Array (0 .. Bucket_Count - 1) := (others => 0);

      Pending   : Interfaces.Unsigned_32 := 0;
      Bit_Count : Natural := 0;

      Length_Base : constant array (Natural range 257 .. 285) of Natural :=
        (3, 4, 5, 6, 7, 8, 9, 10,
         11, 13, 15, 17, 19, 23, 27, 31,
         35, 43, 51, 59, 67, 83, 99, 115,
         131, 163, 195, 227, 258);
      Length_Extra : constant array (Natural range 257 .. 285) of Natural :=
        (0, 0, 0, 0, 0, 0, 0, 0,
         1, 1, 1, 1, 2, 2, 2, 2,
         3, 3, 3, 3, 4, 4, 4, 4,
         5, 5, 5, 5, 0);
      Distance_Base : constant array (Natural range 0 .. 29) of Natural :=
        (1, 2, 3, 4, 5, 7, 9, 13,
         17, 25, 33, 49, 65, 97, 129, 193,
         257, 385, 513, 769, 1_025, 1_537, 2_049, 3_073,
         4_097, 6_145, 8_193, 12_289, 16_385, 24_577);
      Distance_Extra : constant array (Natural range 0 .. 29) of Natural :=
        (0, 0, 0, 0, 1, 1, 2, 2,
         3, 3, 4, 4, 5, 5, 6, 6,
         7, 7, 8, 8, 9, 9, 10, 10,
         11, 11, 12, 12, 13, 13);

      procedure Write_Bits (Value : Natural; Count : Natural) is
      begin
         Pending := Pending or Interfaces.Shift_Left
           (Interfaces.Unsigned_32 (Value), Bit_Count);
         Bit_Count := Bit_Count + Count;
         while Bit_Count >= 8 loop
            Flyology.Bytes.Append
              (Output,
               Ada.Streams.Stream_Element (Pending and 16#FF#));
            Pending := Interfaces.Shift_Right (Pending, 8);
            Bit_Count := Bit_Count - 8;
         end loop;
      end Write_Bits;

      function Reverse_Bits (Value : Natural; Count : Natural)
        return Natural
      is
         Source : Natural := Value;
         Result : Natural := 0;
      begin
         for Index in 1 .. Count loop
            Result := Result * 2 + Source mod 2;
            Source := Source / 2;
         end loop;
         return Result;
      end Reverse_Bits;

      procedure Write_Huffman
        (Code : Natural; Code_Length : Natural) is
      begin
         Write_Bits (Reverse_Bits (Code, Code_Length), Code_Length);
      end Write_Huffman;

      procedure Write_Literal_Length (Symbol : Natural) is
      begin
         case Symbol is
            when 0 .. 143 =>
               Write_Huffman (16#30# + Symbol, 8);
            when 144 .. 255 =>
               Write_Huffman (16#190# + Symbol - 144, 9);
            when 256 .. 279 =>
               Write_Huffman (Symbol - 256, 7);
            when 280 .. 287 =>
               Write_Huffman (16#C0# + Symbol - 280, 8);
            when others =>
               raise Program_Error with "invalid fixed-Huffman symbol";
         end case;
      end Write_Literal_Length;

      procedure Write_Length (Count : Natural) is
      begin
         for Symbol in Length_Base'Range loop
            declare
               Last : constant Natural :=
                 Length_Base (Symbol)
                 + (if Length_Extra (Symbol) = 0 then 0
                    else 2 ** Length_Extra (Symbol) - 1);
            begin
               if Count <= Last then
                  Write_Literal_Length (Symbol);
                  Write_Bits
                    (Count - Length_Base (Symbol), Length_Extra (Symbol));
                  return;
               end if;
            end;
         end loop;
         raise Program_Error with "invalid DEFLATE match length";
      end Write_Length;

      procedure Write_Distance (Distance : Natural) is
      begin
         for Symbol in Distance_Base'Range loop
            declare
               Last : constant Natural :=
                 Distance_Base (Symbol)
                 + (if Distance_Extra (Symbol) = 0 then 0
                    else 2 ** Distance_Extra (Symbol) - 1);
            begin
               if Distance <= Last then
                  Write_Huffman (Symbol, 5);
                  Write_Bits
                    (Distance - Distance_Base (Symbol),
                     Distance_Extra (Symbol));
                  return;
               end if;
            end;
         end loop;
         raise Program_Error with "invalid DEFLATE match distance";
      end Write_Distance;

      function Hash (Position : Positive) return Natural is
        ((Natural (Element (Position)) * 251 * 251
          + Natural (Element (Position + 1)) * 251
          + Natural (Element (Position + 2))) mod Bucket_Count);

      procedure Insert (Position : Positive) is
         Bucket : constant Natural := Hash (Position);
      begin
         Head (Bucket) := Position;
      end Insert;

      procedure Find_Match
        (Position      : Positive;
         Match_Length  : out Natural;
         Match_Distance : out Natural)
      is
         Candidate : constant Natural := Head (Hash (Position));
         Maximum   : constant Natural := Natural'Min
           (Match_Limit, Length - Position + 1);
      begin
         Match_Length := 0;
         Match_Distance := 0;
         if Candidate > 0
           and then Position - Candidate <= Window_Size
         then
            if Element (Candidate) = Element (Position)
              and then Element (Candidate + 1) = Element (Position + 1)
              and then Element (Candidate + 2) = Element (Position + 2)
            then
               declare
                  Count : Natural := 3;
               begin
                  while Count < Maximum
                    and then Element (Candidate + Count) =
                      Element (Position + Count)
                  loop
                     Count := Count + 1;
                  end loop;
                  Match_Length := Count;
                  Match_Distance := Position - Candidate;
               end;
            end if;
         end if;
      end Find_Match;

      Position : Positive := 1;
   begin
      Flyology.Bytes.Clear (Output);
      Flyology.Bytes.Reserve_Capacity
        (Output, Length + Length / 8 + 16);

      --  Non-final fixed-Huffman block. The empty stored block appended below
      --  is the Z_SYNC_FLUSH marker whose last four octets RFC 7692 removes.
      Write_Bits (2, 3);
      while Position <= Length loop
         declare
            Match_Length   : Natural := 0;
            Match_Distance : Natural := 0;
         begin
            if Position + 2 <= Length then
               Find_Match (Position, Match_Length, Match_Distance);
            end if;
            if Match_Length >= 3 then
               Write_Length (Match_Length);
               Write_Distance (Match_Distance);
               for Offset in 0 .. Match_Length - 1 loop
                  exit when Position + Offset + 2 > Length;
                  Insert (Position + Offset);
               end loop;
               Position := Position + Match_Length;
            else
               Write_Literal_Length (Natural (Element (Position)));
               if Position + 2 <= Length then
                  Insert (Position);
               end if;
               Position := Position + 1;
            end if;
         end;
      end loop;
      Write_Literal_Length (256);
      Write_Bits (0, 3);
      if Bit_Count > 0 then
         Flyology.Bytes.Append
           (Output, Ada.Streams.Stream_Element (Pending and 16#FF#));
      end if;
      --  The empty stored-block header and its alignment bits are retained;
      --  LEN and NLEN are the four octets removed from the payload.
   end Encode_Fixed;

   procedure Deflate
     (Input  : Ada.Streams.Stream_Element_Array;
      Output : out Flyology.Bytes.Unbounded_Bytes)
   is
      function Input_Length return Natural is (Input'Length);
      function Input_Element (Index : Positive)
        return Ada.Streams.Stream_Element is
          (Input
             (Input'First + Ada.Streams.Stream_Element_Offset (Index - 1)));
      procedure Encode is new Encode_Fixed (Input_Length, Input_Element);
   begin
      Encode (Output);
   end Deflate;

   procedure Deflate
     (Input  : Flyology.Bytes.Unbounded_Bytes;
      Output : out Flyology.Bytes.Unbounded_Bytes)
   is
      Snapshot : Byte_Array_Access := new Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset
          (Flyology.Bytes.Length (Input)));
      function Input_Length return Natural is (Flyology.Bytes.Length (Input));
      function Input_Element (Index : Positive)
        return Ada.Streams.Stream_Element is
          (Snapshot
             (Ada.Streams.Stream_Element_Offset (Index)));
      procedure Encode is new Encode_Fixed (Input_Length, Input_Element);
   begin
      for Index in 1 .. Flyology.Bytes.Length (Input) loop
         Snapshot (Ada.Streams.Stream_Element_Offset (Index)) :=
           Flyology.Bytes.Element (Input, Index);
      end loop;
      Encode (Output);
      Free (Snapshot);
   exception
      when others =>
         Free (Snapshot);
         raise;
   end Deflate;

end Flyology.HTTP.Server.WebSocket_Deflate;
