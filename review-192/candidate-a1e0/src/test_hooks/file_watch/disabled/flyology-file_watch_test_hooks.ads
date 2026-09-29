--  Disabled file-watch test seams selected by the owning project. The
--  imported-only declarations make a missed static guard visible to symbol
--  inspection without supplying any production implementation.
private package Flyology.File_Watch_Test_Hooks is

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := False;

   function Consume_Events_Lost return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_file_watch_events";
   function Consume_Remove_Failure return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_file_watch_remove";
   function Consume_Close_Failure return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_file_watch_close";

end Flyology.File_Watch_Test_Hooks;
