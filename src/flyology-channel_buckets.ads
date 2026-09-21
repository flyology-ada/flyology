with System;
with System.Storage_Elements;

--  Internal subscription hash shared by both channel implementations.

private package Flyology.Channel_Buckets
  with Preelaborate
is
   use type System.Storage_Elements.Integer_Address;

   Bucket_Count : constant := 32;
   subtype Bucket_Index is Positive range 1 .. Bucket_Count;

   --  Supported targets have 64-bit addresses. Multiplication mixes even a
   --  power-of-two allocation stride into the high bits used for indexing.
   Multiplier : constant System.Storage_Elements.Integer_Address := 16#9E37_79B9_7F4A_7C15#;
   Divisor    : constant System.Storage_Elements.Integer_Address := 2**(System.Address'Size - 5);

   function Bucket (Address : System.Address; Alignment : Positive) return Bucket_Index
   is (Bucket_Index
         (((System.Storage_Elements.To_Integer (Address)
            / System.Storage_Elements.Integer_Address (Alignment))
           * Multiplier)
          / Divisor
          + 1));
end Flyology.Channel_Buckets;
