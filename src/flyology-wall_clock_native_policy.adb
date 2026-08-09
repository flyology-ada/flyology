package body Flyology.Wall_Clock_Native_Policy
  with SPARK_Mode
is
   Billion : constant Interfaces.Integer_64 := 1_000_000_000;

   function Valid_Arm_Arguments
     (State_Open            : Boolean;
      Year                  : Integer;
      Month                 : Integer;
      Day                   : Integer;
      Hour                  : Integer;
      Minute                : Integer;
      Second                : Integer;
      Nanoseconds           : Interfaces.Integer_64;
      Leap_Second           : Integer;
      Maximum_Slice         : Interfaces.Integer_64) return Boolean
   is
     (State_Open
      and then Year in 1901 .. 2399
      and then Month in 1 .. 12
      and then Day in 1 .. 31
      and then Hour in 0 .. 23
      and then Minute in 0 .. 59
      and then Second in 0 .. 59
      and then Nanoseconds in Nanosecond_Part
      and then Leap_Second in 0 .. 1
      and then Maximum_Slice > 0);

   function Days_From_Civil
     (Year  : Integer;
      Month : Integer;
      Day   : Integer) return Civil_Day_Count
   is
      Adjusted_Year  : constant Integer :=
        Year - Boolean'Pos (Month <= 2);
      Era            : constant Integer := Adjusted_Year / 400;
      Year_Of_Era    : constant Integer := Adjusted_Year - Era * 400;
      Adjusted_Month : constant Integer :=
        (if Month > 2 then Month - 3 else Month + 9);
      Day_Of_Year    : constant Integer :=
        (153 * Adjusted_Month + 2) / 5 + Day - 1;
      Day_Of_Era     : constant Integer :=
        Year_Of_Era * 365 + Year_Of_Era / 4 - Year_Of_Era / 100
        + Day_Of_Year;
   begin
      return Interfaces.Integer_64 (Era) * 146_097
        + Interfaces.Integer_64 (Day_Of_Era) - 719_468;
   end Days_From_Civil;

   function Civil_Timestamp
     (Year        : Integer;
      Month       : Integer;
      Day         : Integer;
      Hour        : Integer;
      Minute      : Integer;
      Second      : Integer;
      Nanoseconds : Nanosecond_Part;
      Leap_Second : Boolean) return Timestamp
   is
      Seconds_Since_Epoch : constant Interfaces.Integer_64 :=
        Days_From_Civil (Year, Month, Day) * 86_400
        + Interfaces.Integer_64 (Hour) * 3_600
        + Interfaces.Integer_64 (Minute) * 60
        + Interfaces.Integer_64 (Second)
        + Interfaces.Integer_64 (Boolean'Pos (Leap_Second));
   begin
      return (Seconds_Since_Epoch, Nanoseconds);
   end Civil_Timestamp;

   function Before (Left, Right : Timestamp) return Boolean is
     (Left.Seconds < Right.Seconds
      or else
        (Left.Seconds = Right.Seconds
         and then Left.Nanoseconds < Right.Nanoseconds));

   function Add_Nanoseconds
     (Value  : Timestamp;
      Amount : Interfaces.Integer_64) return Timestamp_Result
   is
      Whole_Seconds : constant Interfaces.Integer_64 := Amount / Billion;
      Remainder     : constant Interfaces.Integer_64 := Amount rem Billion;
      Carry         : constant Interfaces.Integer_64 :=
        Boolean'Pos (Value.Nanoseconds + Remainder >= Billion);
   begin
      if Value.Seconds > Interfaces.Integer_64'Last - Whole_Seconds - Carry
      then
         return (Fits => False, Value => Value);
      end if;
      return
        (Fits => True,
         Value =>
           (Seconds     => Value.Seconds + Whole_Seconds + Carry,
            Nanoseconds =>
              Value.Nanoseconds + Remainder - Carry * Billion));
   end Add_Nanoseconds;

   function Subtract_Nanoseconds
     (Value  : Timestamp;
      Amount : Interfaces.Integer_64) return Timestamp_Result
   is
      Whole_Seconds : constant Interfaces.Integer_64 := Amount / Billion;
      Remainder     : constant Interfaces.Integer_64 := Amount rem Billion;
      Borrow        : constant Interfaces.Integer_64 :=
        Boolean'Pos (Value.Nanoseconds < Remainder);
   begin
      if Value.Seconds < Interfaces.Integer_64'First + Whole_Seconds + Borrow
      then
         return (Fits => False, Value => Value);
      end if;
      return
        (Fits => True,
         Value =>
           (Seconds     => Value.Seconds - Whole_Seconds - Borrow,
            Nanoseconds =>
              Value.Nanoseconds - Remainder + Borrow * Billion));
   end Subtract_Nanoseconds;

   function Earlier (Left, Right : Timestamp) return Timestamp is
     (if Before (Left, Right) then Left else Right);

   function Difference_Nanoseconds
     (Later, Earlier : Timestamp) return Difference_Result
   is
      Seconds : Interfaces.Integer_64;
      Product : Interfaces.Integer_64;
      Fraction : constant Interfaces.Integer_64 :=
        Later.Nanoseconds - Earlier.Nanoseconds;
   begin
      if
        (Earlier.Seconds < 0
         and then
           Later.Seconds > Interfaces.Integer_64'Last + Earlier.Seconds)
        or else
          (Earlier.Seconds > 0
           and then
             Later.Seconds < Interfaces.Integer_64'First + Earlier.Seconds)
      then
         return (Fits => False, Nanoseconds => 0);
      end if;

      Seconds := Later.Seconds - Earlier.Seconds;
      if Seconds > Interfaces.Integer_64'Last / Billion
        or else Seconds < Interfaces.Integer_64'First / Billion
      then
         return (Fits => False, Nanoseconds => 0);
      end if;

      Product := Seconds * Billion;
      if (Fraction > 0
          and then Product > Interfaces.Integer_64'Last - Fraction)
        or else
          (Fraction < 0
           and then Product < Interfaces.Integer_64'First - Fraction)
      then
         return (Fits => False, Nanoseconds => 0);
      end if;
      return
        (Fits        => True,
         Nanoseconds => Product + Fraction);
   end Difference_Nanoseconds;
end Flyology.Wall_Clock_Native_Policy;
