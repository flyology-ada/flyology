with Flyology.Rate_Limit_Policy;

procedure Flyology.Rate_Limit_Policy_Smoke is
   package Policy renames Flyology.Rate_Limit_Policy;

   Value : Duration;
begin
   Value := Policy.Refilled_Tokens (1.0, -0.5, 4);
   pragma Assert (Value = 1.0);

   Value := Policy.Refilled_Tokens (1.0, 0.125, 4);
   pragma Assert (Value = 1.5);

   Value := Policy.Refilled_Tokens (3.75, 0.125, 4);
   pragma Assert (Value = 4.0);

   Value := Policy.Refilled_Tokens (0.0, 1.0, Positive'Last);
   pragma Assert (Value = Duration (Positive'Last));

   Value := Policy.Refilled_Tokens
     (Duration (Positive'Last) - 1.0, 0.999_999_999, Positive'Last);
   pragma Assert (Value = Duration (Positive'Last));

   Value := Policy.Refilled_Tokens
     (0.0, Duration'Last, Positive'Last);
   pragma Assert (Value = Duration (Positive'Last));
end Flyology.Rate_Limit_Policy_Smoke;
