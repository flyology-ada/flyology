with Ada.Real_Time;

package Gnatevl.Fairness is
   use type Ada.Real_Time.Time_Span;

   Default_Quantum : constant Ada.Real_Time.Time_Span :=
     Ada.Real_Time.Milliseconds (2);

   type Yield_Budget is tagged limited private;

   procedure Configure
     (Budget  : in out Yield_Budget;
      Quantum : Ada.Real_Time.Time_Span := Default_Quantum)
   with Pre => Quantum > Ada.Real_Time.Time_Span_Zero;

   procedure Checkpoint (Budget : in out Yield_Budget);

   procedure Yield_Now;

private
   type Yield_Budget is tagged limited record
      Quantum    : Ada.Real_Time.Time_Span := Default_Quantum;
      Next_Yield : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
   end record;
end Gnatevl.Fairness;
