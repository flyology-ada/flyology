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

   procedure Disarm (At_Point : Point) is
   begin
      if C_Disarm (Id (At_Point)) /= 0 then
         raise Program_Error with "runtime fault injection is disabled";
      end if;
   end Disarm;

   function Calls (At_Point : Point) return Natural is
     (Natural (C_Calls (Id (At_Point))));

   function File_Cancel_Count
     (Backend     : File_Cancel_Backend;
      Disposition : File_Cancel_Disposition;
      Terminal    : Boolean) return Natural
   is
     (Natural
        (C_File_Cancel_Count
           (Interfaces.C.int (File_Cancel_Backend'Enum_Rep (Backend)),
            Interfaces.C.int
              (File_Cancel_Disposition'Enum_Rep (Disposition)),
            Boolean'Pos (Terminal))));

   function Uring_Identity_Count (Reused : Boolean) return Natural is
     (Natural
        (C_Uring_Identity_Count
           (Interfaces.C.int (Boolean'Pos (Reused)))));

   function Uring_Admin_Complete_Count return Natural is
     (Natural (C_Uring_Admin_Complete_Count));

end Fault_Control;
