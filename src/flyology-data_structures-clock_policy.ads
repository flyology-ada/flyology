with Interfaces;
with Interfaces.C;

--  Proved scalar conversion for the native monotonic-clock sample. The
--  clock_gettime import and its target-specific clock id remain in Waits;
--  this package validates and converts the sample without depending on native
--  addresses or permitting either arithmetic operation to wrap.
private package Flyology.Data_Structures.Clock_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   package C renames Interfaces.C;

   use type C.int;
   use type C.long;
   use type Interfaces.Unsigned_64;

   Nanoseconds_Per_Second : constant Interfaces.Unsigned_64 := 1_000_000_000;
   Clock_Failure          : constant Interfaces.Unsigned_64 :=
     Interfaces.Unsigned_64'Last;
   Maximum_Clock_Seconds  : constant Interfaces.Unsigned_64 :=
     Interfaces.Unsigned_64'Last / Nanoseconds_Per_Second;
   Maximum_Final_Nanoseconds : constant Interfaces.Unsigned_64 :=
     Interfaces.Unsigned_64'Last rem Nanoseconds_Per_Second;

   --  Convert one clock_gettime outcome. A failed call, malformed timespec,
   --  or sample whose exact nanosecond value exceeds Unsigned_64 returns
   --  Clock_Failure.
   function To_Nanoseconds
     (Status      : C.int;
      Seconds     : C.long;
      Nanoseconds : C.long) return Interfaces.Unsigned_64
   with Global => null,
        Post   =>
          To_Nanoseconds'Result =
            (if Status /= 0
                 or else Seconds < 0
                 or else Nanoseconds < 0
                 or else Nanoseconds >= C.long (Nanoseconds_Per_Second)
                 or else Interfaces.Unsigned_64 (Seconds) >
                   Maximum_Clock_Seconds
                 or else
                   (Interfaces.Unsigned_64 (Seconds) = Maximum_Clock_Seconds
                    and then Interfaces.Unsigned_64 (Nanoseconds) >
                      Maximum_Final_Nanoseconds)
             then Clock_Failure
             else Interfaces.Unsigned_64 (Seconds)
               * Nanoseconds_Per_Second
               + Interfaces.Unsigned_64 (Nanoseconds));
end Flyology.Data_Structures.Clock_Policy;
