with Ada.Exceptions;
with Ada.Streams;
with Flyology.IO.DNS;
with Flyology.IO.DNS.Testing;

procedure DNS_Parser_Smoke is
   package DNS renames Flyology.IO.DNS;
   package Testing renames Flyology.IO.DNS.Testing;
   package Streams renames Ada.Streams;
   use type Streams.Stream_Element_Offset;

   subtype Packet is Streams.Stream_Element_Array;

   Base : constant Packet (1 .. 43) :=
     [16#12#,
      16#34#,
      16#81#,
      16#80#,
      0,
      1,
      0,
      1,
      0,
      0,
      0,
      0,
      4,
      Character'Pos ('f'),
      Character'Pos ('u'),
      Character'Pos ('z'),
      Character'Pos ('z'),
      4,
      Character'Pos ('t'),
      Character'Pos ('e'),
      Character'Pos ('s'),
      Character'Pos ('t'),
      0,
      0,
      1,
      0,
      1,
      16#C0#,
      12,
      0,
      1,
      0,
      1,
      0,
      0,
      0,
      60,
      0,
      4,
      192,
      0,
      2,
      1];

   procedure Check_Safe (Value : Packet; Context : String := "packet") is
   begin
      Testing.Validate_Response (Value, 16#1234#, "fuzz.test");
   exception
      when DNS.Malformed_Response =>
         null;
      when Error : others =>
         raise Program_Error
           with
             "DNS parser leaked an exception for "
             & Context
             & ": "
             & Ada.Exceptions.Exception_Information (Error);
   end Check_Safe;
begin
   --  The seed packet itself must remain a valid compressed A response.
   Testing.Validate_Response (Base, 16#1234#, "fuzz.test");

   --  Every truncation boundary exercises header, question, owner, fixed RR,
   --  RDLENGTH, and address bounds without permitting Constraint_Error.
   for Last in Base'First .. Base'Last - 1 loop
      Check_Safe (Base (Base'First .. Last), "truncation" & Last'Image);
   end loop;

   declare
      Mutant : Packet (Base'Range);
   begin
      --  A compression pointer aimed at its own first byte must hit the
      --  parser's bounded hop guard rather than looping.
      Mutant := Base;
      Mutant (29) := 27;
      Check_Safe (Mutant, "self pointer");

      --  Oversized record counts and RDLENGTH values exercise addition and
      --  end-position checks before any indexed read.
      Mutant := Base;
      Mutant (7) := 255;
      Mutant (8) := 255;
      Mutant (9) := 255;
      Mutant (10) := 255;
      Mutant (11) := 255;
      Mutant (12) := 255;
      Check_Safe (Mutant, "record counts");
      Mutant := Base;
      Mutant (38) := 255;
      Mutant (39) := 255;
      Check_Safe (Mutant, "RDLENGTH");

      --  A compact deterministic mutation corpus gives every packet byte
      --  label, pointer, count, type, class, TTL, and RDATA boundary values.
      for Index in Base'Range loop
         for Replacement of Packet'[0, 16#3F#, 16#C0#, 16#FF#] loop
            Mutant := Base;
            Mutant (Index) := Replacement;
            Check_Safe (Mutant, "mutation" & Index'Image);
         end loop;
      end loop;
   end;
end DNS_Parser_Smoke;
