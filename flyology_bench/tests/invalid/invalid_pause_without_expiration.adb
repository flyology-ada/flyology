--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Flyology_Bench;

procedure Invalid_Pause_Without_Expiration is
   Policy : constant Flyology_Bench.Operating_Conditions_Policy := Flyology_Bench.Pause;
begin
   null;
end Invalid_Pause_Without_Expiration;
