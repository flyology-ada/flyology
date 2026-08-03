private package Flyology.Counter_Policy
  with SPARK_Mode => On
is

   --  Return the next representable Natural, retaining Natural'Last once the
   --  cumulative counter reaches its public representation limit.
   function Saturating_Increment (Value : Natural) return Natural
   with
     Global => null,
     Post   =>
       Saturating_Increment'Result =
         (if Value = Natural'Last then Natural'Last else Value + 1);

end Flyology.Counter_Policy;
