--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with System;

--  Obtains whole pages of memory from the host.
--
--  Placement acts on whole pages, so memory that is to be placed has to be
--  owned a page at a time. Memory taken from the ordinary heap cannot be:
--  it may begin partway into a page whose remainder belongs to something
--  else, and placing that page would move memory this crate does not own.
private package Flyology_NUMA.Mapping is

   --  Reserve Length bytes, rounded up to whole pages, readable and
   --  writable and backed by nothing else.
   --  @param Length The least number of bytes wanted.
   --  @return The first byte reserved, or Null_Address when the host
   --     refused or cannot be asked.
   function Reserve (Length : Byte_Count) return System.Address;

   --  Return memory obtained from Reserve.
   --  @param Base The address Reserve returned.
   --  @param Length The length passed to Reserve.
   procedure Release (Base : System.Address; Length : Byte_Count);

   --  Round Length up to a whole number of pages.
   --  @param Length The number of bytes to round.
   --  @return Length rounded up, or zero when it cannot be represented.
   function Whole_Pages (Length : Byte_Count) return Byte_Count;

end Flyology_NUMA.Mapping;
