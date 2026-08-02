with Interfaces.C;

private package Gnatevl.Time_Math
  with Preelaborate,
       SPARK_Mode
is
   package C renames Interfaces.C;

   use type C.int;
   use type C.long_long;

   Nanosecond                  : constant Duration := 0.000_000_001;
   Nanoseconds_Per_Millisecond : constant C.long_long := 1_000_000;
   Maximum_Poll_Nanoseconds    : constant C.long_long :=
     C.long_long (C.int'Last) * Nanoseconds_Per_Millisecond;

   function Remaining
     (Timeout : Duration;
      Elapsed : Duration) return Duration
   with Post =>
     (if Timeout < 0.0 then
         Remaining'Result = -1.0
      elsif Elapsed <= 0.0 then
         Remaining'Result = Timeout
      elsif Elapsed >= Timeout then
         Remaining'Result = 0.0
      else
         Remaining'Result = Timeout - Elapsed);

   function To_Nanoseconds (Timeout : Duration) return C.long_long
   with Post =>
     (if Timeout < 0.0 then
         To_Nanoseconds'Result = -1
      else
         To_Nanoseconds'Result =
           C.long_long (Timeout / Nanosecond));

   function To_Milliseconds (Timeout : Duration) return C.int
   with Post =>
     (if Timeout < 0.0 then
         To_Milliseconds'Result = -1
      elsif To_Nanoseconds (Timeout) >= Maximum_Poll_Nanoseconds then
         To_Milliseconds'Result = C.int'Last
      else
         To_Milliseconds'Result =
           C.int
             ((To_Nanoseconds (Timeout)
               + Nanoseconds_Per_Millisecond - 1)
              / Nanoseconds_Per_Millisecond));

end Gnatevl.Time_Math;
