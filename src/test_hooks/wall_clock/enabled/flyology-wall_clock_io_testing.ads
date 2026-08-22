with Interfaces;

--  Preelaborable lock-free state for the native poll EINTR test seam. The
--  production IO body retains no code reference when hooks are disabled.

private package Flyology.Wall_Clock_IO_Testing
  with Preelaborate
is
   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := True;

   procedure Configure (Steady_Nanoseconds : Interfaces.Integer_64; Wall_Nanoseconds : Interfaces.Integer_64);
   procedure Reset;
   function Take_EINTR return Boolean;
   function Steady_Adjustment return Interfaces.Integer_64;
   function Wall_Adjustment return Interfaces.Integer_64;
   function Retry_Count return Natural;
end Flyology.Wall_Clock_IO_Testing;
