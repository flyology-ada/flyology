package body Flyology.Dynamic_Destroy_Test_Hooks is

   protected State is
      procedure Reset;
      procedure Arm_Current_Release_Contention;
      procedure Consume_Current_Release_Contention (Armed : out Boolean);
   private
      Current_Release_Contention_Armed : Boolean := False;
   end State;

   protected body State is
      procedure Reset is
      begin
         Current_Release_Contention_Armed := False;
      end Reset;

      procedure Arm_Current_Release_Contention is
      begin
         Current_Release_Contention_Armed := True;
      end Arm_Current_Release_Contention;

      procedure Consume_Current_Release_Contention (Armed : out Boolean) is
      begin
         Armed := Current_Release_Contention_Armed;
         Current_Release_Contention_Armed := False;
      end Consume_Current_Release_Contention;
   end State;

   procedure Reset is
   begin
      State.Reset;
   end Reset;

   procedure Arm_Current_Release_Contention is
   begin
      State.Arm_Current_Release_Contention;
   end Arm_Current_Release_Contention;

   procedure Consume_Current_Release_Contention (Armed : out Boolean) is
   begin
      State.Consume_Current_Release_Contention (Armed);
   end Consume_Current_Release_Contention;

end Flyology.Dynamic_Destroy_Test_Hooks;
