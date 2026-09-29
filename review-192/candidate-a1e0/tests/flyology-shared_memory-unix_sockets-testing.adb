package body Flyology.Shared_Memory.Unix_Sockets.Testing is
   function Is_Busy (Item : Handoff_Channel) return Boolean
   is (Item.Owner.Controller.Busy_Now);
end Flyology.Shared_Memory.Unix_Sockets.Testing;
