--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

--  A Linux architecture whose memory-placement call numbers this package
--  does not record.
--
--  Calling by a number guessed from another architecture would reach a
--  working but unrelated kernel service, so nothing is called at all and
--  placement reports itself unsupported. The numbers below are never used.
private package Flyology_NUMA.Syscall_Numbers is

   --  Whether this architecture's numbers are recorded here.
   Known : constant Boolean := False;

   Mbind         : constant := 0;
   Get_Mempolicy : constant := 0;
   Set_Mempolicy : constant := 0;

end Flyology_NUMA.Syscall_Numbers;
