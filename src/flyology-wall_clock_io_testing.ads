with Interfaces;

--  Preelaborable lock-free state for the native poll EINTR test seam. The
--  production IO body has no dependency when wall-clock hooks are disabled.
private package Flyology.Wall_Clock_IO_Testing
  with Preelaborate
is
   procedure Configure
     (Steady_Nanoseconds : Interfaces.Integer_64;
      Wall_Nanoseconds   : Interfaces.Integer_64);
   procedure Reset;
   function Take_EINTR return Boolean;
   function Steady_Adjustment return Interfaces.Integer_64;
   function Wall_Adjustment return Interfaces.Integer_64;
   function Retry_Count return Natural;
end Flyology.Wall_Clock_IO_Testing;
