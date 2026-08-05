with Interfaces.C;
with System.Flyology.File_Engine;

package System.Flyology.Poller is
   pragma Preelaborate;

   type Poller is limited private;
   type Interest is (Readable, Writable);
   type Event_Kind is
     (Wake_Event,
      Readable_Event,
      Writable_Event,
      Read_Write_Event,
      File_Event,
      Timeout_Event);

   type Poll_Event is record
      Kind       : Event_Kind := Timeout_Event;
      Descriptor : Interfaces.C.int := Interfaces.C.int (-1);
      Token      : System.Address := System.Null_Address;
      Result     : Interfaces.C.long_long := 0;
      Error_Code : Interfaces.C.int := 0;
   end record;

   type Poll_Event_Array is array (Positive range <>) of Poll_Event;

   function Initialize (Item : in out Poller) return Boolean;
   procedure Finalize (Item : in out Poller);

   --  Arm a one-shot readiness notification for Descriptor.
   function Watch
     (Item       : in out Poller;
      Descriptor : Interfaces.C.int;
      Condition  : Interest) return Boolean;

   --  Roll back an armed interest that has no scheduler waiters. This is used
   --  transactionally when a later member of a multi-source wait cannot arm.
   function Cancel
     (Item       : in out Poller;
      Descriptor : Interfaces.C.int;
      Condition  : Interest) return Boolean;

   --  Enqueue positional file I/O and arrange for a File_Event carrying Token
   --  to be returned by Wait_Batch. The buffer must remain valid until that
   --  completion is delivered.
   function Submit_File
     (Item        : in out Poller;
      Descriptor  : Interfaces.C.int;
      Buffer      : System.Address;
      Length      : Interfaces.C.size_t;
      Offset      : Interfaces.C.long_long;
      For_Write   : Boolean;
      Token       : System.Address;
      Error_Code  : out Interfaces.C.int) return Boolean;

   --  Invoke the platform cancellation backend. The scheduler calls this
   --  only from the event-loop thread that owns Item.File_State.
   function Cancel_File
     (Item           : in out Poller;
      Descriptor     : Interfaces.C.int;
      Token          : System.Address;
      Value          : out System.Flyology.File_Engine.Completion;
      Has_Completion : out Boolean;
      Error_Code     : out Interfaces.C.int)
      return System.Flyology.File_Engine.Cancellation_Disposition;

   --  True when no file operation or cancellation completion still belongs
   --  to the kernel. Terminal Darwin quarantine records are released when the
   --  poller is destroyed and do not keep an otherwise idle group alive.
   function File_Quiescent (Item : Poller) return Boolean;

   --  A negative timeout waits indefinitely. The result is false on error.
   function Wait
     (Item                : in out Poller;
      Timeout             : Duration;
      Event               : out Poll_Event) return Boolean;

   --  Collect up to Events'Length notifications in one kernel call. Count is
   --  zero for a timeout or an interrupted wait. The result is false only for
   --  a real poller error.
   function Wait_Batch
     (Item                : in out Poller;
      Timeout             : Duration;
      Events              : out Poll_Event_Array;
      Count               : out Natural) return Boolean
   with Pre => Events'Length in 1 .. Natural (Interfaces.C.int'Last),
        Post => Count <= Events'Length;

   --  Safe to invoke from a designated native thread.
   function Wake (Item : Poller) return Boolean;

private
   type Poller is limited record
      Descriptor : Interfaces.C.int := Interfaces.C.int (-1);
      Wake_Descriptor : Interfaces.C.int := Interfaces.C.int (-1);
      State : System.Address := System.Null_Address;
      File_State : System.Flyology.File_Engine.Engine;
      --  Linux retains a drain obligation after consuming the shared eventfd.
      --  A one-result caller alternates sources while that obligation remains.
      File_Drain_Pending : Boolean := False;
      File_Only_Last_Batch : Boolean := False;
   end record;
end System.Flyology.Poller;
