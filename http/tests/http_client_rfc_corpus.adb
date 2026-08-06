with Ada.Assertions;
with Ada.Streams;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Client.Testing;
with HTTP_Client_RFC_Seeds;

procedure HTTP_Client_RFC_Corpus is
   use HTTP_Client_RFC_Seeds;
   use type Ada.Streams.Stream_Element_Offset;

   function Bytes (Value : String) return Ada.Streams.Stream_Element_Array is
      Result : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Value'Length));
   begin
      for Offset in 0 .. Value'Length - 1 loop
         Result (Result'First + Ada.Streams.Stream_Element_Offset (Offset)) :=
           Ada.Streams.Stream_Element
             (Character'Pos (Value (Value'First + Offset)));
      end loop;
      return Result;
   end Bytes;

begin
   for Index in Seed_Index loop
      declare
         Rejected : Boolean := False;
      begin
         begin
            Flyology.HTTP.Client.Testing.Validate_Response
              (Bytes (Payload (Index)));
         exception
            when Flyology.HTTP.Protocol_Error |
                 Flyology.HTTP.Client.Response_Too_Large =>
               Rejected := True;
         end;
         if Expected (Index) = Accept_Input and then Rejected then
            raise Ada.Assertions.Assertion_Error with
              Name (Index) & " should be accepted under " & Reference (Index);
         elsif Expected (Index) = Reject_Input and then not Rejected then
            raise Ada.Assertions.Assertion_Error with
              Name (Index) & " should be rejected under " & Reference (Index);
         end if;
      end;
   end loop;
end HTTP_Client_RFC_Corpus;
