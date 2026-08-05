package body Flyology.HTTP.Route_Parameter_Policy
  with SPARK_Mode => On
is

   function Advance
     (Current : Parameter_Count) return Capacity_Transition is
     (if Current = Max_Parameters
      then (Accepted => False, Next_Count => Current)
      else (Accepted => True, Next_Count => Current + 1));

end Flyology.HTTP.Route_Parameter_Policy;
