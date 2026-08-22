with Interfaces;

--  Disabled preelaborable wall-clock I/O seams selected by the owning
--  project. Imported-only declarations make a missed static guard visible to
--  symbol inspection without supplying any production implementation.
private package Flyology.Wall_Clock_IO_Testing
  with Preelaborate
is
   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := False;

   procedure Configure (Steady_Nanoseconds : Interfaces.Integer_64; Wall_Nanoseconds : Interfaces.Integer_64)
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_io_configure";
   procedure Reset
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_io_reset";
   function Take_EINTR return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_io_eintr";
   function Steady_Adjustment return Interfaces.Integer_64
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_io_steady";
   function Wall_Adjustment return Interfaces.Integer_64
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_io_wall";
   function Retry_Count return Natural
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_wall_io_retries";
end Flyology.Wall_Clock_IO_Testing;
