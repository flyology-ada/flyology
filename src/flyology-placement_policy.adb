package body Flyology.Placement_Policy
  with SPARK_Mode => On
is

   function Group_For_CPU (CPU : Group_Selector) return Natural is (CPU);

end Flyology.Placement_Policy;
