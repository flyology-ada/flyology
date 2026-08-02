with Interfaces.C;

package System.Gnatevl.File_Engine is
   pragma Preelaborate;

   type Engine is limited private;

   type Completion is record
      Token      : System.Address := System.Null_Address;
      Result     : Interfaces.C.long_long := 0;
      Error_Code : Interfaces.C.int := 0;
   end record;

   type Completion_Array is array (Positive range <>) of Completion;

   type Cancellation_Disposition is
     (Cancellation_Submitted,
      Already_Completing,
      Not_Cancelable,
      Cancellation_Failed);

   function Initialize
     (Item      : in out Engine;
      Poller_FD : Interfaces.C.int;
      Wake_FD   : Interfaces.C.int) return Boolean;

   procedure Finalize (Item : in out Engine);

   function Submit
     (Item        : in out Engine;
      Descriptor  : Interfaces.C.int;
      Buffer      : System.Address;
      Length      : Interfaces.C.size_t;
      Offset      : Interfaces.C.long_long;
      For_Write   : Boolean;
      Token       : System.Address;
      Error_Code  : out Interfaces.C.int) return Boolean;

   --  Ask the kernel to cancel the operation identified by Token. A submitted
   --  cancellation is not itself terminal: callers must continue retaining
   --  the buffer until the ordinary completion is delivered. Native Linux
   --  AIO is the exception because io_cancel returns the terminal event
   --  directly; Has_Completion reports that safe-to-resume case.
   function Cancel
     (Item           : in out Engine;
      Descriptor     : Interfaces.C.int;
      Token          : System.Address;
      Value          : out Completion;
      Has_Completion : out Boolean;
      Error_Code     : out Interfaces.C.int)
      return Cancellation_Disposition;

   --  Darwin completes one AIO request from the payload carried by kevent64.
   --  Other platforms return False because they drain their own completion
   --  queue instead.
   function Complete_Event
     (Item            : in out Engine;
      Request_Address : System.Address;
      Kernel_Result   : Interfaces.C.long_long;
      Kernel_Error    : Interfaces.C.int;
      Value           : out Completion) return Boolean;

   --  Linux drains io_uring or native-AIO completions. Darwin returns an
   --  empty batch because its completions are delivered directly by kqueue.
   function Drain
     (Item   : in out Engine;
      Values : out Completion_Array;
      Count  : out Natural) return Boolean
   with Post => Count <= Values'Length;

private
   type Engine is limited record
      State : System.Address := System.Null_Address;
   end record;
end System.Gnatevl.File_Engine;
