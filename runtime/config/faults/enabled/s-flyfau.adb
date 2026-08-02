with Interfaces.C;

package body System.Flyology.Faults is

   use type Interfaces.C.int;

   function Test_Fault_Hit
     (Point : Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, Test_Fault_Hit, "flyology_test_fault_hit");

   function Fail (Point : Fault_Point) return Boolean is
     (Test_Fault_Hit (Interfaces.C.int (Fault_Point'Enum_Rep (Point))) /= 0);

end System.Flyology.Faults;
