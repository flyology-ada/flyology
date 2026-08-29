with Ada.Real_Time;
with Flyology.Channel_Test_Hooks;

package body Flyology.Channel_Testing is

   use type Ada.Real_Time.Time;

   procedure Reset is
   begin
      Flyology.Channel_Test_Hooks.Reset;
   end Reset;

   procedure Arm_Before_Send is
   begin
      Flyology.Channel_Test_Hooks.Arm_Before_Send;
   end Arm_Before_Send;

   procedure Wait_Before_Send is
      Deadline : constant Ada.Real_Time.Time := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
   begin
      while not Flyology.Channel_Test_Hooks.Before_Send_Reached loop
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "channel before-send barrier was not reached";
         end if;
         delay 0.001;
      end loop;
   end Wait_Before_Send;

   procedure Release_Before_Send is
   begin
      Flyology.Channel_Test_Hooks.Release_Before_Send;
   end Release_Before_Send;

end Flyology.Channel_Testing;
