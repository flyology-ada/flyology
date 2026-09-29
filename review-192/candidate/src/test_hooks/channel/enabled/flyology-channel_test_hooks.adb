package body Flyology.Channel_Test_Hooks is

   Armed   : Boolean := False
   with Atomic;
   Arrived : Boolean := False
   with Atomic;

   procedure Reset is
   begin
      Armed := False;
      Arrived := False;
   end Reset;

   procedure Arm_Before_Send is
   begin
      Arrived := False;
      Armed := True;
   end Arm_Before_Send;

   procedure Before_Send_Barrier is
   begin
      if Armed then
         Arrived := True;
         while Armed loop
            delay 0.0;
         end loop;
      end if;
   end Before_Send_Barrier;

   function Before_Send_Reached return Boolean
   is (Arrived);

   procedure Release_Before_Send is
   begin
      Armed := False;
   end Release_Before_Send;

end Flyology.Channel_Test_Hooks;
