--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

--  Mapping flags for a host this package has not been taught to read a
--  memory-node description from.
--
--  Such a host still supplies pages the ordinary way, so the value follows
--  the one Linux uses.  This crate is published for Linux and macOS, and a
--  host with no way to ask for pages at all would fail to link rather than
--  reach this.

private package Flyology_NUMA.Map_Flags is

   --  Memory backed by nothing but itself.  Linux and macOS agree on every
   --  other flag this crate uses and differ on this one.
   Anonymous : constant := 16#20#;

end Flyology_NUMA.Map_Flags;
