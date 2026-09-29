with Flyology.Counter_Policy;
with Interfaces;

procedure Flyology.Counter_Policy_Smoke is
   package Counters renames Flyology.Counter_Policy;
   use type Interfaces.Unsigned_64;

   Value      : Natural;
   Generation : Interfaces.Unsigned_64;
begin
   Value := Counters.Saturating_Increment (0);
   pragma Assert (Value = 1);

   Value := Counters.Saturating_Increment (Natural'Last - 1);
   pragma Assert (Value = Natural'Last);

   Value := Counters.Saturating_Increment (Value);
   pragma Assert (Value = Natural'Last);

   Value := Counters.Saturating_Increment (Value);
   pragma Assert (Value = Natural'Last);

   Generation := Counters.Nonzero_Successor (0);
   pragma Assert (Generation = 1);

   Generation := Counters.Nonzero_Successor (Interfaces.Unsigned_64'Last - 1);
   pragma Assert (Generation = Interfaces.Unsigned_64'Last);

   Generation := Counters.Nonzero_Successor (Generation);
   pragma Assert (Generation = 1);

   Generation := Counters.Nonzero_Successor (Generation);
   pragma Assert (Generation = 2);
end Flyology.Counter_Policy_Smoke;
