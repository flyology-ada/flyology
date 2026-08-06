private package Flyology.HTTP_Chunk_Encoding
  with SPARK_Mode => On
is

   Max_Hex_Digits : constant Positive := (Natural'Size + 3) / 4;

   --  Encode an HTTP chunk size using the uppercase hexadecimal form placed
   --  on the wire.  The result has no leading zeroes except for value zero.
   function Encode (Value : Natural) return String
   with
     Global => null,
     Post   =>
       Encode'Result'Length in 1 .. Max_Hex_Digits
       and then
         (for all Index in Encode'Result'Range =>
            Encode'Result (Index) in '0' .. '9' | 'A' .. 'F');

end Flyology.HTTP_Chunk_Encoding;
