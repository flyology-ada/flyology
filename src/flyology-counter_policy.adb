package body Flyology.Counter_Policy
  with SPARK_Mode => On
is

   function Saturating_Increment (Value : Natural) return Natural is
     (if Value = Natural'Last then Natural'Last else Value + 1);

   function Nonzero_Successor
     (Value : Interfaces.Unsigned_64) return Interfaces.Unsigned_64 is
     (if Value = Interfaces.Unsigned_64'Last then 1 else Value + 1);

end Flyology.Counter_Policy;
