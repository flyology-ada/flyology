with Interfaces.C;

package body System.Flyology.Faults is

   use type Interfaces.C.int;

   function Test_Fault_Hit
     (Point : Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, Test_Fault_Hit, "flyology_test_fault_hit");

   function Test_Pause_Final_Reaper return Interfaces.C.int;
   pragma Import
     (C, Test_Pause_Final_Reaper, "flyology_test_pause_final_reaper");

   procedure Test_Release_Final_Reaper;
   pragma Import
     (C, Test_Release_Final_Reaper, "flyology_test_release_final_reaper");

   function Fail (Point : Fault_Point) return Boolean is
     (Test_Fault_Hit (Interfaces.C.int (Fault_Point'Enum_Rep (Point))) /= 0);

   function Pause_Final_Reaper return Boolean is
     (Test_Pause_Final_Reaper = 0);

   procedure Release_Final_Reaper is
   begin
      Test_Release_Final_Reaper;
   end Release_Final_Reaper;

end System.Flyology.Faults;
