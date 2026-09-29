package body Gnat13_Contract_Probe is
   function Require_Positive (Value : Integer) return Integer is (Value);

   function Return_Positive (Value : Integer) return Integer is (Value);
end Gnat13_Contract_Probe;
