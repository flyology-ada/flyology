with Ada.Streams;
with Flyology.HTTP.Client.Testing;
with HTTP_Client_RFC_Seeds;
with Interfaces;

procedure HTTP_Client_Parser_Randomized is
   package Testing renames Flyology.HTTP.Client.Testing;

   use Ada.Streams;
   use type Interfaces.Unsigned_32;

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
            declare
               Seed_Index : constant HTTP_Client_RFC_Seeds.Seed_Index :=
                 HTTP_Client_RFC_Seeds.Seed_Index
                   (((Iteration / 2) - 1)
                      mod HTTP_Client_RFC_Seeds.Seed_Index'Last + 1);
               Seed : constant String :=
                 HTTP_Client_RFC_Seeds.Payload (Seed_Index);
            begin
               Length := Seed'Length;
               for Offset in 0 .. Seed'Length - 1 loop
                  Value
                    (Value'First + Stream_Element_Offset (Offset)) :=
                      Stream_Element
                        (Character'Pos (Seed (Seed'First + Offset)));
               end loop;
               for Mutation in 1 .. Natural (Next mod 9) loop
                  declare
                     Index : constant Stream_Element_Offset :=
                       Value'First + Stream_Element_Offset
                         (Next mod Interfaces.Unsigned_32 (Length));
                  begin
                     Value (Index) := Stream_Element (Next mod 256);
                  end;
               end loop;
            end;
         end if;
         Testing.Fuzz_Response (Value, Length);
      end;
   end loop;
end HTTP_Client_Parser_Randomized;
