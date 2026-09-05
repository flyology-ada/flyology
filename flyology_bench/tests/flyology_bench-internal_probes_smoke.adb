--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Flyology_Bench.Internal_Probes;
with Interfaces;

procedure Flyology_Bench.Internal_Probes_Smoke is
   use type Interfaces.Unsigned_64;

   Started : constant Interfaces.Unsigned_64 := Internal_Probes.Clock_Now;
begin
   --  Loading Internal_Probes runs its production header-layout checks.
   pragma Assert (Internal_Probes.Clock_Now >= Started);
end Flyology_Bench.Internal_Probes_Smoke;
