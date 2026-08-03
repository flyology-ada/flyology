package body Flyology.Counter_Policy
  with SPARK_Mode => On
is

   function Saturating_Increment (Value : Natural) return Natural is
     (if Value = Natural'Last then Natural'Last else Value + 1);

end Flyology.Counter_Policy;
