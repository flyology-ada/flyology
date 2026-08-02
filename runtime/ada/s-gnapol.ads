with Interfaces.C;

package System.Gnatevl.Poller is
   pragma Preelaborate;

   type Poller is limited private;
   type Interest is (Readable, Writable);
   type Event_Kind is
     (Wake_Event, Readable_Event, Writable_Event, Timeout_Event);

   type Poll_Event is record
      Kind       : Event_Kind := Timeout_Event;
      Descriptor : Interfaces.C.int := Interfaces.C.int (-1);
   end record;

   type Poll_Event_Array is array (Positive range <>) of Poll_Event;

   function Initialize (Item : in out Poller) return Boolean;
   procedure Finalize (Item : in out Poller);

   --  Arm a one-shot readiness notification for Descriptor.
   function Watch
     (Item       : Poller;
      Descriptor : Interfaces.C.int;
      Condition  : Interest) return Boolean;

   --  A negative timeout waits indefinitely. The result is false on error.
   function Wait
     (Item                : Poller;
      Timeout             : Duration;
      Event               : out Poll_Event) return Boolean;

   --  Collect up to Events'Length notifications in one kernel call. Count is
   --  zero for a timeout or an interrupted wait. The result is false only for
   --  a real poller error.
   function Wait_Batch
     (Item                : Poller;
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
   end record;
end System.Gnatevl.Poller;
