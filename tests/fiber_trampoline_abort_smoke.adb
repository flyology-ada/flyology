with Flyology;

--  A lightweight task can be aborted while a nested-subprogram callback it
--  created is still live. Abort unwinds the frame that declares the callback,
--  so the runtime must release that trampoline through the aborted fiber's own
--  cursor rather than the event thread's, and the scheduler must still reap the
--  fiber. Nothing here asserts a value; the test fails by hanging, aborting on
--  a scheduler invariant, or corrupting the trampoline pool for the task that
--  keeps running afterwards.
procedure Fiber_Trampoline_Abort_Smoke is
   type Callback_Access is access procedure;

   Sink : Callback_Access := null;
   pragma Volatile (Sink);
   Observed : Natural := 0;
   pragma Volatile (Observed);

   protected Gate is
      procedure Holder_Ready;
      entry Await_Holder;
      procedure Survivor_Done;
      entry Await_Survivor;
   private
      Holder_Is_Ready  : Boolean := False;
      Survivor_Is_Done : Boolean := False;
   end Gate;

   protected body Gate is
      procedure Holder_Ready is
      begin
         Holder_Is_Ready := True;
      end Holder_Ready;

      entry Await_Holder when Holder_Is_Ready is
      begin
         null;
      end Await_Holder;

      procedure Survivor_Done is
      begin
         Survivor_Is_Done := True;
      end Survivor_Done;

      entry Await_Survivor when Survivor_Is_Done is
      begin
         null;
      end Await_Survivor;
   end Gate;

   task Holder with CPU => 1 is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Holder;

   --  Shares Holder's event loop, so a trampoline pool damaged by the abort
   --  would be observed here.
   task Survivor with CPU => 1 is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Survivor;

   task body Holder is
      procedure Hold is
         Value : Natural := 0;
         procedure Callback is
         begin
            Value := Value + 1;
            Observed := Value;
         end Callback;
      begin
         Sink := Callback'Unrestricted_Access;
         Gate.Holder_Ready;
         --  Suspend with the callback live so the abort arrives mid-scope.
         loop
            delay 3600.0;
         end loop;
      end Hold;
   begin
      Hold;
   end Holder;

   task body Survivor is
   begin
      Gate.Await_Survivor;
      for Round in 1 .. 64 loop
         declare
            Value : Natural := Round;
            procedure Callback is
            begin
               Value := Value + 1;
               Observed := Value;
            end Callback;
         begin
            Sink := Callback'Unrestricted_Access;
            Sink.all;
         end;
      end loop;
   end Survivor;
begin
   Gate.Await_Holder;
   abort Holder;
   Gate.Survivor_Done;
end Fiber_Trampoline_Abort_Smoke;
