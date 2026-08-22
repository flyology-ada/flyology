with Ada.Real_Time;

package Flyology.Fairness is
   use type Ada.Real_Time.Time_Span;

   --  Provides explicit cooperative yield points for CPU-bound task code.
   --
   --  Example:
   --
   --     Flyology.Fairness.Checkpoint (Budget);

   --  Default elapsed time between eligible cooperative yields.
   Default_Quantum : constant Ada.Real_Time.Time_Span := Ada.Real_Time.Milliseconds (2);

   --  Per-task checkpoint state. A budget is not synchronized and must be used
   --  by one task at a time.
   type Yield_Budget is tagged limited private;

   --  Reset Budget and schedule its first eligible yield Quantum from now.
   --  Quantum is elapsed wall-clock time. Checkpoint yields at most once after
   --  an overrun, then starts a new quantum.
   --  @param Budget State owned by the calling task
   --  @param Quantum Positive interval between eligible yields
   procedure Configure (Budget : in out Yield_Budget; Quantum : Ada.Real_Time.Time_Span := Default_Quantum)
   with Pre => Quantum > Ada.Real_Time.Time_Span_Zero;

   --  Yield when Budget's quantum has elapsed. Otherwise return immediately.
   --  Lightweight tasks return to their event loop; native tasks perform the
   --  normal Ada `delay 0.0` scheduling point. Fairness remains cooperative.
   --  @param Budget State owned by the calling task
   procedure Checkpoint (Budget : in out Yield_Budget);

   --  Perform one cooperative scheduling point using `delay 0.0`.
   procedure Yield_Now;

private
   type Yield_Budget is tagged limited record
      Quantum    : Ada.Real_Time.Time_Span := Default_Quantum;
      Next_Yield : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
   end record;
end Flyology.Fairness;
