--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

package Flyology_Bench.Metadata is
   --  Describes build and host attributes relevant to reproducible results.

   --  Return the operating-system family used to build the crate.
   --  @return Stable operating-system family name.
   function Operating_System return String;

   --  Return the target architecture used to build the crate.
   --  @return Stable target architecture name.
   function Architecture return String;

   --  Return the GNAT compiler version string.
   --  @return Compiler version reported by the GNAT build.
   function Compiler return String;

   --  Return a stable default compatibility fingerprint. Extra should include
   --  caller-controlled CPU policy, compiler switches, revision, or other
   --  conditions needed by its regression policy.
   --  @param Extra Additional caller-defined compatibility identity.
   --  @return OS, architecture, compiler, and Extra joined by semicolons.
   function Fingerprint (Extra : String := "") return String;
end Flyology_Bench.Metadata;
