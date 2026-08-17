--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Interfaces.C;
with System;

with Flyology_NUMA.Uniform;

pragma Elaborate (Flyology_NUMA.Uniform);

--  macOS describes no memory-node structure, and exposes no interface that
--  would place memory on a chosen part of the machine.  Its memory is
--  uniform, so this host has one memory domain and is reported as one node.
--
--  The performance and efficiency processor clusters that this host does
--  describe are not memory nodes.  They share one memory domain, so
--  reporting them here would name a distinction that memory placement cannot
--  act on.
package body Flyology_NUMA.Platform is

   use type Interfaces.C.int;
   use type Interfaces.C.size_t;

   function Sysctl_By_Name
     (Name      : System.Address;
      Old_Value : System.Address;
      Old_Len   : System.Address;
      New_Value : System.Address;
      New_Len   : Interfaces.C.size_t) return Interfaces.C.int
     with Import,
          Convention    => C,
          External_Name => "sysctlbyname";

   function Query (Name : String) return Byte_Query;

   -----------
   -- Query --
   -----------

   function Query (Name : String) return Byte_Query is
      C_Name : aliased constant Interfaces.C.char_array :=
        Interfaces.C.To_C (Name);
      Value  : aliased Interfaces.C.size_t := 0;
      Length : aliased Interfaces.C.size_t :=
        Interfaces.C.size_t (Value'Size / System.Storage_Unit);
      Result : constant Interfaces.C.int :=
        Sysctl_By_Name
          (Name      => C_Name'Address,
           Old_Value => Value'Address,
           Old_Len   => Length'Address,
           New_Value => System.Null_Address,
           New_Len   => 0);
   begin
      if Result /= 0
        or else Value = 0
        or else Value > Interfaces.C.size_t (Byte_Count'Last)
      then
         return No_Bytes;
      end if;

      return (Available => True, Bytes => Byte_Count (Value));
   exception
      when others =>
         return No_Bytes;
   end Query;

   Detected_Memory : constant Byte_Query := Query ("hw.memsize");

   --------------
   -- Discover --
   --------------

   function Discover return Machine_Facts is
     (Uniform.Single_Domain_Facts (Memory => Detected_Memory));

end Flyology_NUMA.Platform;
