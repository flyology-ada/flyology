--  Internal, proved token-bucket refill arithmetic used by HTTP rate limits.
private package Flyology.Rate_Limit_Policy
  with Preelaborate,
       SPARK_Mode
is

   --  Refill at Rate tokens per second and retain at most one second of
   --  capacity. Nonpositive elapsed time adds nothing. One second or more
   --  saturates directly so long idle intervals are never multiplied by Rate.
   function Refilled_Tokens
     (Tokens  : Duration;
      Elapsed : Duration;
      Rate    : Positive) return Duration
   with
     Global         => null,
     Contract_Cases =>
       (Elapsed >= 1.0 =>
          Refilled_Tokens'Result = Duration (Rate),
        Elapsed <= 0.0 =>
          Refilled_Tokens'Result = Duration'Min (Duration (Rate), Tokens),
        others =>
          Refilled_Tokens'Result =
            (if Tokens >= Duration (Rate) - Elapsed * Rate
             then Duration (Rate)
             else Tokens + Elapsed * Rate));

end Flyology.Rate_Limit_Policy;
