--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

--  Memory-placement call numbers from the table Linux gives architectures
--  added since it was written, which includes AArch64 and RISC-V.
--
--  Note that get_mempolicy and set_mempolicy sit in the opposite order to
--  the x86-64 table.
private package Flyology_NUMA.Syscall_Numbers is

   --  Whether this architecture's numbers are recorded here.
   Known : constant Boolean := True;

   Mbind         : constant := 235;
   Get_Mempolicy : constant := 236;
   Set_Mempolicy : constant := 237;

end Flyology_NUMA.Syscall_Numbers;
