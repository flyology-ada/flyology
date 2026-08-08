--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with GNAT.Compiler_Version;
with Interfaces.C;

package body Flyology_Bench.Metadata is
   package Compiler_Info is new GNAT.Compiler_Version;

   function Native_OS return Interfaces.C.int;
   pragma Import (C, Native_OS, "flyology_bench_platform_os");

   function Native_Architecture return Interfaces.C.int;
   pragma Import
     (C, Native_Architecture, "flyology_bench_platform_architecture");

   function Operating_System return String is
   begin
      case Native_OS is
         when 1 => return "darwin";
         when 2 => return "linux";
         when others => return "unknown";
      end case;
   end Operating_System;

   function Architecture return String is
   begin
      case Native_Architecture is
         when 1 => return "aarch64";
         when 2 => return "x86_64";
         when others => return "unknown";
      end case;
   end Architecture;

   function Compiler return String is
     (Compiler_Info.Version);

   function Fingerprint (Extra : String := "") return String is
     (Operating_System & ";" & Architecture & ";gnat=" & Compiler
      & (if Extra'Length = 0 then "" else ";" & Extra));
end Flyology_Bench.Metadata;
