with Interfaces;

private package Flyology.Counter_Policy
  with SPARK_Mode => On
is

   use type Interfaces.Unsigned_64;

   --  Return the next representable Natural, retaining Natural'Last once the
   --  cumulative counter reaches its public representation limit.
   function Saturating_Increment (Value : Natural) return Natural
   with
     Global => null,
     Post   =>
       Saturating_Increment'Result =
         (if Value = Natural'Last then Natural'Last else Value + 1);

   --  Return the next modular generation while reserving zero as an invalid
   --  sentinel. The maximum valid generation therefore wraps to one.
   function Nonzero_Successor
     (Value : Interfaces.Unsigned_64) return Interfaces.Unsigned_64
   with
     Global => null,
     Post   =>
       Nonzero_Successor'Result /= 0
       and then Nonzero_Successor'Result =
         (if Value = Interfaces.Unsigned_64'Last then 1 else Value + 1);

end Flyology.Counter_Policy;
