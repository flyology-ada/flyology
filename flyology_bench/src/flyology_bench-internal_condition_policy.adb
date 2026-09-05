--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

package body Flyology_Bench.Internal_Condition_Policy
with SPARK_Mode => On
is
   function Compare_Counter
     (Before : Counter_Observation; After : Counter_Observation) return Counter_Evidence
   is
   begin
      if Before.Availability /= Condition_Available then
         return
           (Availability => Condition_Unavailable,
            Increased => False,
            Increase => 0,
            Discontinuous => False);
      elsif After.Availability /= Condition_Available or else After.Value < Before.Value then
         return
           (Availability => Condition_Unavailable,
            Increased => False,
            Increase => 0,
            Discontinuous => True);
      end if;
      return
        (Availability => Condition_Available,
         Increased    => After.Value > Before.Value,
         Increase     => After.Value - Before.Value,
         Discontinuous => False);
   end Compare_Counter;

end Flyology_Bench.Internal_Condition_Policy;
