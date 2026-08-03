package body System.Flyology.Faults is

   function Fail (Point : Fault_Point) return Boolean is
   begin
      pragma Unreferenced (Point);
      return False;
   end Fail;

   function Pause_Final_Reaper return Boolean is (True);

   procedure Release_Final_Reaper is null;

end System.Flyology.Faults;
