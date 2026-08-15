with Ada.Real_Time;

--  Private monotonic-deadline and lane-aware yielding policy for explicitly
--  waiting data-structure operations. No task or timer starts at elaboration.
private package Flyology_Allocators.Waits is
   type Context is private;

   function Start (Timeout : Wait_Timeout) return Context;

   --  Raise Timeout_Error if the deadline has expired; otherwise yield the
   --  calling Ada task once through the selected Ada runtime's delay support.
   procedure Retry (Item : in out Context);

   pragma Inline_Always (Start);

private
   type Context is record
      Timeout  : Wait_Timeout := 0.0;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
   end record;
end Flyology_Allocators.Waits;
