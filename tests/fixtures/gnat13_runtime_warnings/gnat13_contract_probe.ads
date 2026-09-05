package Gnat13_Contract_Probe is
   function Require_Positive (Value : Integer) return Integer
   with Pre => Value > 0;
   pragma Inline_Always (Require_Positive);

   function Return_Positive (Value : Integer) return Integer
   with Post => Return_Positive'Result > 0;
   pragma Inline_Always (Return_Positive);
end Gnat13_Contract_Probe;
