with Interfaces.C;

package System.Gnatevl.Poller is
   pragma Preelaborate;

   type Poller is limited private;

   function Initialize (Item : in out Poller) return Boolean;
   procedure Finalize (Item : in out Poller);

   --  A negative timeout waits indefinitely. The result is false on error.
   function Wait
     (Item                : Poller;
      Timeout             : Duration) return Boolean;

   --  Safe to invoke from a designated native thread.
   function Wake (Item : Poller) return Boolean;

private
   type Poller is limited record
      Descriptor : Interfaces.C.int := Interfaces.C.int (-1);
   end record;
end System.Gnatevl.Poller;
