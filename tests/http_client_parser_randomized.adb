with Ada.Streams;
with Flyology.HTTP.Client.Testing;
with Interfaces;

procedure HTTP_Client_Parser_Randomized is
   package Testing renames Flyology.HTTP.Client.Testing;

   use Ada.Streams;
   use type Interfaces.Unsigned_32;

   CRLF : constant String := Character'Val (13) & Character'Val (10);
   Seed_Response : constant String :=
     "HTTP/1.1 200 OK" & CRLF &
     "X-Repeated: one" & CRLF &
     "X-Repeated: two" & CRLF &
     "Transfer-Encoding: chunked" & CRLF & CRLF &
     "4;note=yes" & CRLF & "test" & CRLF &
     "0" & CRLF & "X-End: done" & CRLF & CRLF;

   State : Interfaces.Unsigned_32 := 16#51A7_C0DE#;

   function Next return Interfaces.Unsigned_32 is
   begin
      State := State * 1_664_525 + 1_013_904_223;
      return State;
   end Next;

   Value : Testing.Fuzz_Bytes;
begin
   for Iteration in 1 .. 10_000 loop
      for Index in Value'Range loop
         Value (Index) := Stream_Element (Next mod 256);
      end loop;
      declare
         Length : Testing.Fuzz_Length :=
           Testing.Fuzz_Length
             (Next mod Interfaces.Unsigned_32 (Testing.Fuzz_Capacity + 1));
      begin
         if Iteration mod 2 = 0 then
            Length := Seed_Response'Length;
            for Offset in 0 .. Seed_Response'Length - 1 loop
               Value
                 (Value'First + Stream_Element_Offset (Offset)) :=
                   Stream_Element
                     (Character'Pos
                        (Seed_Response (Seed_Response'First + Offset)));
            end loop;
            for Mutation in 1 .. Natural (Next mod 8) + 1 loop
               declare
                  Index : constant Stream_Element_Offset :=
                    Value'First + Stream_Element_Offset
                      (Next mod Interfaces.Unsigned_32 (Length));
               begin
                  Value (Index) := Stream_Element (Next mod 256);
               end;
            end loop;
         end if;
         Testing.Fuzz_Response (Value, Length);
      end;
   end loop;
end HTTP_Client_Parser_Randomized;
