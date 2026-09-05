--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

procedure Delta_Aggregate_Expression_Function_Compile is
   type Configuration is record
      First  : Integer;
      Second : Integer;
   end record;

   Base : constant Configuration := (First => 1, Second => 2);

   --  GNAT 13 and 14 require inner parentheses around the delta aggregate.
   function Changed return Configuration
   is ((Base with delta Second => 3));
begin
   pragma Assert (Changed.Second = 3);
end Delta_Aggregate_Expression_Function_Compile;
