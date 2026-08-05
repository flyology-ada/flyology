package body Flyology.WebSocket_Deflate_Policy
  with SPARK_Mode => On
is

   function Negotiated_Server_Window_Bits
     (Offered_Bits : Natural) return Natural is
     (if Offered_Bits = Encoder_Window_Bits
      then Encoder_Window_Bits
      else 0);

   function Select_Distance_Tree
     (Declared_Code_Count : Positive;
      First_Code_Length   : Natural) return Distance_Tree_Disposition is
     (if Declared_Code_Count = 1 and then First_Code_Length = 0
      then No_Tree
      else Decode_Tree);

   function Distance_Requirement_Is_Satisfied
     (Disposition           : Distance_Tree_Disposition;
      Literal_Length_Symbol : Natural) return Boolean is
     (Disposition = Decode_Tree
      or else Literal_Length_Symbol not in 257 .. 285);

end Flyology.WebSocket_Deflate_Policy;
