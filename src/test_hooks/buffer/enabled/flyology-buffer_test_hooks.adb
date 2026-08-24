package body Flyology.Buffer_Test_Hooks is

   protected State is
      procedure Arm;
      procedure Consume (Armed : out Boolean);
   private
      Is_Armed : Boolean := False;
   end State;

   protected body State is
      procedure Arm is
      begin
         Is_Armed := True;
      end Arm;

      procedure Consume (Armed : out Boolean) is
      begin
         Armed := Is_Armed;
         Is_Armed := False;
      end Consume;
   end State;

   procedure Arm_Next_Acquisition_Near_Exhaustion is
   begin
      State.Arm;
   end Arm_Next_Acquisition_Near_Exhaustion;

   function Consume_Next_Acquisition_Near_Exhaustion return Boolean is
      Armed : Boolean;
   begin
      State.Consume (Armed);
      return Armed;
   end Consume_Next_Acquisition_Near_Exhaustion;

end Flyology.Buffer_Test_Hooks;
