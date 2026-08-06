--  Internal, proved capability and admission decisions shared by the
--  production WebSocket DEFLATE negotiator, encoder, and decoder.
private package Flyology.WebSocket_Deflate_Policy
  with SPARK_Mode => On
is

   subtype RFC_1951_Window_Bits is Positive range 8 .. 15;

   Encoder_Window_Bits : constant RFC_1951_Window_Bits := 15;
   Encoder_Window_Bytes : constant Positive := 2 ** Encoder_Window_Bits;

   --  Return the server_max_window_bits value that the fixed-window encoder
   --  can honor, or zero when the offer must be declined.  The returned wire
   --  value and the encoder history size are derived from the same constants.
   function Negotiated_Server_Window_Bits
     (Offered_Bits : Natural) return Natural
   with
     Global => null,
     Post   =>
       Negotiated_Server_Window_Bits'Result =
         (if Offered_Bits = Encoder_Window_Bits
          then Encoder_Window_Bits
          else 0)
       and then
         (if Negotiated_Server_Window_Bits'Result /= 0
          then Negotiated_Server_Window_Bits'Result = Encoder_Window_Bits
            and then Encoder_Window_Bytes = 2 ** Encoder_Window_Bits);

   type Distance_Tree_Disposition is (Decode_Tree, No_Tree);

   --  RFC 1951 represents an absent distance alphabet as exactly one
   --  declared distance code whose code length is zero.  All other declared
   --  shapes require normal Huffman-tree validation and construction.
   function Select_Distance_Tree
     (Declared_Code_Count : Positive;
      First_Code_Length   : Natural) return Distance_Tree_Disposition
   with
     Global => null,
     Post   =>
       (Select_Distance_Tree'Result = No_Tree) =
         (Declared_Code_Count = 1 and then First_Code_Length = 0);

   --  Return whether the distance requirement for this symbol is satisfied.
   --  Every RFC 1951 length symbol requires a distance tree. Literals, the
   --  end-of-block symbol, and reserved symbols have no distance requirement;
   --  their separate validity checks remain outside this classifier. This
   --  does not prove reserved-symbol rejection or general DEFLATE correctness.
   function Distance_Requirement_Is_Satisfied
     (Disposition           : Distance_Tree_Disposition;
      Literal_Length_Symbol : Natural) return Boolean
   with
     Global => null,
     Post   =>
       Distance_Requirement_Is_Satisfied'Result =
         (Disposition = Decode_Tree
          or else Literal_Length_Symbol not in 257 .. 285);

end Flyology.WebSocket_Deflate_Policy;
