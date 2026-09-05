package body System.Flyology.Faults is

   use type Interfaces.C.int;

   function Test_Fault_Hit (Point : Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, Test_Fault_Hit, "flyology_test_fault_hit");

   function Test_Pause_Final_Reaper return Interfaces.C.int;
   pragma Import (C, Test_Pause_Final_Reaper, "flyology_test_pause_final_reaper");

   procedure Test_Release_Final_Reaper;
   pragma Import (C, Test_Release_Final_Reaper, "flyology_test_release_final_reaper");

   function Test_Pause_Create_Registration return Interfaces.C.int;
   pragma Import (C, Test_Pause_Create_Registration, "flyology_test_pause_create_registration");

   procedure Test_Note_Create_Registering;
   pragma Import (C, Test_Note_Create_Registering, "flyology_test_note_create_registering");

   procedure Test_Note_Automatic_Placement_Claim (Group : Interfaces.C.int);
   pragma Import (C, Test_Note_Automatic_Placement_Claim, "flyology_test_note_automatic_placement_claim");

   function Test_Pause_Automatic_Placement return Interfaces.C.int;
   pragma Import (C, Test_Pause_Automatic_Placement, "flyology_test_pause_automatic_placement");

   procedure Test_Release_Create_Registration;
   pragma Import (C, Test_Release_Create_Registration, "flyology_test_release_create_registration");

   procedure Test_Begin_Poller_Translation;
   pragma Import (C, Test_Begin_Poller_Translation, "flyology_test_begin_poller_translation");

   function Test_Poller_Translation_Released return Interfaces.C.int;
   pragma Import (C, Test_Poller_Translation_Released, "flyology_test_poller_translation_released");

   procedure Test_Begin_Descriptor_Cancel_Budget;
   pragma Import (C, Test_Begin_Descriptor_Cancel_Budget, "flyology_test_begin_descriptor_cancel_budget");

   function Test_Descriptor_Cancel_Budget_Released return Interfaces.C.int;
   pragma
     Import (C, Test_Descriptor_Cancel_Budget_Released, "flyology_test_descriptor_cancel_budget_released");

   function Usleep (Microseconds : Interfaces.C.unsigned) return Interfaces.C.int;
   pragma Import (C, Usleep, "usleep");

   procedure Test_Note_Poller_Cancel;
   pragma Import (C, Test_Note_Poller_Cancel, "flyology_test_note_poller_cancel");

   procedure Test_Note_Descriptor_Cancel_Queued;
   pragma Import (C, Test_Note_Descriptor_Cancel_Queued, "flyology_test_note_descriptor_cancel_queued");

   procedure Test_Note_Descriptor_Cancel_Processed;
   pragma Import (C, Test_Note_Descriptor_Cancel_Processed, "flyology_test_note_descriptor_cancel_processed");

   function Fail (Point : Fault_Point) return Boolean
   is (Test_Fault_Hit (Interfaces.C.int (Fault_Point'Enum_Rep (Point))) /= 0);

   function Pause_Final_Reaper return Boolean
   is (Test_Pause_Final_Reaper = 0);

   procedure Release_Final_Reaper is
   begin
      Test_Release_Final_Reaper;
   end Release_Final_Reaper;

   function Pause_Create_Registration return Boolean
   is (Test_Pause_Create_Registration = 0);

   procedure Note_Automatic_Placement_Claim (Group : Interfaces.C.int) is
   begin
      Test_Note_Automatic_Placement_Claim (Group);
   end Note_Automatic_Placement_Claim;

   function Pause_Automatic_Placement return Boolean
   is (Test_Pause_Automatic_Placement = 0);

   procedure Note_Create_Registering is
   begin
      Test_Note_Create_Registering;
   end Note_Create_Registering;

   procedure Release_Create_Registration is
   begin
      Test_Release_Create_Registration;
   end Release_Create_Registration;

   procedure Pause_Poller_Translation is
      Ignored : Interfaces.C.int;
      pragma Unreferenced (Ignored);
   begin
      --  Ada owns rendezvous progress. C exposes only atomic state and the
      --  fixed-signature POSIX sleep primitive used by this test-only path.
      Test_Begin_Poller_Translation;
      while Test_Poller_Translation_Released = 0 loop
         Ignored := Usleep (1_000);
      end loop;
   end Pause_Poller_Translation;

   procedure Pause_Descriptor_Cancel_Budget is
      Ignored : Interfaces.C.int;
      pragma Unreferenced (Ignored);
   begin
      Test_Begin_Descriptor_Cancel_Budget;
      while Test_Descriptor_Cancel_Budget_Released = 0 loop
         Ignored := Usleep (1_000);
      end loop;
   end Pause_Descriptor_Cancel_Budget;

   procedure Note_Poller_Cancel is
   begin
      Test_Note_Poller_Cancel;
   end Note_Poller_Cancel;

   procedure Note_Descriptor_Cancel_Queued is
   begin
      Test_Note_Descriptor_Cancel_Queued;
   end Note_Descriptor_Cancel_Queued;

   procedure Note_Descriptor_Cancel_Processed is
   begin
      Test_Note_Descriptor_Cancel_Processed;
   end Note_Descriptor_Cancel_Processed;

end System.Flyology.Faults;
