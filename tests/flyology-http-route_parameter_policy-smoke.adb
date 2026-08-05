procedure Flyology.HTTP.Route_Parameter_Policy.Smoke is
   Transition : Capacity_Transition;
begin
   Transition := Advance (0);
   pragma Assert (Transition.Accepted);
   pragma Assert (Transition.Next_Count = 1);

   Transition := Advance (Max_Parameters - 1);
   pragma Assert (Transition.Accepted);
   pragma Assert (Transition.Next_Count = Max_Parameters);

   Transition := Advance (Max_Parameters);
   pragma Assert (not Transition.Accepted);
   pragma Assert (Transition.Next_Count = Max_Parameters);
end Flyology.HTTP.Route_Parameter_Policy.Smoke;
