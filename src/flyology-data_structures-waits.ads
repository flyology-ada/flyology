with Interfaces;

--  Private monotonic-deadline and lane-aware yielding policy for explicitly
--  waiting data-structure operations. No task or timer starts at elaboration.
private package Flyology.Data_Structures.Waits with Preelaborate is
   type Context is private;

   function Start (Timeout : Wait_Timeout) return Context;

   --  Raise Timeout_Error if the deadline has expired; otherwise yield the
   --  calling Ada task once. Flyology's tasking runtime turns delay 0.0 into a
   --  fiber yield for lightweight tasks and a pthread yield for native tasks.
   procedure Retry (Item : in out Context);

   pragma Inline_Always (Start);

private
   type Context is record
      Timeout  : Wait_Timeout := 0.0;
      Deadline : Interfaces.Unsigned_64 := 0;
   end record;
end Flyology.Data_Structures.Waits;
