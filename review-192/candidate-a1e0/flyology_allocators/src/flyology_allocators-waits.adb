with Ada.Real_Time;

package body Flyology_Allocators.Waits is
   package RT renames Ada.Real_Time;

   use type RT.Time;
   use type RT.Time_Span;

   function Start (Timeout : Wait_Timeout) return Context
   is (Timeout => Timeout, Deadline => RT.Time_First);

   procedure Retry (Item : in out Context) is
      Observed : constant RT.Time := RT.Clock;
      Span     : RT.Time_Span;
   begin
      if Item.Deadline = RT.Time_First then
         Span := RT.To_Time_Span (Duration (Item.Timeout));
         Item.Deadline := (if Span >= RT.Time_Last - Observed then RT.Time_Last else Observed + Span);
      end if;
      if Observed >= Item.Deadline then
         raise Timeout_Error with "data-structure wait timed out";
      end if;
      delay 0.0;
   end Retry;
end Flyology_Allocators.Waits;
