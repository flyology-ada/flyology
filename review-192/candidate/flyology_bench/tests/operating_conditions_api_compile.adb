--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Flyology_Bench;

procedure Operating_Conditions_API_Compile is
   use type Flyology_Bench.Operating_Conditions_Mode;

   Disabled_Policy : constant Flyology_Bench.Operating_Conditions_Policy :=
     Flyology_Bench.Disabled_Operating_Conditions;
   Observe_Policy  : constant Flyology_Bench.Operating_Conditions_Policy := Flyology_Bench.Observe;
   Pause_Policy    : constant Flyology_Bench.Operating_Conditions_Policy :=
     Flyology_Bench.Pause (On_Pause_Timeout => Flyology_Bench.Fallback_Observe);
   Fail_Policy     : constant Flyology_Bench.Operating_Conditions_Policy := Flyology_Bench.Fail;
   Default_Config  : constant Flyology_Bench.Configuration := Flyology_Bench.Default_Configuration;
begin
   pragma Assert (Flyology_Bench.Mode (Default_Config.Operating_Conditions) = Flyology_Bench.Disabled);
   pragma Assert (Flyology_Bench.Mode (Disabled_Policy) = Flyology_Bench.Disabled);
   pragma Assert (Flyology_Bench.Mode (Observe_Policy) = Flyology_Bench.Observe);
   pragma Assert (Flyology_Bench.Mode (Pause_Policy) = Flyology_Bench.Pause);
   pragma Assert (Flyology_Bench.Mode (Fail_Policy) = Flyology_Bench.Fail);
end Operating_Conditions_API_Compile;
