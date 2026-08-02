package body System.Gnatevl.Faults is

   use type Interfaces.C.int;

   function Fail (Point : Fault_Point) return Boolean is
     (Test_Fault_Hit (Interfaces.C.int (Fault_Point'Enum_Rep (Point))) /= 0);

end System.Gnatevl.Faults;
