--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

private package Flyology_Bench.Internal_Window_Policy
  with SPARK_Mode => On
is
   --  One shared collection group must satisfy every enabled watch. A zero
   --  duration represents a disabled watch and cannot determine the result.
   function Required_Window
     (Interference_Window : Nonnegative_Duration; Condition_Window : Nonnegative_Duration)
      return Positive_Duration
   is (if Interference_Window = 0.0
       then Positive_Duration (Condition_Window)
       elsif Condition_Window = 0.0
       then Positive_Duration (Interference_Window)
       else
         Positive_Duration'Max
           (Positive_Duration (Interference_Window), Positive_Duration (Condition_Window)))
   with
     Pre  => Interference_Window > 0.0 or else Condition_Window > 0.0,
     Post =>
       Required_Window'Result >= Interference_Window and then Required_Window'Result >= Condition_Window;
end Flyology_Bench.Internal_Window_Policy;
