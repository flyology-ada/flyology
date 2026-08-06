procedure Flyology.HTTP.Expect_Policy.Smoke is

   procedure Check
     (Version         : HTTP_Version;
      Field_Count     : Natural;
      Value_Supported : Boolean;
      Expected        : Expectation_Action)
   is
   begin
      pragma Assert
        (Classify (Version, Field_Count, Value_Supported) = Expected);
   end Check;

begin
   Check (HTTP_1_0, 0, False, Ignore);
   Check (HTTP_1_0, 0, True, Ignore);
   Check (HTTP_1_0, 1, False, Ignore);
   Check (HTTP_1_0, 1, True, Ignore);
   Check (HTTP_1_0, 2, False, Ignore);
   Check (HTTP_1_0, Natural'Last, True, Ignore);

   Check (HTTP_1_1, 0, False, Ignore);
   Check (HTTP_1_1, 0, True, Ignore);
   Check (HTTP_1_1, 1, True, Proceed);
   Check (HTTP_1_1, 1, False, Reject);
   Check (HTTP_1_1, 2, True, Reject);
   Check (HTTP_1_1, Natural'Last, False, Reject);
end Flyology.HTTP.Expect_Policy.Smoke;
