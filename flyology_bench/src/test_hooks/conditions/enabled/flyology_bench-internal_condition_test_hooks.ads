with Flyology_Bench.Internal_Conditions;

private package Flyology_Bench.Internal_Condition_Test_Hooks is

   --  Keep this a literal compile-time constant so production selection can
   --  statically remove every hook reference.
   Enabled : constant Boolean := True;

   procedure Reset;
   procedure Reject_Read (Index : Positive);
   procedure Reject_From_Read (Index : Positive);
   procedure Reject_Profile_Read (Index : Positive);
   procedure Begin_Throttle_Event (Index : Positive);
   procedure Delay_Read (Index : Positive; Milliseconds : Positive);
   procedure Use_Linux_Fixture
     (Sysfs_Root                : String;
      PPD_Profile               : String;
      PPD_Profile_Available     : Boolean;
      PPD_Degradation           : String;
      PPD_Degradation_Available : Boolean);

   function Read_Count return Natural;
   function Profile_Read_Count return Natural;
   function Linux_Fixture_Enabled return Boolean;
   function Linux_Sysfs_Root return String;
   function Linux_PPD_Profile return String;
   function Linux_PPD_Profile_Available return Boolean;
   function Linux_PPD_Degradation return String;
   function Linux_PPD_Degradation_Available return Boolean;

   procedure Supply
     (Value : out Internal_Conditions.Snapshot; Include_Profile : Boolean; Supplied : out Boolean);

end Flyology_Bench.Internal_Condition_Test_Hooks;
