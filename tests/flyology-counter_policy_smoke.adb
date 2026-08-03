with Flyology.Counter_Policy;

procedure Flyology.Counter_Policy_Smoke is
   package Counters renames Flyology.Counter_Policy;

   Value : Natural;
begin
   Value := Counters.Saturating_Increment (0);
   pragma Assert (Value = 1);

   Value := Counters.Saturating_Increment (Natural'Last - 1);
   pragma Assert (Value = Natural'Last);

   Value := Counters.Saturating_Increment (Value);
   pragma Assert (Value = Natural'Last);

   Value := Counters.Saturating_Increment (Value);
   pragma Assert (Value = Natural'Last);
end Flyology.Counter_Policy_Smoke;
