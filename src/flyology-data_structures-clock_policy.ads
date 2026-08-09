with Interfaces;
with Interfaces.C;

--  Proved scalar conversion for the native monotonic-clock sample. The
--  clock_gettime import and its target-specific clock id remain in Waits;
--  this package preserves the former C bridge's exact validation, sentinel,
--  and unsigned-wrap behavior without depending on native addresses.
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

   --  Convert one clock_gettime outcome exactly as the former C bridge did.
   --  A failed call or malformed timespec returns Clock_Failure. For a valid
   --  sample, Interfaces.Unsigned_64 arithmetic deliberately preserves C's
   --  modulo semantics, including wrap in the final nanosecond addition.
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
                   Interfaces.Unsigned_64'Last / Nanoseconds_Per_Second
             then Clock_Failure
             else Interfaces.Unsigned_64 (Seconds)
               * Nanoseconds_Per_Second
               + Interfaces.Unsigned_64 (Nanoseconds));
end Flyology.Data_Structures.Clock_Policy;
