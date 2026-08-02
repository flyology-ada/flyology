package body System.Gnatevl.Faults is

   function Fail (Point : Fault_Point) return Boolean is
   begin
      pragma Unreferenced (Point);
      return False;
   end Fail;

end System.Gnatevl.Faults;
