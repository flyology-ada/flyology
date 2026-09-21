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
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
   begin
      while not Flyology.Channel_Test_Hooks.Before_Send_Reached loop
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error
              with "channel before-send barrier was not reached";
         end if;
         delay 0.001;
      end loop;
   end Wait_Before_Send;

   procedure Release_Before_Send is
   begin
      Flyology.Channel_Test_Hooks.Release_Before_Send;
   end Release_Before_Send;

   procedure Arm_After_Buffer_Commit is
   begin
      Flyology.Channel_Test_Hooks.Arm_After_Buffer_Commit;
   end Arm_After_Buffer_Commit;

   procedure Wait_After_Buffer_Commit is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
   begin
      while not Flyology.Channel_Test_Hooks.Buffer_Commit_Reached loop
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error
              with "buffer channel commit barrier was not reached";
         end if;
         delay 0.001;
      end loop;
   end Wait_After_Buffer_Commit;

   procedure Release_After_Buffer_Commit is
   begin
      Flyology.Channel_Test_Hooks.Release_After_Buffer_Commit;
   end Release_After_Buffer_Commit;

   procedure Arm_After_Signal_Claim is
   begin
      Flyology.Channel_Test_Hooks.Arm_After_Signal_Claim;
   end Arm_After_Signal_Claim;

   procedure Wait_After_Signal_Claim is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
   begin
      while not Flyology.Channel_Test_Hooks.Signal_Claim_Reached loop
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error
              with "buffer channel signal claim barrier was not reached";
         end if;
         delay 0.001;
      end loop;
   end Wait_After_Signal_Claim;

   procedure Release_After_Signal_Claim is
   begin
      Flyology.Channel_Test_Hooks.Release_After_Signal_Claim;
   end Release_After_Signal_Claim;

   function Signal_Claim_Was_Released return Boolean
   is (Flyology.Channel_Test_Hooks.Signal_Claim_Was_Released);

   procedure Arm_Next_Buffer_Signal_Failure is
   begin
      Flyology.Channel_Test_Hooks.Arm_Next_Buffer_Signal_Failure;
   end Arm_Next_Buffer_Signal_Failure;

   procedure Arm_Next_Bounded_Signal_Interrupt is
   begin
      Flyology.Channel_Test_Hooks.Arm_Next_Bounded_Signal_Interrupt;
   end Arm_Next_Bounded_Signal_Interrupt;

   function Bounded_Signal_Interrupt_Observed return Boolean
   is (Flyology.Channel_Test_Hooks.Bounded_Signal_Interrupt_Observed);

   procedure Arm_Next_Bounded_Signal_Failure is
   begin
      Flyology.Channel_Test_Hooks.Arm_Next_Bounded_Signal_Failure;
   end Arm_Next_Bounded_Signal_Failure;

   function Bounded_Signal_Failure_Observed return Boolean
   is (Flyology.Channel_Test_Hooks.Bounded_Signal_Failure_Observed);

   procedure Arm_After_Bounded_Failure_Ack is
   begin
      Flyology.Channel_Test_Hooks.Arm_After_Bounded_Failure_Ack;
   end Arm_After_Bounded_Failure_Ack;

   procedure Wait_After_Bounded_Failure_Ack is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
   begin
      while not Flyology.Channel_Test_Hooks.Bounded_Failure_Ack_Reached loop
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error
              with "bounded channel failed-ack barrier was not reached";
         end if;
         delay 0.001;
      end loop;
   end Wait_After_Bounded_Failure_Ack;

   procedure Release_After_Bounded_Failure_Ack is
   begin
      Flyology.Channel_Test_Hooks.Release_After_Bounded_Failure_Ack;
   end Release_After_Bounded_Failure_Ack;

end Flyology.Channel_Testing;
