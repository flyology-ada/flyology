--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

--  Memory-placement call numbers for x86-64 Linux.
--
--  These differ per architecture, and not only in value: the x86-64 table
--  and the table newer architectures share disagree on the order of
--  get_mempolicy and set_mempolicy. Reading them from the wrong table would
--  call a working but different kernel service, so each table is written out
--  separately rather than derived.
private package Flyology_NUMA.Syscall_Numbers is

   --  Whether this architecture's numbers are recorded here.
   Known : constant Boolean := True;

   Mbind         : constant := 237;
   Set_Mempolicy : constant := 238;
   Get_Mempolicy : constant := 239;

end Flyology_NUMA.Syscall_Numbers;
