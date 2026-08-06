package body Flyology.Rate_Limit_Policy
  with SPARK_Mode
is

   function Refilled_Tokens
     (Tokens  : Duration;
      Elapsed : Duration;
      Rate    : Positive) return Duration
   is
      Capacity  : constant Duration := Duration (Rate);
      Increment : Duration;
   begin
      if Elapsed >= 1.0 then
         return Capacity;
      elsif Elapsed <= 0.0 then
         return Duration'Min (Capacity, Tokens);
      end if;

      Increment := Elapsed * Rate;
      if Tokens >= Capacity - Increment then
         return Capacity;
      else
         return Tokens + Increment;
      end if;
   end Refilled_Tokens;

end Flyology.Rate_Limit_Policy;
