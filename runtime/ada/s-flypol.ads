with Interfaces.C;
with System.Flyology.File_Engine;
with System.Flyology.Poller_Policy;

package System.Flyology.Poller is
   pragma Preelaborate;

   type Poller is limited private;
   type Interest is (Readable, Writable);
   type Interest_Request is record
      Descriptor : Interfaces.C.int;
      Condition  : Interest;
   end record;
   type Interest_Request_Array is array (Positive range <>) of Interest_Request;
   type Event_Kind is
     (Wake_Event, Readable_Event, Writable_Event, Read_Write_Event, File_Event, Timeout_Event);

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
   function Watch (Item : in out Poller; Descriptor : Interfaces.C.int; Condition : Interest) return Boolean;

   --  Arm one-shot readiness notifications as one logical operation. Success
   --  means every request is armed. A failure may leave an earlier request
   --  armed, so the caller must pass the complete set to Cancel_Many before
   --  releasing its scheduler state. Repeated pairs are permitted.
   function Watch_Many (Item : in out Poller; Requests : Interest_Request_Array) return Boolean
   with Pre => Requests'Length > 0;

   --  Roll back an armed interest that has no scheduler waiters. This is used
   --  transactionally when a later member of a multi-source wait cannot arm,
   --  and again whenever the scheduler removes a waiter that still owns
   --  one-shot interests. It is idempotent: an interest the kernel already
   --  consumed, and a descriptor whose owner closed it while the interest was
   --  armed, both report success because nothing remains to cancel. False is
   --  reserved for a genuinely broken poller, which the scheduler treats as
   --  fatal.
   function Cancel (Item : in out Poller; Descriptor : Interfaces.C.int; Condition : Interest) return Boolean;

   --  Clear every requested interest, including after a descriptor close or
   --  an already-consumed one-shot event. All requests are attempted even if
   --  one reports a hard poller failure.
   function Cancel_Many (Item : in out Poller; Requests : Interest_Request_Array) return Boolean
   with Pre => Requests'Length > 0;

   --  Report whether an armed one-shot interest may remain after its last
   --  scheduler waiter detaches. Such an interest can produce at most one
   --  unmatched readiness hint and is removed by descriptor close. Platforms
   --  with process-side registration records return False so detachment also
   --  releases that bookkeeping.
   function Retains_Orphaned_One_Shots return Boolean;

   --  Enqueue positional file I/O and arrange for a File_Event carrying Token
   --  to be returned by Wait_Batch. The buffer must remain valid until that
   --  completion is delivered.
   function Submit_File
     (Item       : in out Poller;
      Descriptor : Interfaces.C.int;
      Buffer     : System.Address;
      Length     : Interfaces.C.size_t;
      Offset     : Interfaces.C.long_long;
      For_Write  : Boolean;
      Token      : System.Address;
      Error_Code : out Interfaces.C.int) return Boolean;

   --  Report whether the poller's completion engine supports a terminal
   --  zero-copy socket send.
   function Supports_Send_ZC (Item : Poller) return Boolean;

   --  Enqueue a zero-copy socket send and arrange for one terminal File_Event
   --  after the kernel no longer owns Buffer.
   function Submit_Send_ZC
     (Item       : in out Poller;
      Descriptor : Interfaces.C.int;
      Buffer     : System.Address;
      Length     : Interfaces.C.size_t;
      Token      : System.Address;
      Error_Code : out Interfaces.C.int) return Boolean;

   --  Invoke the platform cancellation backend. The scheduler calls this
   --  only from the event-loop thread that owns Item.File_State.
   function Cancel_File
     (Item           : in out Poller;
      Descriptor     : Interfaces.C.int;
      Token          : System.Address;
      Value          : out System.Flyology.File_Engine.Completion;
      Has_Completion : out Boolean;
      Error_Code     : out Interfaces.C.int) return System.Flyology.File_Engine.Cancellation_Disposition;

   --  True when no file operation or cancellation completion still belongs
   --  to the kernel. Terminal Darwin quarantine records are released when the
   --  poller is destroyed and do not keep an otherwise idle group alive.
   function File_Quiescent (Item : Poller) return Boolean;

   --  A negative timeout waits indefinitely. The result is false on error.
   function Wait (Item : in out Poller; Timeout : Duration; Event : out Poll_Event) return Boolean;

   --  Collect up to Events'Length notifications in one kernel call. Count is
   --  zero for a timeout or an interrupted wait. The result is false only for
   --  a real poller error.
   function Wait_Batch
     (Item : in out Poller; Timeout : Duration; Events : out Poll_Event_Array; Count : out Natural)
      return Boolean
   with
     Pre  => Events'Length in 1 .. System.Flyology.Poller_Policy.Max_Batch_Capacity,
     Post => Count <= Events'Length;

   --  Safe to invoke from a designated native thread.
   function Wake (Item : Poller) return Boolean;

private
   type Poller is limited record
      Descriptor       : Interfaces.C.int := Interfaces.C.int (-1);
      Wake_Descriptor  : Interfaces.C.int := Interfaces.C.int (-1);
      State            : System.Address := System.Null_Address;
      File_State       : System.Flyology.File_Engine.Engine;
      --  Linux retains a drain obligation after consuming the shared eventfd.
      --  A one-result caller alternates sources while that obligation remains.
      File_Drain_State : System.Flyology.Poller_Policy.Drain_State;
   end record;
end System.Flyology.Poller;
