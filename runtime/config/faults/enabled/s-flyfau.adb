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

   function Test_Pause_Create_Registration return Interfaces.C.int;
   pragma Import
     (C,
      Test_Pause_Create_Registration,
      "flyology_test_pause_create_registration");

   procedure Test_Note_Create_Registering;
   pragma Import
     (C,
      Test_Note_Create_Registering,
      "flyology_test_note_create_registering");

   procedure Test_Note_Automatic_Placement_Claim
     (Group : Interfaces.C.int);
   pragma Import
     (C,
      Test_Note_Automatic_Placement_Claim,
      "flyology_test_note_automatic_placement_claim");

   function Test_Pause_Automatic_Placement return Interfaces.C.int;
   pragma Import
     (C,
      Test_Pause_Automatic_Placement,
      "flyology_test_pause_automatic_placement");

   procedure Test_Release_Create_Registration;
   pragma Import
     (C,
      Test_Release_Create_Registration,
      "flyology_test_release_create_registration");

   function Fail (Point : Fault_Point) return Boolean is
     (Test_Fault_Hit (Interfaces.C.int (Fault_Point'Enum_Rep (Point))) /= 0);

   function Pause_Final_Reaper return Boolean is
     (Test_Pause_Final_Reaper = 0);

   procedure Release_Final_Reaper is
   begin
      Test_Release_Final_Reaper;
   end Release_Final_Reaper;

   function Pause_Create_Registration return Boolean is
     (Test_Pause_Create_Registration = 0);

   procedure Note_Automatic_Placement_Claim (Group : Interfaces.C.int) is
   begin
      Test_Note_Automatic_Placement_Claim (Group);
   end Note_Automatic_Placement_Claim;

   function Pause_Automatic_Placement return Boolean is
     (Test_Pause_Automatic_Placement = 0);

   procedure Note_Create_Registering is
   begin
      Test_Note_Create_Registering;
   end Note_Create_Registering;

   procedure Release_Create_Registration is
   begin
      Test_Release_Create_Registration;
   end Release_Create_Registration;

end System.Flyology.Faults;
