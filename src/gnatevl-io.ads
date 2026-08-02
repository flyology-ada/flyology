with Interfaces.C;

package Gnatevl.IO with Preelaborate is

   Infinite : constant Duration := -1.0;

   Timeout_Error : exception;
   Device_Error  : exception;

   subtype Descriptor is Interfaces.C.int;
   Invalid_Descriptor : constant Descriptor := Interfaces.C.int (-1);
   type Wait_Kind is (For_Read, For_Write);
   type Wait_Outcome is (Ready, Timed_Out, Interrupted);

   function Is_Evented_Task return Boolean;

   --  Wait until Descriptor is ready. False denotes timeout. Event-loop
   --  tasks suspend cooperatively; designated native tasks use poll(2).
   function Wait
     (FD        : Descriptor;
      Condition : Wait_Kind;
      Timeout   : Duration := Infinite) return Boolean;

   --  Wait for Descriptor or either optional one-shot interrupt source.
   --  Interrupt descriptors are observed for readability and are not read or
   --  closed here. This is the low-level primitive used by cancellable
   --  connection operations.
   function Wait_Interruptibly
     (FD          : Descriptor;
      Condition   : Wait_Kind;
      Timeout     : Duration := Infinite;
      Interrupt_1 : Descriptor := Invalid_Descriptor;
      Interrupt_2 : Descriptor := Invalid_Descriptor) return Wait_Outcome;

end Gnatevl.IO;
