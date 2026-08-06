with Ada.Streams;

--  Exposes stateless HTTP client parser entry points for deterministic tests
--  and coverage-guided fuzzing, not application use.
package Flyology.HTTP.Client.Testing is

   --  Return the exact Host field value used by the production HTTP/1.1
   --  serializer. This exposes no request or transport state.
   --  @param Value Origin whose authority is serialized
   --  @return Host field value without the field name
   function Serialized_Host (Value : Origin) return String;

   --  Fixed fuzz-input capacity accepted by GNATfuzz's automatic marshaller.
   Fuzz_Capacity : constant Positive := 1_000;
   subtype Fuzz_Length is Natural range 0 .. Fuzz_Capacity;
   subtype Fuzz_Bytes is Ada.Streams.Stream_Element_Array
     (1 .. Ada.Streams.Stream_Element_Offset (Fuzz_Capacity));

   --  Parse one bounded response byte sequence through the production status,
   --  field, length, transfer-coding, chunk, and trailer validators. Normal
   --  malformed inputs raise Protocol_Error or Response_Too_Large.
   --  @param Value Complete response bytes, with EOF delimiting an otherwise
   --     close-delimited body
   procedure Validate_Response
     (Value : Ada.Streams.Stream_Element_Array);

   --  Fuzzing oracle around Validate_Response. Documented syntax and size
   --  rejections are consumed; assertion failures, runtime checks, and all
   --  other exceptions remain visible to the fuzzing engine as crashes.
   --  @param Value Fixed-capacity generated input
   --  @param Length Prefix length to parse
   procedure Fuzz_Response (Value : Fuzz_Bytes; Length : Fuzz_Length);

end Flyology.HTTP.Client.Testing;
