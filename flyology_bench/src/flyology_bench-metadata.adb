--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Flyology_Bench.Internal_Probes;
with GNAT.Compiler_Version;

package body Flyology_Bench.Metadata is
   package Compiler_Info is new GNAT.Compiler_Version;

   function Operating_System return String is
   begin
      case Internal_Probes.Operating_System is
         when Internal_Probes.Darwin         =>
            return "darwin";

         when Internal_Probes.Linux          =>
            return "linux";

         when Internal_Probes.Unknown_System =>
            return "unknown";
      end case;
   end Operating_System;

   function Architecture return String is
   begin
      case Internal_Probes.Architecture is
         when Internal_Probes.AArch64              =>
            return "aarch64";

         when Internal_Probes.X86_64               =>
            return "x86_64";

         when Internal_Probes.Unknown_Architecture =>
            return "unknown";
      end case;
   end Architecture;

   function Compiler return String
   is (Compiler_Info.Version);

   function Fingerprint (Extra : String := "") return String
   is (Operating_System
       & ";"
       & Architecture
       & ";gnat="
       & Compiler
       & (if Extra'Length = 0 then "" else ";" & Extra));
end Flyology_Bench.Metadata;
