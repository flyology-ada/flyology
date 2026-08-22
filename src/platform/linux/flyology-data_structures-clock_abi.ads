with Interfaces.C;

--  Target constants used by the data-structure monotonic-clock import.

private package Flyology.Data_Structures.Clock_ABI
  with Preelaborate
is
   --  clockid_t is C int and <time.h> defines CLOCK_MONOTONIC as 1 on Linux.
   Clock_Monotonic : constant Interfaces.C.int := 1;
end Flyology.Data_Structures.Clock_ABI;
