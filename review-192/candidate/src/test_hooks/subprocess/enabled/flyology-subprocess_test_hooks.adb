with Interfaces.C;

package body Flyology.Subprocess_Test_Hooks is
   use type Interfaces.C.int;

   function Test_Fail_Reaper_Allocation return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_subprocess_fail_reaper_allocation";

   function Fail_Reaper_Allocation return Boolean
   is (Test_Fail_Reaper_Allocation /= 0);

end Flyology.Subprocess_Test_Hooks;
