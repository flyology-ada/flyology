#if FLYOLOGY_FILE_WATCH_TEST_HOOKS then
with Interfaces.C;
#end if;

package body Flyology.File_Watch_Test_Hooks is
#if FLYOLOGY_FILE_WATCH_TEST_HOOKS then
   use type Interfaces.C.int;

   function Test_Events_Lost return Interfaces.C.int
     with Import,
          Convention    => C,
          External_Name => "flyology_test_file_watch_events_lost";
   function Test_Remove_Failure return Interfaces.C.int
     with Import,
          Convention    => C,
          External_Name => "flyology_test_file_watch_remove_failure";
   function Test_Close_Failure return Interfaces.C.int
     with Import,
          Convention    => C,
          External_Name => "flyology_test_file_watch_close_failure";

   function Consume_Events_Lost return Boolean is (Test_Events_Lost /= 0);
   function Consume_Remove_Failure return Boolean is
     (Test_Remove_Failure /= 0);
   function Consume_Close_Failure return Boolean is
     (Test_Close_Failure /= 0);
#else
   function Consume_Events_Lost return Boolean is (False);
   function Consume_Remove_Failure return Boolean is (False);
   function Consume_Close_Failure return Boolean is (False);
#end if;
end Flyology.File_Watch_Test_Hooks;
