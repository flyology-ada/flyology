package body Gnatevl.Time_Math
  with SPARK_Mode
is
   function Remaining
     (Timeout : Duration;
      Elapsed : Duration) return Duration
   is
   begin
      if Timeout < 0.0 then
         return -1.0;
      elsif Elapsed <= 0.0 then
         return Timeout;
      elsif Elapsed >= Timeout then
         return 0.0;
      else
         return Timeout - Elapsed;
      end if;
   end Remaining;

   function To_Nanoseconds (Timeout : Duration) return C.long_long is
   begin
      if Timeout < 0.0 then
         return -1;
      end if;
      return C.long_long (Timeout / Nanosecond);
   end To_Nanoseconds;

   function To_Milliseconds (Timeout : Duration) return C.int is
      Nanoseconds : C.long_long;
   begin
      if Timeout < 0.0 then
         return -1;
      end if;

      Nanoseconds := To_Nanoseconds (Timeout);
      if Nanoseconds >= Maximum_Poll_Nanoseconds then
         return C.int'Last;
      end if;
      return C.int
        ((Nanoseconds + Nanoseconds_Per_Millisecond - 1)
         / Nanoseconds_Per_Millisecond);
   end To_Milliseconds;

end Gnatevl.Time_Math;
