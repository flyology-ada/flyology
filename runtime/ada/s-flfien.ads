with Interfaces.C;

package System.Flyology.File_Engine is
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

   type Event_Completion_Disposition is
     (Completion_Produced,
      Completion_Ignored,
      Completion_Failed);

   function Initialize
     (Item      : in out Engine;
      Poller_FD : Interfaces.C.int;
      Wake_FD   : Interfaces.C.int) return Boolean;

   procedure Finalize (Item : in out Engine);

   --  True when this platform engine can submit an asynchronous zero-copy
   --  socket send and retain its buffer through the reuse notification.
   function Supports_Send_ZC (Item : Engine) return Boolean;

   --  False with EAGAIN denotes temporary kernel queue pressure and is safe
   --  for the owning scheduler to retry without releasing Buffer. Linux also
   --  normalizes io_uring EBUSY to this retry contract.
   function Submit
     (Item        : in out Engine;
      Descriptor  : Interfaces.C.int;
      Buffer      : System.Address;
      Length      : Interfaces.C.size_t;
      Offset      : Interfaces.C.long_long;
      For_Write   : Boolean;
      Token       : System.Address;
      Error_Code  : out Interfaces.C.int) return Boolean;

   --  Enqueue one socket send whose buffer remains kernel-owned until the
   --  terminal completion. False with EAGAIN has the same queue-pressure
   --  meaning as Submit. False with another error means no request owns
   --  Buffer. Call only when Supports_Send_ZC is true.
   function Submit_Send_ZC
     (Item        : in out Engine;
      Descriptor  : Interfaces.C.int;
      Buffer      : System.Address;
      Length      : Interfaces.C.size_t;
      Token       : System.Address;
      Error_Code  : out Interfaces.C.int) return Boolean;

   --  Ask the kernel to cancel the operation identified by Token. A submitted
   --  cancellation is not normally terminal: callers continue retaining the
   --  buffer until ordinary completion, and Has_Completion identifies the
   --  exception. Darwin AIO_CANCELED is reaped with aio_return here and is
   --  currently the only backend that produces one. Linux io_uring answers
   --  through its administrative CQE, and native Linux AIO reports the
   --  positional read and write opcodes this engine submits as not-cancelable
   --  because io_cancel(2) has had no cancel handler for them since kernel
   --  3.11; both keep the buffer until the ordinary completion arrives. Only
   --  the owning event-loop thread may call this operation.
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
      Value           : out Completion) return Event_Completion_Disposition;

   --  True when the engine has no kernel-owned operation or administrative
   --  completion that must be drained before its poller can be destroyed.
   --  Darwin quarantine entries are terminal and remain owned by the poller,
   --  so they do not prevent quiescence.
   function Is_Quiescent (Item : Engine) return Boolean;

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
end System.Flyology.File_Engine;
