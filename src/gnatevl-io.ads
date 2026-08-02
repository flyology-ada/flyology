with Interfaces.C;

package Gnatevl.IO with Preelaborate is

   Infinite : constant Duration := -1.0;

   Timeout_Error : exception;
   Device_Error  : exception;

   subtype Descriptor is Interfaces.C.int;
   type Wait_Kind is (For_Read, For_Write);

   function Is_Evented_Task return Boolean;

   --  Wait until Descriptor is ready. False denotes timeout. Event-loop
   --  tasks suspend cooperatively; designated native tasks use poll(2).
   function Wait
     (FD        : Descriptor;
      Condition : Wait_Kind;
      Timeout   : Duration := Infinite) return Boolean;

end Gnatevl.IO;
