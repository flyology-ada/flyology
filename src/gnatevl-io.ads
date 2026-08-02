with Interfaces.C;

package Gnatevl.IO with Preelaborate is

   Infinite : constant Duration := -1.0;

   Timeout_Error : exception;
   Device_Error  : exception;

   subtype Descriptor is Interfaces.C.int;
   Invalid_Descriptor : constant Descriptor := Interfaces.C.int (-1);
   type Wait_Kind is (For_Read, For_Write);
   type Wait_Outcome is (Ready, Timed_Out, Interrupted);

   type Wait_Request is record
      FD        : Descriptor;
      Condition : Wait_Kind;
   end record;
   type Wait_Request_Array is array (Positive range <>) of Wait_Request;

   --  Upper bound chosen for predictable, allocation-free registration in
   --  both the public library and the patched runtime.  Callers can split
   --  larger sets across owning tasks instead of making each fiber carry an
   --  unbounded descriptor vector.
   Max_Wait_Requests : constant := 32;

   function Is_Evented_Task return Boolean;

   --  Wait until Descriptor is ready. False denotes timeout. Event-loop
   --  tasks suspend cooperatively; designated native tasks use poll(2).
   function Wait
     (FD        : Descriptor;
      Condition : Wait_Kind;
      Timeout   : Duration := Infinite) return Boolean;

   --  Wait until any requested descriptor is ready.  The return value is the
   --  exact index in Requests, or 0 on timeout.  Duplicate descriptors and a
   --  read/write pair for the same descriptor are supported.  No descriptor
   --  is read, closed, or otherwise consumed by this operation.
   function Wait_Any
     (Requests : Wait_Request_Array;
      Timeout  : Duration := Infinite) return Natural
     with Pre => Requests'Length <= Max_Wait_Requests;

   --  Wait for Descriptor or any optional one-shot interrupt source.
   --  Interrupt descriptors are observed for readability and are not read or
   --  closed here. This is the low-level primitive used by cancellable
   --  connection operations.
   function Wait_Interruptibly
     (FD          : Descriptor;
      Condition   : Wait_Kind;
      Timeout     : Duration := Infinite;
      Interrupt_1 : Descriptor := Invalid_Descriptor;
      Interrupt_2 : Descriptor := Invalid_Descriptor;
      Interrupt_3 : Descriptor := Invalid_Descriptor) return Wait_Outcome;

end Gnatevl.IO;
