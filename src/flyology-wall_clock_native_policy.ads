with Interfaces;

--  Proved civil-time and bounded timestamp arithmetic for platform wall-clock
--  readiness sources. Syscalls and ABI records stay in the platform bodies.
private package Flyology.Wall_Clock_Native_Policy
  with Preelaborate,
       SPARK_Mode
is
   use type Interfaces.Integer_64;

   subtype Nanosecond_Part is Interfaces.Integer_64
     range 0 .. 999_999_999;

   type Timestamp is record
      Seconds     : Interfaces.Integer_64;
      Nanoseconds : Nanosecond_Part;
   end record;

   type Timestamp_Result is record
      Fits  : Boolean;
      Value : Timestamp;
   end record;

   type Difference_Result is record
      Fits        : Boolean;
      Nanoseconds : Interfaces.Integer_64;
   end record;

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
   with Post => Valid_Arm_Arguments'Result =
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
      Day   : Integer) return Interfaces.Integer_64
   with Pre => Year in 1901 .. 2399
     and then Month in 1 .. 12
     and then Day in 1 .. 31;

   function Civil_Timestamp
     (Year        : Integer;
      Month       : Integer;
      Day         : Integer;
      Hour        : Integer;
      Minute      : Integer;
      Second      : Integer;
      Nanoseconds : Nanosecond_Part;
      Leap_Second : Boolean) return Timestamp
   with Pre => Year in 1901 .. 2399
     and then Month in 1 .. 12
     and then Day in 1 .. 31
     and then Hour in 0 .. 23
     and then Minute in 0 .. 59
     and then Second in 0 .. 59,
     Post => Civil_Timestamp'Result.Nanoseconds = Nanoseconds;

   function Before (Left, Right : Timestamp) return Boolean
   with Post => Before'Result =
     (Left.Seconds < Right.Seconds
      or else
        (Left.Seconds = Right.Seconds
         and then Left.Nanoseconds < Right.Nanoseconds));

   --  Normalize Value + Amount with the native bridge's former two's-
   --  complement boundary behavior.
   function Add_Nanoseconds
     (Value  : Timestamp;
      Amount : Interfaces.Integer_64) return Timestamp_Result
   with Pre => Amount >= 0;

   --  Test-only inverse used to synthesize a wall-clock sample at a precise
   --  target-relative distance.
   function Subtract_Nanoseconds
     (Value  : Timestamp;
      Amount : Interfaces.Integer_64) return Timestamp_Result
   with Pre => Amount >= 0;

   function Earlier (Left, Right : Timestamp) return Timestamp
   with Post =>
     (if Before (Left, Right) then Earlier'Result = Left
      else Earlier'Result = Right);

   --  Return Later - Earlier in nanoseconds with the former native bridge's
   --  two's-complement boundary behavior.
   function Difference_Nanoseconds
     (Later, Earlier : Timestamp) return Difference_Result;
end Flyology.Wall_Clock_Native_Policy;
