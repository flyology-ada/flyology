package body Flyology.Fairness is
   use type Ada.Real_Time.Time;

   procedure Configure (Budget : in out Yield_Budget; Quantum : Ada.Real_Time.Time_Span := Default_Quantum) is
   begin
      Budget.Quantum := Quantum;
      Budget.Next_Yield := Ada.Real_Time.Clock + Quantum;
   end Configure;

   procedure Checkpoint (Budget : in out Yield_Budget) is
      Now : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   begin
      if Budget.Next_Yield = Ada.Real_Time.Time_First then
         Budget.Next_Yield := Now + Budget.Quantum;
      elsif Now >= Budget.Next_Yield then
         delay 0.0;
         --  Rebase after the yield instead of accumulating missed quanta. A
         --  delayed task therefore yields once, not once per elapsed slice.
         Budget.Next_Yield := Ada.Real_Time.Clock + Budget.Quantum;
      end if;
   end Checkpoint;

   procedure Yield_Now is
   begin
      delay 0.0;
   end Yield_Now;

end Flyology.Fairness;
