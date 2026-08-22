package body System.Flyology.Faults is

   function Fail (Point : Fault_Point) return Boolean is
   begin
      pragma Unreferenced (Point);
      return False;
   end Fail;

   function Pause_Final_Reaper return Boolean
   is (True);

   procedure Release_Final_Reaper is null;

   function Pause_Create_Registration return Boolean
   is (True);

   procedure Note_Automatic_Placement_Claim (Group : Interfaces.C.int) is null;

   function Pause_Automatic_Placement return Boolean
   is (True);

   procedure Note_Create_Registering is null;

   procedure Release_Create_Registration is null;

end System.Flyology.Faults;
