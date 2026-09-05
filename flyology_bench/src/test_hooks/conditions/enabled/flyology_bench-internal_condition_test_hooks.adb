package body Flyology_Bench.Internal_Condition_Test_Hooks is

   Maximum_Reads : constant := 128;
   type Rejection_Map is array (Positive range 1 .. Maximum_Reads) of Boolean;
   type Delay_Map is array (Positive range 1 .. Maximum_Reads) of Natural;

   Rejected_Reads         : Rejection_Map := [others => False];
   Rejected_Profile_Reads : Rejection_Map := [others => False];
   Read_Delays_MS         : Delay_Map := [others => 0];
   Reject_From            : Natural := 0;
   Throttle_From          : Natural := 0;
   Reads                  : Natural := 0;
   Profile_Reads          : Natural := 0;

   procedure Reset is
   begin
      Rejected_Reads := [others => False];
      Rejected_Profile_Reads := [others => False];
      Read_Delays_MS := [others => 0];
      Reject_From := 0;
      Throttle_From := 0;
      Reads := 0;
      Profile_Reads := 0;
   end Reset;

   procedure Reject_Read (Index : Positive) is
   begin
      if Index > Maximum_Reads then
         raise Constraint_Error with "condition hook read index exceeds its fixed capacity";
      end if;
      Rejected_Reads (Index) := True;
   end Reject_Read;

   procedure Reject_From_Read (Index : Positive) is
   begin
      Reject_From := Index;
   end Reject_From_Read;

   procedure Reject_Profile_Read (Index : Positive) is
   begin
      if Index > Maximum_Reads then
         raise Constraint_Error with "condition hook profile-read index exceeds its fixed capacity";
      end if;
      Rejected_Profile_Reads (Index) := True;
   end Reject_Profile_Read;

   procedure Begin_Throttle_Event (Index : Positive) is
   begin
      if Index > Maximum_Reads then
         raise Constraint_Error with "condition hook throttle index exceeds its fixed capacity";
      end if;
      Throttle_From := Index;
   end Begin_Throttle_Event;

   procedure Delay_Read (Index : Positive; Milliseconds : Positive) is
   begin
      if Index > Maximum_Reads then
         raise Constraint_Error with "condition hook delayed-read index exceeds its fixed capacity";
      end if;
      Read_Delays_MS (Index) := Milliseconds;
   end Delay_Read;

   function Read_Count return Natural
   is (Reads);

   function Profile_Read_Count return Natural
   is (Profile_Reads);

   procedure Supply
     (Value : out Internal_Conditions.Snapshot; Include_Profile : Boolean; Supplied : out Boolean)
   is
      Reject_Live    : Boolean;
      Reject_Profile : Boolean := False;
   begin
      Reads := Reads + 1;
      if Reads <= Maximum_Reads and then Read_Delays_MS (Reads) > 0 then
         delay Duration (Read_Delays_MS (Reads)) / 1_000.0;
      end if;
      if Include_Profile then
         Profile_Reads := Profile_Reads + 1;
         Reject_Profile := Profile_Reads <= Maximum_Reads and then Rejected_Profile_Reads (Profile_Reads);
      end if;
      Reject_Live :=
        (Reads <= Maximum_Reads and then Rejected_Reads (Reads))
        or else (Reject_From /= 0 and then Reads >= Reject_From);
      Value :=
        (Profile_Availability        =>
           (if Include_Profile then Condition_Available else Condition_Unavailable),
         Profile_Detector            => (if Include_Profile then Darwin_PMSet else No_Condition_Detector),
         Profile                     =>
           (if not Include_Profile
            then Profile_Unknown
            elsif Reject_Profile
            then Profile_Reduced
            else Profile_Performance),
         Power_Source                => External_Power,
         Low_Power_Availability      => Condition_Available,
         Low_Power_Detector          => Darwin_Process_Info,
         Low_Power_Mode              => Low_Power_Mode_Disabled,
         Process_Profile_Avail       => Condition_Available,
         Process_Profile_Detector    => Darwin_Process_Info,
         Process_Profile             => Process_Profile_Default,
         Thermal_Availability        => Condition_Available,
         Thermal_Detector            => Darwin_Process_Info,
         Thermal_State               =>
           (if Reject_Live then Thermal_State_Serious else Thermal_State_Nominal),
         Degradation_Availability    => Condition_Available,
         Degradation                 => Not_Degraded,
         Throttle_Availability       => Condition_Available,
         Throttle_Time_Avail         => Condition_Available,
         Throttle_Detector           => Linux_CPU_Thermal_Throttle,
         Throttle_Total              => (if Throttle_From /= 0 and then Reads >= Throttle_From then 1 else 0),
         Throttle_Time_Total_MS      => 0,
         Throttle_Discontinuous      => False,
         Throttle_Time_Discontinuous => False);
      Supplied := True;
   end Supply;

end Flyology_Bench.Internal_Condition_Test_Hooks;
