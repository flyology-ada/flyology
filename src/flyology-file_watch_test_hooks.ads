--  Test-only file-watch fault checks compiled with Flyology's own switches.
--  The disabled implementation has no native imports or observable effects.
private package Flyology.File_Watch_Test_Hooks is
   function Consume_Events_Lost return Boolean;
   function Consume_Remove_Failure return Boolean;
   function Consume_Close_Failure return Boolean;
end Flyology.File_Watch_Test_Hooks;
