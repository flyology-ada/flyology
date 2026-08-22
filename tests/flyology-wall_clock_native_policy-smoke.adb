with Interfaces;

procedure Flyology.Wall_Clock_Native_Policy.Smoke is
   procedure Require (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Require;

   function Valid
     (Open        : Boolean := True;
      Year        : Integer := 2026;
      Month       : Integer := 8;
      Day         : Integer := 8;
      Hour        : Integer := 12;
      Minute      : Integer := 30;
      Second      : Integer := 45;
      Nanoseconds : Interfaces.Integer_64 := 123;
      Leap        : Integer := 0;
      Slice       : Interfaces.Integer_64 := 1) return Boolean
   is (Valid_Arm_Arguments (Open, Year, Month, Day, Hour, Minute, Second, Nanoseconds, Leap, Slice));

   Epoch  : constant Timestamp := Civil_Timestamp (1970, 1, 1, 0, 0, 0, 0, False);
   Leap   : constant Timestamp := Civil_Timestamp (1970, 1, 1, 0, 0, 59, 7, True);
   Value  : constant Timestamp := (Seconds => 10, Nanoseconds => 900_000_000);
   Result : Timestamp_Result;
   Diff   : Difference_Result;
begin
   Require (Valid, "valid arm arguments rejected");
   Require (not Valid (Open => False), "closed state accepted");
   Require (not Valid (Year => 1900), "low year accepted");
   Require (not Valid (Year => 2400), "high year accepted");
   Require (not Valid (Month => 0), "low month accepted");
   Require (not Valid (Month => 13), "high month accepted");
   Require (not Valid (Day => 0), "low day accepted");
   Require (not Valid (Day => 32), "high day accepted");
   Require (not Valid (Hour => -1), "low hour accepted");
   Require (not Valid (Hour => 24), "high hour accepted");
   Require (not Valid (Minute => -1), "low minute accepted");
   Require (not Valid (Minute => 60), "high minute accepted");
   Require (not Valid (Second => -1), "low second accepted");
   Require (not Valid (Second => 60), "high second accepted");
   Require (not Valid (Nanoseconds => -1), "negative fraction accepted");
   Require (not Valid (Nanoseconds => 1_000_000_000), "oversized fraction accepted");
   Require (Valid (Leap => 1), "leap-second flag rejected");
   Require (not Valid (Leap => -1), "negative leap flag accepted");
   Require (not Valid (Leap => 2), "oversized leap flag accepted");
   Require (not Valid (Slice => 0), "zero slice accepted");
   Require (not Valid (Slice => -1), "negative slice accepted");

   Require (Days_From_Civil (1970, 1, 1) = 0, "epoch day mismatch");
   Require (Days_From_Civil (1969, 12, 31) = -1, "pre-epoch mismatch");
   Require (Days_From_Civil (2000, 3, 1) = 11_017, "leap day mismatch");
   Require (Epoch = (0, 0), "epoch timestamp mismatch");
   Require (Leap = (60, 7), "leap-second timestamp mismatch");

   Require (Before ((0, 0), (1, 0)), "second ordering failed");
   Require (Before ((1, 0), (1, 1)), "fraction ordering failed");
   Require (not Before ((1, 1), (1, 1)), "equal timestamps ordered");
   Require (not Before ((2, 0), (1, 9)), "reverse ordering failed");

   Result := Add_Nanoseconds (Value, 200_000_001);
   Require (Result.Fits and then Result.Value = (11, 100_000_001), "normalized addition mismatch");
   Result := Add_Nanoseconds ((Interfaces.Integer_64'Last, 999_999_999), 1);
   Require (not Result.Fits, "addition overflow accepted");

   Result := Subtract_Nanoseconds ((11, 100_000_000), 200_000_001);
   Require (Result.Fits and then Result.Value = (10, 899_999_999), "normalized subtraction mismatch");
   Result := Subtract_Nanoseconds ((Interfaces.Integer_64'First, 0), 1);
   Require (not Result.Fits, "subtraction overflow accepted");

   Require (Earlier ((0, 1), (0, 2)) = (0, 1), "left minimum failed");
   Require (Earlier ((0, 2), (0, 1)) = (0, 1), "right minimum failed");
   Require (Earlier ((0, 1), (0, 1)) = (0, 1), "equal minimum failed");

   Diff := Difference_Nanoseconds ((2, 100), (1, 200));
   Require (Diff.Fits and then Diff.Nanoseconds = 999_999_900, "positive difference mismatch");
   Diff := Difference_Nanoseconds ((1, 100), (2, 200));
   Require (Diff.Fits and then Diff.Nanoseconds = -1_000_000_100, "negative difference mismatch");
   Diff := Difference_Nanoseconds ((Interfaces.Integer_64'Last, 0), (-1, 0));
   Require (not Diff.Fits, "positive subtraction overflow accepted");
   Diff := Difference_Nanoseconds ((Interfaces.Integer_64'First, 0), (1, 0));
   Require (not Diff.Fits, "negative subtraction overflow accepted");
   Diff := Difference_Nanoseconds ((9_223_372_037, 0), (0, 0));
   Require (not Diff.Fits, "positive multiplication overflow accepted");
   Diff := Difference_Nanoseconds ((-9_223_372_037, 0), (0, 0));
   Require (not Diff.Fits, "negative multiplication overflow accepted");
   Diff := Difference_Nanoseconds ((9_223_372_036, 999_999_999), (0, 0));
   Require (not Diff.Fits, "positive final addition overflow accepted");
   Diff := Difference_Nanoseconds ((-9_223_372_036, 0), (0, 999_999_999));
   Require (not Diff.Fits, "negative final addition overflow accepted");
end Flyology.Wall_Clock_Native_Policy.Smoke;
