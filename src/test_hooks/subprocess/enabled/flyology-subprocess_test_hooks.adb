package body Flyology.Subprocess_Test_Hooks is
   use type Interfaces.C.int;

   protected Reap_Barrier is
      procedure Set_Signal_Failure (Enabled : Boolean);
      function Signal_Failure return Boolean;
      procedure Arm;
      procedure Reaped;
      entry Await_Reaped;
      entry Await_Release;
      procedure Release;
      procedure Note_Signal;
      function Signal_Count return Interfaces.C.int;
   private
      Armed       : Boolean := False;
      Observed    : Boolean := False;
      Unlocked    : Boolean := False;
      Count       : Interfaces.C.int := 0;
      Fail_Signal : Boolean := False;
   end Reap_Barrier;

   protected body Reap_Barrier is
      procedure Set_Signal_Failure (Enabled : Boolean) is
      begin
         Fail_Signal := Enabled;
      end Set_Signal_Failure;

      function Signal_Failure return Boolean
      is (Fail_Signal);

      procedure Arm is
      begin
         Armed := True;
         Observed := False;
         Unlocked := False;
         Count := 0;
      end Arm;

      procedure Reaped is
      begin
         if Armed then
            Observed := True;
         end if;
      end Reaped;

      entry Await_Reaped when Observed is
      begin
         null;
      end Await_Reaped;

      entry Await_Release when not Armed or Unlocked is
      begin
         Armed := False;
      end Await_Release;

      procedure Release is
      begin
         Unlocked := True;
      end Release;

      procedure Note_Signal is
      begin
         Count := Count + 1;
      end Note_Signal;

      function Signal_Count return Interfaces.C.int
      is (Count);
   end Reap_Barrier;

   function Test_Fail_Reaper_Allocation return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_subprocess_fail_reaper_allocation";

   function Fail_Reaper_Allocation return Boolean
   is (Test_Fail_Reaper_Allocation /= 0);

   function Fail_Group_Signal return Boolean
   is (Reap_Barrier.Signal_Failure);

   procedure Set_Fail_Group_Signal (Enabled : Interfaces.C.int) is
   begin
      Reap_Barrier.Set_Signal_Failure (Enabled /= 0);
   end Set_Fail_Group_Signal;

   procedure After_Reap is
   begin
      Reap_Barrier.Reaped;
      Reap_Barrier.Await_Release;
   end After_Reap;

   procedure Note_Group_Signal is
   begin
      Reap_Barrier.Note_Signal;
   end Note_Group_Signal;

   procedure Arm_Reap_Barrier is
   begin
      Reap_Barrier.Arm;
   end Arm_Reap_Barrier;

   procedure Await_Reap_Barrier is
   begin
      Reap_Barrier.Await_Reaped;
   end Await_Reap_Barrier;

   procedure Release_Reap_Barrier is
   begin
      Reap_Barrier.Release;
   end Release_Reap_Barrier;

   function Group_Signal_Count return Interfaces.C.int
   is (Reap_Barrier.Signal_Count);

end Flyology.Subprocess_Test_Hooks;
