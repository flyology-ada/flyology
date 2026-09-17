package body Flyology.Subprocess_Test_Hooks is
   use type Interfaces.C.int;

   protected Hooks is
      procedure Set_Allocation_Failure (Enabled : Boolean);
      function Allocation_Failure return Boolean;
      procedure Set_Signal_Failure (Enabled : Boolean);
      function Signal_Failure return Boolean;
      procedure Note_Signal;
      function Signal_Count return Interfaces.C.int;
   private
      Count           : Interfaces.C.int := 0;
      Fail_Allocation : Boolean := False;
      Fail_Signal     : Boolean := False;
   end Hooks;

   protected body Hooks is
      procedure Set_Allocation_Failure (Enabled : Boolean) is
      begin
         Fail_Allocation := Enabled;
      end Set_Allocation_Failure;

      function Allocation_Failure return Boolean
      is (Fail_Allocation);

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
   end Hooks;

   function Fail_Reaper_Allocation return Boolean
   is (Hooks.Allocation_Failure);

   procedure Set_Fail_Reaper_Allocation (Enabled : Interfaces.C.int) is
   begin
      Hooks.Set_Allocation_Failure (Enabled /= 0);
   end Set_Fail_Reaper_Allocation;

   function Fail_Group_Signal return Boolean
   is (Hooks.Signal_Failure);

   procedure Set_Fail_Group_Signal (Enabled : Interfaces.C.int) is
   begin
      Hooks.Set_Signal_Failure (Enabled /= 0);
   end Set_Fail_Group_Signal;

   procedure Note_Group_Signal is
   begin
      Hooks.Note_Signal;
   end Note_Group_Signal;

   function Group_Signal_Count return Interfaces.C.int
   is (Hooks.Signal_Count);

end Flyology.Subprocess_Test_Hooks;
