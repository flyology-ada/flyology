--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Finalization;
with Ada.Strings.Unbounded;
with Interfaces.C;

package Flyology_Bench.Host_Lock is
   --  Advisory coordination between tools that claim host CPU capacity.
   --
   --  Benchmarks need the machine quiet; load generators, soak tests, and
   --  profilers make it loud. Both take the same claim, so the convention is
   --  named for the resource rather than for benchmarking. The protocol, file
   --  naming, and content grammar are specified in docs/host-cpu-lock.md so
   --  that tools outside this project can interoperate.
   --
   --  Conflict detection is `flock` alone. A holder that dies releases its
   --  claim with no cleanup path, and no registry can be left inconsistent.
   --  File content is diagnostic only and is never consulted to decide
   --  whether a claim conflicts.
   --
   --  A successful claim is not proof of exclusivity. It coordinates only
   --  with processes that reach the same file: unrelated CPU work is
   --  unaffected, and a privately mounted path silently scopes the claim to
   --  one namespace. See Isolation.

   --  Convention identifier written to, and expected in, the lock file.
   Convention : constant String := "host-cpu-lock/1";

   --  Machine-wide claim path used when no override is set. This is a single
   --  deterministic default rather than a writability-probing fallback chain:
   --  two tools that probe differently would claim different files and each
   --  conclude it holds the machine.
   Default_Path : constant String := "/tmp/host-cpu.lock";

   --  Cross-tool path override honored by every conforming implementation.
   Convention_Variable : constant String := "HOST_CPU_LOCK_PATH";

   --  Project-specific path override; takes precedence over the convention
   --  variable.
   Override_Variable : constant String := "FLYOLOGY_BENCH_LOCK_PATH";

   --  Largest number of logical CPUs one claim may name.
   Maximum_Claimed_CPUs : constant := 64;

   --  Zero-based logical CPU identifiers named by one claim.
   type CPU_List is array (Positive range <>) of Natural;

   --  Empty CPU list, claiming the machine's whole CPU capacity.
   Whole_Machine : constant CPU_List;

   --  Result of one claim attempt.
   --  @enum Acquired The claim is held until Release or finalization.
   --  @enum Busy Another holder conflicts with the requested claim.
   --  @enum Path_Unusable The path could not be opened. Missing, read-only,
   --  and permission-denied paths all land here; /tmp is absent on scratch
   --  container images and unwritable under a read-only root filesystem.
   type Acquisition is (Acquired, Busy, Path_Unusable);

   --  Whether the claim path is shared with the rest of the machine.
   --  @enum Isolation_Not_Detected No evidence that the path is private. This
   --  is not proof that it is shared; separate containers cannot be detected
   --  from inside and need an explicit path override.
   --  @enum Private_Namespace The path resolves inside a privately bound
   --  subtree, so the claim covers only this mount namespace. systemd
   --  PrivateTmp= produces exactly this.
   --  @enum Isolation_Unknown The platform did not answer the question.
   type Path_Isolation is (Isolation_Not_Detected, Private_Namespace, Isolation_Unknown);

   --  Diagnostic identity parsed from a claim file. Every field may be empty:
   --  content is written after the lock is taken, so a reader can observe an
   --  empty file, and a holder that died mid-write leaves a partial line.
   --  @field Available Whether any content was read.
   --  @field Convention_Id Convention identifier claimed by the holder.
   --  @field Tool Program that took the claim.
   --  @field Process_Id Holder process identifier as written.
   --  @field Started Acquisition timestamp as written.
   --  @field Claim Claimed resources, "all" or a CPU list.
   --  @field Working_Directory Holder's working directory when it acquired.
   type Holder is record
      Available         : Boolean := False;
      Convention_Id     : Ada.Strings.Unbounded.Unbounded_String;
      Tool              : Ada.Strings.Unbounded.Unbounded_String;
      Process_Id        : Ada.Strings.Unbounded.Unbounded_String;
      Started           : Ada.Strings.Unbounded.Unbounded_String;
      Claim             : Ada.Strings.Unbounded.Unbounded_String;
      Working_Directory : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  One held or unheld claim. Finalization releases whatever is held, so a
   --  benchmark that propagates an exception cannot leak the machine.
   type Claim is limited new Ada.Finalization.Limited_Controlled with private;

   --  Return the machine-wide claim path selected from the environment.
   --  @return Override_Variable, else Convention_Variable, else Default_Path.
   function Resolved_Path return String;

   --  Attempt one claim without waiting. A CPU list takes a shared claim on
   --  the machine file and an exclusive claim on each named CPU, in ascending
   --  order so that two callers cannot deadlock against each other. An empty
   --  list takes an exclusive claim on the machine file.
   --  @param Object Claim to populate; must not already be held.
   --  @param CPUs Logical CPUs to claim, or Whole_Machine.
   --  @param Path Machine claim path, or "" for Resolved_Path.
   --  @param Tool Program identity recorded in the claim file.
   --  @param Outcome Whether the claim was taken, conflicted, or was unusable.
   --  @exception Program_Error If Object already holds a claim, or more than
   --  Maximum_Claimed_CPUs are named.
   procedure Try_Acquire
     (Object  : in out Claim;
      Outcome : out Acquisition;
      CPUs    : CPU_List := Whole_Machine;
      Path    : String := "";
      Tool    : String := "flyology_bench");

   --  Attempt one claim, retrying until it succeeds or Timeout elapses. The
   --  caller is idle between attempts and therefore does not itself compete
   --  for the capacity it is waiting for.
   --  @param Object Claim to populate; must not already be held.
   --  @param Outcome Whether the claim was taken, timed out as Busy, or was
   --  unusable.
   --  @param CPUs Logical CPUs to claim, or Whole_Machine.
   --  @param Path Machine claim path, or "" for Resolved_Path.
   --  @param Tool Program identity recorded in the claim file.
   --  @param Timeout Longest total wait; zero attempts exactly once.
   --  @param Poll_Interval Delay between attempts.
   --  @exception Program_Error If Object already holds a claim, or more than
   --  Maximum_Claimed_CPUs are named.
   procedure Acquire
     (Object        : in out Claim;
      Outcome       : out Acquisition;
      CPUs          : CPU_List := Whole_Machine;
      Path          : String := "";
      Tool          : String := "flyology_bench";
      Timeout       : Duration := 30.0;
      Poll_Interval : Duration := 0.250);

   --  Release a held claim. Releasing an unheld claim does nothing.
   --  @param Object Claim to release.
   procedure Release (Object : in out Claim);

   --  Test whether a claim is currently held.
   --  @param Object Claim to inspect.
   --  @return True while the claim is held.
   function Held (Object : Claim) return Boolean;

   --  Return whether the claimed path is privately mounted. Evaluated when
   --  the claim is taken.
   --  @param Object Claim to inspect.
   --  @return Isolation state observed for the claim path.
   function Isolation (Object : Claim) return Path_Isolation;

   --  Return the machine claim path this claim used.
   --  @param Object Claim to inspect.
   --  @return Claim path, or the empty string when none was opened.
   function Claim_Path (Object : Claim) return String;

   --  Read the diagnostic identity written by whoever holds a claim file.
   --  The file is read without locking, because taking a shared lock would
   --  block behind the very holder the caller is trying to name.
   --  @param Path Machine claim path, or "" for Resolved_Path.
   --  @return Parsed content, with Available False when nothing was read.
   function Read_Holder (Path : String := "") return Holder;

private
   use type Interfaces.C.int;

   Whole_Machine : constant CPU_List := (1 .. 0 => 0);

   type Descriptor_Array is array (Positive range 1 .. Maximum_Claimed_CPUs) of Interfaces.C.int;

   type Claim is limited new Ada.Finalization.Limited_Controlled with record
      Machine_Descriptor : Interfaces.C.int := -1;
      CPU_Descriptors    : Descriptor_Array := (others => -1);
      CPU_Total          : Natural := 0;
      Held_Value         : Boolean := False;
      Isolation_Value    : Path_Isolation := Isolation_Unknown;
      Path_Value         : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  @exclude
   --  @param Object Claim being finalized.
   overriding
   procedure Finalize (Object : in out Claim);
end Flyology_Bench.Host_Lock;
