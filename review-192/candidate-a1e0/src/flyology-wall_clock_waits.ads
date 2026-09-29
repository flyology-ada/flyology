with Ada.Calendar;
with Ada.Finalization;
with Interfaces.C;
with Flyology.Wall_Clock_Native;

--  Internal controlled owner of one platform wall-clock readiness source.
--  Linux uses timerfd; Darwin uses a relative kqueue timer, clock-set
--  notification, and bounded wall-clock re-evaluation.

private package Flyology.Wall_Clock_Waits is
   use type Interfaces.C.int;

   --  Unique controlled owner of the descriptors for one active wait.
   type Source is new Ada.Finalization.Limited_Controlled with private;

   --  Allocate the platform source. Repeated calls without finalization are
   --  not supported.
   procedure Open (Item : in out Source);
   --  Arm the wall-clock target or one bounded probe, whichever is earlier.
   --  True means a clock change raced the arm and the caller must classify a
   --  fresh sample without blocking.
   function Arm (Item : in out Source; Target : Ada.Calendar.Time; Maximum_Slice : Duration) return Boolean
   with Pre => Maximum_Slice > 0.0;
   --  Drain one readiness event without taking descriptor ownership.
   procedure Consume (Item : in out Source);
   --  Borrow the descriptor registered with Flyology.IO.
   function Descriptor (Item : Source) return Interfaces.C.int;
   --  Report whether the kernel timer itself cancels on a clock change.
   function Cancels_On_Clock_Set (Item : Source) return Boolean;

private
   type Source is new Ada.Finalization.Limited_Controlled with record
      Native : Flyology.Wall_Clock_Native.Wait_State;
   end record;

   --  Release every owned descriptor without propagating close errors.
   overriding
   procedure Finalize (Item : in out Source);
end Flyology.Wall_Clock_Waits;
