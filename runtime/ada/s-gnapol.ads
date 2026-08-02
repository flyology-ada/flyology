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

   --  Safe to invoke from a designated native thread.
   function Wake (Item : Poller) return Boolean;

private
   type Poller is limited record
      Descriptor : Interfaces.C.int := Interfaces.C.int (-1);
   end record;
end System.Gnatevl.Poller;
