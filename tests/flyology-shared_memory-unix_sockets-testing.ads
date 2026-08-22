--  Test-only observations for the owned handoff-channel guard. This unit is
--  built only into the runtime smoke-test archive.

package Flyology.Shared_Memory.Unix_Sockets.Testing is
   function Is_Busy (Item : Handoff_Channel) return Boolean;
end Flyology.Shared_Memory.Unix_Sockets.Testing;
