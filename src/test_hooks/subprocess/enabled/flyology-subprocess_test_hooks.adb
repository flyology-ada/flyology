package body Flyology.Subprocess_Test_Hooks is
   use type Interfaces.C.int;

   protected Signal_Hooks is
      procedure Set_Signal_Failure (Enabled : Boolean);
      function Signal_Failure return Boolean;
      procedure Note_Signal;
      function Signal_Count return Interfaces.C.int;
   private
      Count       : Interfaces.C.int := 0;
      Fail_Signal : Boolean := False;
   end Signal_Hooks;

   protected body Signal_Hooks is
      procedure Set_Signal_Failure (Enabled : Boolean) is
      begin
         Fail_Signal := Enabled;
      end Set_Signal_Failure;

      function Signal_Failure return Boolean
      is (Fail_Signal);

      procedure Note_Signal is
      begin
         Count := Count + 1;
      end Note_Signal;

      function Signal_Count return Interfaces.C.int
      is (Count);
   end Signal_Hooks;

   function Test_Fail_Reaper_Allocation return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_subprocess_fail_reaper_allocation";

   function Fail_Reaper_Allocation return Boolean
   is (Test_Fail_Reaper_Allocation /= 0);

   function Fail_Group_Signal return Boolean
   is (Signal_Hooks.Signal_Failure);

   procedure Set_Fail_Group_Signal (Enabled : Interfaces.C.int) is
   begin
      Signal_Hooks.Set_Signal_Failure (Enabled /= 0);
   end Set_Fail_Group_Signal;

   procedure Note_Group_Signal is
   begin
      Signal_Hooks.Note_Signal;
   end Note_Group_Signal;

   function Group_Signal_Count return Interfaces.C.int
   is (Signal_Hooks.Signal_Count);

end Flyology.Subprocess_Test_Hooks;
