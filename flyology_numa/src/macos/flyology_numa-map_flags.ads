--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

--  Mapping flags for macOS.

private package Flyology_NUMA.Map_Flags is

   --  Memory backed by nothing but itself.  Linux and macOS agree on every
   --  other flag this crate uses and differ on this one.
   Anonymous : constant := 16#1000#;

end Flyology_NUMA.Map_Flags;
