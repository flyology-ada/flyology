with Flyology_Bench.Internal_Conditions;

private package Flyology_Bench.Internal_Condition_Test_Hooks is

   --  Keep this a literal compile-time constant so production selection can
   --  statically remove every hook reference.
   Enabled : constant Boolean := True;

   procedure Reset;
   procedure Reject_Read (Index : Positive);
   procedure Reject_From_Read (Index : Positive);
   procedure Reject_Profile_Read (Index : Positive);
   procedure Delay_Read (Index : Positive; Milliseconds : Positive);

   function Read_Count return Natural;
   function Profile_Read_Count return Natural;

   procedure Supply
     (Value : out Internal_Conditions.Snapshot; Include_Profile : Boolean; Supplied : out Boolean);

end Flyology_Bench.Internal_Condition_Test_Hooks;
