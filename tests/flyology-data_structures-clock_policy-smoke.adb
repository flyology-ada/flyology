with Interfaces;
with Interfaces.C;

procedure Flyology.Data_Structures.Clock_Policy.Smoke is
   package C renames Interfaces.C;

   Maximum_Seconds : constant C.long := 18_446_744_073;

   procedure Expect
     (Status : C.int; Seconds : C.long; Nanoseconds : C.long; Expected : Interfaces.Unsigned_64) is
   begin
      pragma Assert (To_Nanoseconds (Status, Seconds, Nanoseconds) = Expected);
   end Expect;
begin
   --  Successful ordinary samples retain their exact nanosecond value.
   Expect (0, 0, 0, 0);
   Expect (0, 1, 0, 1_000_000_000);
   Expect (0, 1, 999_999_999, 1_999_999_999);

   --  Every former C validation branch maps to the all-ones sentinel.
   Expect (1, 0, 0, Clock_Failure);
   Expect (-1, 0, 0, Clock_Failure);
   Expect (0, -1, 0, Clock_Failure);
   Expect (0, 0, -1, Clock_Failure);
   Expect (0, 0, 1_000_000_000, Clock_Failure);
   Expect (0, Maximum_Seconds + 1, 0, Clock_Failure);

   --  The maximum second accepts only the final nanoseconds that fit without
   --  wrapping. Larger values fail instead of becoming small timestamps.
   Expect (0, Maximum_Seconds, 709_551_615, Interfaces.Unsigned_64'Last);
   Expect (0, Maximum_Seconds, 709_551_616, Clock_Failure);
   Expect (0, Maximum_Seconds, 999_999_999, Clock_Failure);
end Flyology.Data_Structures.Clock_Policy.Smoke;
