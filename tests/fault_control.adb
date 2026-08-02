package body Fault_Control is

   use type Interfaces.C.int;

   function Id (At_Point : Point) return Interfaces.C.int is
     (Interfaces.C.int (Point'Enum_Rep (At_Point)));

   function Enabled return Boolean is (C_Enabled /= 0);

   procedure Reset is
   begin
      C_Reset;
   end Reset;

   procedure Arm
     (At_Point : Point;
      First    : Natural := 0;
      Count    : Positive := 1)
   is
   begin
      if C_Arm
        (Id (At_Point), Interfaces.C.unsigned (First),
         Interfaces.C.unsigned (Count)) /= 0
      then
         raise Program_Error with "runtime fault injection is disabled";
      end if;
   end Arm;

   function Calls (At_Point : Point) return Natural is
     (Natural (C_Calls (Id (At_Point))));

end Fault_Control;
