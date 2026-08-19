--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

--  Counter groups held open for the life of a recording session.
--
--  Recorder-mode counters stay enabled while an externally controlled
--  session runs. Each native worker gets its own group per session; a span
--  reads cumulative value/enabled/running triples at both of its
--  boundaries and scales the difference. Workers are identified by a token
--  the platform releases when the thread ends, rather than by a thread
--  identifier that a later thread could reuse.
package Flyology_Bench.Internal_Probes.Sessions is

   subtype Identifier is Interfaces.Unsigned_64;

   --  Names no session. Zero is never issued.
   No_Session : constant Identifier := 0;

   --  Opens a session for the named counters. Returns No_Session when the
   --  request is empty or the registry is unusable.
   function Start
     (Requested_Mask : Interfaces.Unsigned_64) return Identifier;

   --  Closes every worker's counters and forgets the session. Naming an
   --  unknown session does nothing.
   procedure Stop (Session : Identifier);

   --  Reads this worker's counters, opening and enabling them on the
   --  worker's first span of the session.
   procedure Snapshot
     (Session   : Identifier;
      Result    : out Perf_Values;
      Enabled   : out Perf_Values;
      Running   : out Perf_Values;
      Status    : out Perf_Status_Values;
      Mask      : out Interfaces.Unsigned_64;
      Available : out Boolean);

end Flyology_Bench.Internal_Probes.Sessions;
