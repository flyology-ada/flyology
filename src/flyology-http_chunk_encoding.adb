package body Flyology.HTTP_Chunk_Encoding
  with SPARK_Mode => On
is

   function Encode (Value : Natural) return String is
      subtype Hex_Digit is Character
        with Static_Predicate =>
          Hex_Digit in '0' .. '9' | 'A' .. 'F';
      Hex_Digits : constant array (Positive range 1 .. 16) of Hex_Digit :=
        "0123456789ABCDEF";
      Buffer     : String (1 .. Max_Hex_Digits) := (others => '0');
      Cursor     : Natural := Buffer'Last;
      Rest       : Natural := Value;
   begin
      for Digit_Number in 1 .. Max_Hex_Digits loop
         pragma Loop_Invariant
           (Cursor = Buffer'Last - Digit_Number + 1);
         --  After consuming Digit_Number - 1 digits, Rest cannot exceed the
         --  corresponding quotient of Natural'Last.  Spell out the finite
         --  capacity ladder so proof does not depend on nonlinear powers.
         pragma Loop_Invariant
           (Long_Long_Integer (Rest)
              <= (case Long_Long_Integer (Digit_Number) is
                     when 1  => Long_Long_Integer (Natural'Last),
                     when 2  => Long_Long_Integer (Natural'Last) / 16,
                     when 3  => Long_Long_Integer (Natural'Last) / 256,
                     when 4  => Long_Long_Integer (Natural'Last) / 4_096,
                     when 5  => Long_Long_Integer (Natural'Last) / 65_536,
                     when 6  => Long_Long_Integer (Natural'Last) / 1_048_576,
                     when 7  => Long_Long_Integer (Natural'Last) / 16_777_216,
                     when 8  => Long_Long_Integer (Natural'Last) / 268_435_456,
                     when others => 0));
         pragma Loop_Invariant
           (for all Index in Buffer'Range =>
              Buffer (Index) in '0' .. '9' | 'A' .. 'F');
         Buffer (Cursor) := Hex_Digits (Rest mod 16 + 1);
         Rest := Rest / 16;
         pragma Assert
           (Digit_Number < Max_Hex_Digits or else Rest = 0);
         exit when Rest = 0;
         Cursor := Cursor - 1;
      end loop;
      pragma Assert (Rest = 0);
      return Buffer (Cursor .. Buffer'Last);
   end Encode;

end Flyology.HTTP_Chunk_Encoding;
