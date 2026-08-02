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
