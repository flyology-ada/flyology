package body Flyology.HTTP.Client.Testing is
   use type Ada.Streams.Stream_Element_Offset;

   procedure Validate_Response
     (Value : Ada.Streams.Stream_Element_Array) is
   begin
      Validate_Response_Bytes_For_Testing (Value);
   end Validate_Response;

   procedure Fuzz_Response (Value : Fuzz_Bytes; Length : Fuzz_Length) is
   begin
      Validate_Response
        (Value
           (Value'First ..
              Value'First + Ada.Streams.Stream_Element_Offset (Length) - 1));
   exception
      when Protocol_Error | Response_Too_Large =>
         null;
   end Fuzz_Response;

end Flyology.HTTP.Client.Testing;
