--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Native_Rendezvous_Lane_Benchmark;

procedure Native_Rendezvous_Lane_Control is
begin
   Native_Rendezvous_Lane_Benchmark.Run (With_Idle_Lightweight => False);
end Native_Rendezvous_Lane_Control;
